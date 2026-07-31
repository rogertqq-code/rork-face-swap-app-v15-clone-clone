import WebKit
import UIKit

/// A cached image source from which EXIF-stamped JPEG data is regenerated
/// on demand. Storing the source (rather than pre-rendered bytes) lets the
/// handler synthesize fresh metadata — most importantly the capture timestamp
/// and subsecond fields — at the exact moment the resource is requested.
nonisolated struct ImageInjectionSource: Sendable {
    let image: UIImage
    let camera: CameraDeviceSpec?
    let hardware: DeviceHardwareSpec?
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
}

nonisolated struct ResourceByteRange: Equatable, Sendable {
    let start: UInt64
    let end: UInt64

    var length: UInt64 { end - start + 1 }
}

nonisolated enum ResourceRangeResolution: Equatable, Sendable {
    case full
    case partial(ResourceByteRange)
    case unsatisfiable
}

nonisolated final class LocalResourceHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _frontVideoFileURL: URL?
    private var _backVideoFileURL: URL?
    private var _frontImageData: Data?
    private var _backImageData: Data?

    private var _stepImageSources: [String: ImageInjectionSource] = [:]
    private var _stepVideoURLs: [String: URL] = [:]
    private var _stepChunkData: [String: Data] = [:]

    private let exifService = EXIFMetadataService()

    /// Registers (or clears) the EXIF image source served for `fslimage://step/<id>`.
    func setStepImageSource(_ source: ImageInjectionSource?, id: String) {
        lock.withLock {
            if let source { _stepImageSources[id] = source } else { _stepImageSources.removeValue(forKey: id) }
        }
    }

    /// Registers (or clears) the video file served for `fslvideo://step/<id>`.
    func setStepVideoURL(_ url: URL?, id: String) {
        lock.withLock {
            if let url { _stepVideoURLs[id] = url } else { _stepVideoURLs.removeValue(forKey: id) }
        }
    }

    /// Registers (or clears) the demuxed encoded-chunk JSON served for
    /// `fslvideo://chunks/<id>` — the new frame engine's WebCodecs source.
    func setStepChunkData(_ data: Data?, id: String) {
        lock.withLock {
            if let data { _stepChunkData[id] = data } else { _stepChunkData.removeValue(forKey: id) }
        }
    }

    func clearStepSources() {
        lock.withLock {
            _stepImageSources.removeAll()
            _stepVideoURLs.removeAll()
            _stepChunkData.removeAll()
        }
    }

    /// Returns JPEG data for a step, regenerating EXIF metadata from the
    /// stored source. Used by the CSP-immune delivery path to embed raw
    /// bytes directly in the page script.
    func jpegDataForStep(_ id: String) -> Data? {
        let source = lock.withLock { _stepImageSources[id] }
        guard let source else { return nil }
        return freshJPEG(from: source)
    }

    /// Returns a metadata-stripped, re-encoded JPEG for a step — the shape Safari
    /// hands a file input after a live camera capture. Served to native
    /// camera-capture requests so the file doesn't carry more metadata than a
    /// genuine Safari capture would.
    func strippedJPEGDataForStep(_ id: String) -> Data? {
        let source = lock.withLock { _stepImageSources[id] }
        guard let source else { return nil }
        return exifService.strippedJPEGData(image: source.image)
    }

    /// A metadata-stripped JPEG for a step guaranteed to fit inside `maxBytes`, so a
    /// native camera capture can always be handed over as bytes carried inside the
    /// page — never falling back to a route a locked-down site refuses, and never
    /// to the full-metadata original.
    func strippedJPEGDataForStep(_ id: String, maxBytes: Int) -> Data? {
        let source = lock.withLock { _stepImageSources[id] }
        guard let source else { return nil }
        return exifService.strippedJPEGData(image: source.image, maxBytes: maxBytes)
    }

    /// Returns raw RGBA pixel data + dimensions for a step, resized to the
    /// target dimensions. Used by the putImageData CSP-immune path — the
    /// highest-confidence delivery method because it writes pixels directly
    /// to the canvas with zero URLs, blobs, or fetch calls.
    func rgbaPixelDataForStep(_ id: String, targetWidth: Int, targetHeight: Int) -> (data: Data, width: Int, height: Int)? {
        let source = lock.withLock { _stepImageSources[id] }
        guard let source else { return nil }
        let resized = resizeImageForPixels(source.image, maxWidth: targetWidth, maxHeight: targetHeight)
        return rgbaPixelData(from: resized)
    }

    /// Resizes an image to fit within maxWidth x maxHeight, maintaining aspect ratio.
    /// Orientation is baked into upright pixels first so the later RGBA extract
    /// never has to interpret UIImage orientation tags.
    private func resizeImageForPixels(_ image: UIImage, maxWidth: Int, maxHeight: Int) -> UIImage {
        let upright = image.normalizedForInjection()
        let size = upright.size
        guard size.width > 0, size.height > 0 else { return upright }
        let scale = min(CGFloat(maxWidth) / size.width, CGFloat(maxHeight) / size.height, 1.0)
        let newSize = CGSize(width: max(size.width * scale, 1), height: max(size.height * scale, 1))
        // Force a 1:1 pixel scale so the extracted RGBA buffer matches the
        // target dimensions exactly. The default renderer uses the device
        // screen scale (2x/3x), which inflates the pixel data 4–9x and blows
        // the inline pixel-data budget, silently disabling the putImageData
        // delivery path on every retina device.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            upright.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Extracts top-left-origin RGBA bytes from a UIImage suitable for
    /// ImageData construction in JavaScript (row 0 = visual top, R,G,B,A).
    ///
    /// Uses pure Core Graphics drawing (safe on the background cache queue) into
    /// a Quartz bitmap whose row 0 is the visual top, so the buffer matches
    /// canvas ImageData with no manual flip.
    private func rgbaPixelData(from image: UIImage) -> (data: Data, width: Int, height: Int)? {
        let upright = image.normalizedForInjection()
        // Pure Core Graphics needs the backing CGImage. Injection sources are
        // always CGImage-backed (decoded JPEG / rendered upright), so this is
        // only nil in pathological cases — where returning nil correctly makes
        // the engine fall back to the JPEG byte path instead of crashing.
        guard let cgImage = upright.cgImage else { return nil }
        let width = max(Int(upright.size.width.rounded()), 1)
        let height = max(Int(upright.size.height.rounded()), 1)
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // PremultipliedLast + byteOrder32Big yields RGBA byte order that matches
        // the HTML canvas ImageData layout (R,G,B,A per pixel, top-left origin).
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        context.interpolationQuality = .high

        // Pure Core Graphics draw — thread-safe off the main thread, unlike the
        // previous UIGraphicsPushContext + UIImage.draw (this runs on the
        // background cache-population queue). A CGBitmapContext stores row 0 as
        // the visual top, so drawing the CGImage with NO CTM flip lands the top
        // row first. Byte-for-byte identical to the old flip + UIImage.draw path
        // (UIImage.draw added a second, canceling flip), so the putImageData
        // frame stays upright.
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return (Data(pixelData), width, height)
    }

    private func stepImageSource(_ id: String) -> ImageInjectionSource? {
        lock.withLock { _stepImageSources[id] }
    }

    private func stepVideoURL(_ id: String) -> URL? {
        lock.withLock { _stepVideoURLs[id] }
    }

    private func stepChunkData(_ id: String) -> Data? {
        lock.withLock { _stepChunkData[id] }
    }

    var frontVideoFileURL: URL? {
        get { lock.withLock { _frontVideoFileURL } }
        set { lock.withLock { _frontVideoFileURL = newValue } }
    }

    var backVideoFileURL: URL? {
        get { lock.withLock { _backVideoFileURL } }
        set { lock.withLock { _backVideoFileURL = newValue } }
    }

    var videoFileURL: URL? {
        get { frontVideoFileURL ?? backVideoFileURL }
        set {
            frontVideoFileURL = newValue
            backVideoFileURL = newValue
        }
    }

    var frontImageData: Data? {
        get { lock.withLock { _frontImageData } }
        set { lock.withLock { _frontImageData = newValue } }
    }

    var backImageData: Data? {
        get { lock.withLock { _backImageData } }
        set { lock.withLock { _backImageData = newValue } }
    }



    private var _activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let task = Task {
            await handleRequest(urlSchemeTask: urlSchemeTask)
            lock.withLock { _activeTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) }
        }
        lock.withLock { _activeTasks[ObjectIdentifier(urlSchemeTask)] = task }
    }

    private func handleRequest(urlSchemeTask: any WKURLSchemeTask) async {
        let method = urlSchemeTask.request.httpMethod?.uppercased() ?? "GET"
        let requestURL = urlSchemeTask.request.url!
        let scheme = requestURL.scheme ?? ""

        if scheme == "fslimage" {
            handleImageRequest(urlSchemeTask: urlSchemeTask, requestURL: requestURL, method: method)
            return
        }

        if method == "OPTIONS" {
            guard let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: corsHeaders()
            ) else {
                urlSchemeTask.didFailWithError(URLError(.unknown))
                return
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
            return
        }

        let host = requestURL.host ?? ""

        if host == "chunks" {
            serveChunkData(urlSchemeTask: urlSchemeTask, requestURL: requestURL, method: method)
            return
        }

        let fileURL: URL?
        if host == "step" {
            fileURL = stepVideoURL(requestURL.lastPathComponent)
        } else {
            fileURL = frontVideoFileURL ?? backVideoFileURL
        }

        guard let fileURL else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch {
            urlSchemeTask.didFailWithError(URLError(.cannotOpenFile))
            return
        }

        let fileSize = (attrs[.size] as? UInt64) ?? 0
        let mime = mimeType(for: fileURL)

        if method == "HEAD" {
            var headers = corsHeaders()
            headers["Content-Type"] = mime
            headers["Content-Length"] = "\(fileSize)"
            headers["Accept-Ranges"] = "bytes"
            guard let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                urlSchemeTask.didFailWithError(URLError(.unknown))
                return
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
            return
        }

        let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")

        switch Self.resolveByteRange(rangeHeader, fileSize: fileSize) {
        case .partial(let byteRange):
            guard byteRange.length <= UInt64(Int.max),
                  let handle = try? FileHandle(forReadingFrom: fileURL) else {
                urlSchemeTask.didFailWithError(URLError(.cannotOpenFile))
                return
            }
            defer { try? handle.close() }

            var headers = corsHeaders()
            headers["Content-Type"] = mime
            headers["Content-Length"] = "\(byteRange.length)"
            headers["Content-Range"] = "bytes \(byteRange.start)-\(byteRange.end)/\(fileSize)"
            headers["Accept-Ranges"] = "bytes"

            guard let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                urlSchemeTask.didFailWithError(URLError(.unknown))
                return
            }
            urlSchemeTask.didReceive(response)
            
            var bytesRemaining = byteRange.length
            try? handle.seek(toOffset: byteRange.start)
            let chunkSize: UInt64 = 1024 * 1024
            
            while bytesRemaining > 0 {
                if Task.isCancelled { return }
                let toRead = min(bytesRemaining, chunkSize)
                if let data = try? handle.read(upToCount: Int(toRead)), !data.isEmpty {
                    urlSchemeTask.didReceive(data)
                    bytesRemaining -= UInt64(data.count)
                } else {
                    break
                }
                await Task.yield()
            }
            if !Task.isCancelled {
                urlSchemeTask.didFinish()
            }
            return
        case .unsatisfiable:
            var headers = corsHeaders()
            headers["Content-Range"] = "bytes */\(fileSize)"
            let resp = HTTPURLResponse(
                url: requestURL,
                statusCode: 416,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            urlSchemeTask.didReceive(resp)
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
            return
        case .full:
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                urlSchemeTask.didFailWithError(URLError(.cannotOpenFile))
                return
            }
            defer { try? handle.close() }

            var headers = corsHeaders()
            headers["Content-Type"] = mime
            headers["Content-Length"] = "\(fileSize)"
            headers["Accept-Ranges"] = "bytes"

            guard let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                urlSchemeTask.didFailWithError(URLError(.unknown))
                return
            }

            urlSchemeTask.didReceive(response)
            
            let chunkSize = 1024 * 1024
            while !Task.isCancelled {
                if let data = try? handle.read(upToCount: chunkSize), !data.isEmpty {
                    urlSchemeTask.didReceive(data)
                } else {
                    break
                }
                await Task.yield()
            }
            if !Task.isCancelled {
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        lock.withLock {
            if let task = _activeTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) {
                task.cancel()
            }
        }
    }

    func stopTask(for url: URL) {
        // No-op: tasks are tracked by WKURLSchemeTask identity, not URL.
        // The webView(_:stop:) callback handles cancellation via Task.cancel().
    }

    func cancelAllTasks() {
        lock.withLock {
            for (_, task) in _activeTasks {
                task.cancel()
            }
            _activeTasks.removeAll()
        }
    }

    /// Serves the demuxed encoded-chunk JSON for a step (new frame engine). A
    /// missing bundle fails cleanly so the page falls back to the element feed.
    private func serveChunkData(urlSchemeTask: any WKURLSchemeTask, requestURL: URL, method: String) {
        guard let data = stepChunkData(requestURL.lastPathComponent) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        var headers = corsHeaders()
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = "\(data.count)"
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            urlSchemeTask.didFailWithError(URLError(.unknown))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(method == "HEAD" ? Data() : data)
        urlSchemeTask.didFinish()
    }

    private func handleImageRequest(urlSchemeTask: any WKURLSchemeTask, requestURL: URL, method: String) {
        if method == "OPTIONS" {
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: corsHeaders()
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
            return
        }

        let host = requestURL.host ?? ""

        if host == "__probe__" {
            serveImageProbe(urlSchemeTask: urlSchemeTask, requestURL: requestURL)
            return
        }

        // Regenerate EXIF on demand so the timestamp (and subsecond fields)
        // reflect the exact moment of capture rather than load time. A `strip=1`
        // query returns the metadata-stripped re-encode used for native camera
        // captures (Safari drops EXIF on a capture hand-off).
        let wantsStripped = (URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "strip" })?.value == "1")
        var imageData: Data?
        if host == "step", let source = stepImageSource(requestURL.lastPathComponent) {
            imageData = wantsStripped
                ? exifService.strippedJPEGData(image: source.image)
                : freshJPEG(from: source)
        }

        // Fall back to any pre-rendered bytes if no live source is available.
        if imageData == nil {
            imageData = frontImageData ?? backImageData
        }

        guard let data = imageData else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        var headers = corsHeaders()
        headers["Content-Type"] = "image/jpeg"
        headers["Content-Length"] = "\(data.count)"

        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            urlSchemeTask.didFailWithError(URLError(.unknown))
            return
        }

        urlSchemeTask.didReceive(response)
        if method != "HEAD" {
            urlSchemeTask.didReceive(data)
        } else {
            urlSchemeTask.didReceive(Data())
        }
        urlSchemeTask.didFinish()
    }

    static func resolveByteRange(_ header: String?, fileSize: UInt64) -> ResourceRangeResolution {
        guard let header, header.lowercased().hasPrefix("bytes=") else { return .full }
        guard fileSize > 0 else { return .unsatisfiable }

        let rangeSpec = String(header.dropFirst(6))
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        let parts = rangeSpec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full }

        let startText = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let endText = String(parts[1]).trimmingCharacters(in: .whitespaces)
        let lastByte = fileSize - 1

        if startText.isEmpty {
            guard let suffixLength = UInt64(endText), suffixLength > 0 else { return .unsatisfiable }
            let clampedLength = min(suffixLength, fileSize)
            return .partial(ResourceByteRange(start: fileSize - clampedLength, end: lastByte))
        }

        guard let start = UInt64(startText), start <= lastByte else { return .unsatisfiable }
        let end = endText.isEmpty ? lastByte : min(UInt64(endText) ?? lastByte, lastByte)
        guard end >= start else { return .unsatisfiable }
        return .partial(ResourceByteRange(start: start, end: end))
    }

    private func serveImageProbe(urlSchemeTask: any WKURLSchemeTask, requestURL: URL) {
        let data = Data([
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
            0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
            0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
            0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08,
            0x07, 0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C,
            0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
            0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D,
            0x1A, 0x1C, 0x1C, 0x20, 0x24, 0x2E, 0x27, 0x20,
            0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
            0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27,
            0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34,
            0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
            0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4,
            0x00, 0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x08, 0xFF, 0xC4, 0x00, 0x14,
            0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
            0x00, 0x00, 0x3F, 0x00, 0x2A, 0xBF, 0xFF, 0xD9
        ])
        var headers = corsHeaders()
        headers["Content-Type"] = "image/jpeg"
        headers["Content-Length"] = "\(data.count)"
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            urlSchemeTask.didFailWithError(URLError(.unknown))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    private func freshJPEG(from source: ImageInjectionSource) -> Data? {
        if source.latitude != nil && source.longitude != nil {
            return exifService.jpegDataWithEXIFAndGPS(
                image: source.image,
                camera: source.camera,
                hardware: source.hardware,
                latitude: source.latitude,
                longitude: source.longitude,
                altitude: source.altitude
            )
        }
        return exifService.jpegDataWithEXIF(
            image: source.image,
            camera: source.camera,
            hardware: source.hardware
        )
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        default: return "video/mp4"
        }
    }

    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
            "Access-Control-Allow-Headers": "*",
            "Access-Control-Max-Age": "86400"
        ]
    }
}
