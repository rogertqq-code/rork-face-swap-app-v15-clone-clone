import AVFoundation
import Foundation

@Observable
@MainActor
final class CameraResponseCalibrationService {
    var isCalibrating: Bool = false
    var progress: Double = 0
    var status: String = ""

    func calibrate(profile: DeviceProfile) async -> CameraResponseMap {
        isCalibrating = true
        progress = 0
        status = "Preparing camera calibration…"
        defer {
            isCalibrating = false
            progress = 1
            status = "Calibration ready"
        }

        let requests = Self.smartRequests(for: profile)
        guard !requests.isEmpty else { return CameraResponseMap(results: []) }

        let hasPermission = await requestVideoAccessIfNeeded()
        status = hasPermission ? "Reading real camera formats…" : "Camera unavailable — using saved profile formats…"

        var results: [CameraResponseResult] = []
        for (index, request) in requests.enumerated() {
            status = "Testing \(request.target.label) \(request.surface.label) \(request.requestedLabel)…"
            if let result = Self.resolve(request: request, in: profile) {
                results.append(result)
            }
            progress = Double(index + 1) / Double(requests.count)
        }

        if hasPermission {
            results.append(contentsOf: Self.liveDeviceResults(for: profile))
        }

        return CameraResponseMap(results: Self.deduplicate(results))
    }

    nonisolated static func responseMap(for profile: DeviceProfile) -> CameraResponseMap {
        let requests = smartRequests(for: profile)
        let results = requests.compactMap { resolve(request: $0, in: profile) }
        return CameraResponseMap(results: deduplicate(results))
    }

    nonisolated static func learnedMap(from entries: [ConstraintLogEntry], existing: CameraResponseMap?) -> CameraResponseMap {
        var results = existing?.results ?? []
        for entry in entries {
            guard let request = requestFromConstraintEntry(entry), let result = resultFromConstraintEntry(entry, request: request) else { continue }
            results.removeAll { existing in
                existing.request.target == result.request.target &&
                existing.request.surface == .liveSite &&
                existing.request.requestedWidth == result.request.requestedWidth &&
                existing.request.requestedHeight == result.request.requestedHeight &&
                existing.request.requestedFrameRate == result.request.requestedFrameRate &&
                existing.request.sourceLabel == result.request.sourceLabel
            }
            results.append(result)
        }
        return CameraResponseMap(generatedAt: Date(), results: deduplicate(results))
    }

    nonisolated static func insights(
        from entries: [ConstraintLogEntry],
        profile: DeviceProfile?,
        activeProfile: InjectionMethodKind
    ) -> [CameraRequestInsight] {
        entries.compactMap { insight(from: $0, profile: profile, activeProfile: activeProfile) }
    }

    nonisolated static func insight(
        from entry: ConstraintLogEntry,
        profile: DeviceProfile?,
        activeProfile: InjectionMethodKind
    ) -> CameraRequestInsight? {
        let parsed = parsedRequest(from: entry)
        let host = URL(string: entry.siteURL)?.host ?? entry.siteURL
        let target = parsed.target
        let requestedFPS = parsed.frameRate
        let fps = requestedFPS ?? profile.flatMap { camera(for: target, profile: $0) }.map { MediaConversionSpec.clampFrameRate(Int($0.activeFrameRate.rounded())) } ?? 30

        guard let profile else {
            let predictedWidth = parsed.width ?? 1280
            let predictedHeight = parsed.height ?? 720
            return CameraRequestInsight(
                siteURL: entry.siteURL,
                host: host,
                timestamp: entry.timestamp,
                target: target,
                audioRequested: parsed.audioRequested,
                requestedWidth: parsed.width,
                requestedHeight: parsed.height,
                requestedFrameRate: parsed.frameRate,
                predictedWidth: predictedWidth,
                predictedHeight: predictedHeight,
                predictedFrameRate: fps,
                dimensionSource: parsed.dimensionSource,
                observedSettings: entry.negotiatedResult,
                wasSuccessful: entry.wasSuccessful,
                warnings: [CameraRequestWarning(kind: .noProfile, message: "Create or select a device profile to predict the phone's natural camera response.")],
                notes: "No active device profile was available for prediction."
            )
        }

        guard let camera = camera(for: target, profile: profile) else { return nil }
        let normalized = normalizedRequest(width: parsed.width, height: parsed.height, camera: camera)
        let request = CameraResponseRequest(
            target: target,
            surface: .liveSite,
            requestedWidth: normalized.width,
            requestedHeight: normalized.height,
            requestedFrameRate: fps,
            sourceLabel: host.isEmpty ? "Live Site" : host
        )
        let mapMatch = profile.cameraResponseMap?.bestMatch(
            target: target,
            surface: .liveSite,
            requestedWidth: normalized.width,
            requestedHeight: normalized.height,
            frameRate: fps
        ) ?? profile.cameraResponseMap?.bestMatch(
            target: target,
            surface: .webRTC,
            requestedWidth: normalized.width,
            requestedHeight: normalized.height,
            frameRate: fps
        )
        let predicted = mapMatch ?? resolve(request: request, in: profile)
        let predictedWidth = predicted?.actualWidth ?? normalized.width
        let predictedHeight = predicted?.actualHeight ?? normalized.height
        let predictedFPS = predicted?.actualFrameRate ?? fps
        var warnings = requestWarnings(
            parsed: parsed,
            normalized: normalized,
            predicted: predicted,
            camera: camera,
            entry: entry
        )
        // Always append a media-fit hint since all injection methods benefit from knowing the predicted shape.
        if activeProfile != .passthrough {
            warnings.append(CameraRequestWarning(kind: .partialDimensions, message: "Compare your selected media against this predicted shape before using it with \(activeProfile.label)."))
        }

        return CameraRequestInsight(
            siteURL: entry.siteURL,
            host: host,
            timestamp: entry.timestamp,
            target: target,
            audioRequested: parsed.audioRequested,
            requestedWidth: parsed.width,
            requestedHeight: parsed.height,
            requestedFrameRate: parsed.frameRate,
            predictedWidth: predictedWidth,
            predictedHeight: predictedHeight,
            predictedFrameRate: predictedFPS,
            dimensionSource: normalized.source,
            predictedResponse: predicted,
            observedSettings: entry.negotiatedResult,
            wasSuccessful: entry.wasSuccessful,
            warnings: warnings,
            notes: predictionNote(target: target, camera: camera, predicted: predicted)
        )
    }

    nonisolated static func smartRequests(for profile: DeviceProfile) -> [CameraResponseRequest] {
        var requests: [CameraResponseRequest] = []
        var seen: Set<String> = []

        func add(target: RequestTarget, surface: CameraRequestSurface, width: Int, height: Int, fps: Int, label: String) {
            guard width >= 160, height >= 120 else { return }
            let clampedFPS = MediaConversionSpec.clampFrameRate(fps)
            let key = "\(target.rawValue)-\(surface.rawValue)-\(width)x\(height)-\(clampedFPS)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            requests.append(CameraResponseRequest(target: target, surface: surface, requestedWidth: width, requestedHeight: height, requestedFrameRate: clampedFPS, sourceLabel: label))
        }

        let commonWeb: [(Int, Int, Int, String)] = [
            (320, 240, 30, "QVGA"),
            (640, 480, 30, "VGA"),
            (1280, 720, 30, "HD"),
            (1920, 1080, 30, "Full HD"),
            (1080, 1920, 30, "Portrait HD")
        ]
        let nativeDefaults: [(Int, Int, Int, String)] = [
            (640, 480, 30, "Native VGA"),
            (1280, 720, 30, "Native HD"),
            (1920, 1080, 30, "Native 1080p"),
            (3840, 2160, 30, "Native 4K")
        ]

        for target in [RequestTarget.front, .back] {
            if let camera = camera(for: target, profile: profile) {
                add(target: target, surface: .webRTC, width: camera.activeWidth, height: camera.activeHeight, fps: Int(camera.activeFrameRate.rounded()), label: "Active format")
                add(target: target, surface: .nativeCamera, width: camera.activeWidth, height: camera.activeHeight, fps: Int(camera.activeFrameRate.rounded()), label: "Active native")
                for format in usefulFormats(camera.supportedFormats, limit: 4) {
                    add(target: target, surface: .webRTC, width: format.width, height: format.height, fps: Int(format.maxFrameRate.rounded()), label: "Device format")
                    add(target: target, surface: .nativeCamera, width: format.width, height: format.height, fps: Int(format.maxFrameRate.rounded()), label: "Native format")
                }
            }
            for item in commonWeb {
                add(target: target, surface: .webRTC, width: item.0, height: item.1, fps: item.2, label: item.3)
            }
            for item in nativeDefaults {
                add(target: target, surface: .nativeCamera, width: item.0, height: item.1, fps: item.2, label: item.3)
            }
        }

        return Array(requests.prefix(32))
    }

    nonisolated static func resolve(request: CameraResponseRequest, in profile: DeviceProfile) -> CameraResponseResult? {
        guard let camera = camera(for: request.target, profile: profile) else { return nil }
        let formats = usefulFormats(camera.supportedFormats, limit: 80)
        let selected = closestFormat(to: request, formats: formats) ?? CameraFormatSpec(
            width: camera.activeWidth,
            height: camera.activeHeight,
            maxFrameRate: camera.activeFrameRate,
            minFrameRate: camera.minFrameRate,
            mediaType: "vide",
            videoFieldOfView: camera.focalLength ?? 0,
            isMultiCamSupported: false
        )

        let actualFPS = MediaConversionSpec.clampFrameRate(Int(min(selected.maxFrameRate, Double(request.requestedFrameRate)).rounded()))
        let isExact = selected.width == request.requestedWidth && selected.height == request.requestedHeight && abs(actualFPS - request.requestedFrameRate) <= 1
        let matchType: CameraResponseMatchType
        if isExact {
            matchType = request.surface == .nativeCamera ? .nativeCameraMatch : .exactNaturalMatch
        } else {
            matchType = .closestDeviceMatch
        }
        let confidence = confidenceScore(request: request, width: selected.width, height: selected.height, fps: actualFPS)

        return CameraResponseResult(
            request: request,
            actualWidth: selected.width,
            actualHeight: selected.height,
            actualFrameRate: actualFPS,
            matchType: matchType,
            confidence: confidence,
            cameraID: camera.id,
            cameraLabel: camera.label,
            notes: isExact ? "Device accepts this request naturally." : "Device naturally resolves this request to the closest supported format."
        )
    }

    private func requestVideoAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private nonisolated static func liveDeviceResults(for profile: DeviceProfile) -> [CameraResponseResult] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInDualCamera, .builtInTripleCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .unspecified
        )
        var results: [CameraResponseResult] = []
        for device in discovery.devices {
            let target: RequestTarget = device.position == .front ? .front : .back
            guard camera(for: target, profile: profile) != nil else { continue }
            let formats = device.formats.compactMap { format -> CameraFormatSpec? in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dimensions.width > 0, dimensions.height > 0 else { return nil }
                let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
                let minFPS = format.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 1
                return CameraFormatSpec(
                    width: Int(dimensions.width),
                    height: Int(dimensions.height),
                    maxFrameRate: maxFPS,
                    minFrameRate: minFPS,
                    mediaType: "vide",
                    videoFieldOfView: format.videoFieldOfView,
                    isMultiCamSupported: format.isMultiCamSupported
                )
            }
            for format in usefulFormats(formats, limit: 4) {
                let fps = MediaConversionSpec.clampFrameRate(Int(format.maxFrameRate.rounded()))
                let request = CameraResponseRequest(target: target, surface: .nativeCamera, requestedWidth: format.width, requestedHeight: format.height, requestedFrameRate: fps, sourceLabel: "Observed native")
                results.append(CameraResponseResult(
                    request: request,
                    actualWidth: format.width,
                    actualHeight: format.height,
                    actualFrameRate: fps,
                    matchType: .nativeCameraMatch,
                    confidence: 1.0,
                    cameraID: device.uniqueID,
                    cameraLabel: device.localizedName,
                    notes: "Observed from the real camera hardware after permission."
                ))
            }
        }
        return results
    }

    private nonisolated static func camera(for target: RequestTarget, profile: DeviceProfile) -> CameraDeviceSpec? {
        switch target {
        case .front: profile.frontCamera
        case .back: profile.backCamera
        case .any: profile.backCamera ?? profile.frontCamera
        }
    }

    private nonisolated static func usefulFormats(_ formats: [CameraFormatSpec], limit: Int) -> [CameraFormatSpec] {
        var bySize: [String: CameraFormatSpec] = [:]
        for format in formats where format.width > 0 && format.height > 0 {
            let key = "\(format.width)x\(format.height)"
            if let existing = bySize[key] {
                if format.maxFrameRate > existing.maxFrameRate { bySize[key] = format }
            } else {
                bySize[key] = format
            }
        }
        return bySize.values
            .sorted { lhs, rhs in
                let lhsPixels = lhs.width * lhs.height
                let rhsPixels = rhs.width * rhs.height
                if lhsPixels == rhsPixels { return lhs.maxFrameRate > rhs.maxFrameRate }
                return lhsPixels > rhsPixels
            }
            .prefix(limit)
            .map { $0 }
    }

    private nonisolated static func closestFormat(to request: CameraResponseRequest, formats: [CameraFormatSpec]) -> CameraFormatSpec? {
        formats.min { lhs, rhs in
            distance(request: request, format: lhs) < distance(request: request, format: rhs)
        }
    }

    private nonisolated static func distance(request: CameraResponseRequest, format: CameraFormatSpec) -> Int {
        let requestedPixels = request.requestedWidth * request.requestedHeight
        let formatPixels = format.width * format.height
        let pixelDelta = abs(requestedPixels - formatPixels)
        let requestedAspect = Double(request.requestedWidth) / Double(max(request.requestedHeight, 1))
        let formatAspect = Double(format.width) / Double(max(format.height, 1))
        let aspectDelta = Int(abs(requestedAspect - formatAspect) * 150_000)
        let fpsDelta = abs(Int(format.maxFrameRate.rounded()) - request.requestedFrameRate) * 6_000
        return pixelDelta + aspectDelta + fpsDelta
    }

    private nonisolated static func confidenceScore(request: CameraResponseRequest, width: Int, height: Int, fps: Int) -> Double {
        let requestedPixels = max(request.requestedWidth * request.requestedHeight, 1)
        let actualPixels = max(width * height, 1)
        let pixelScore = 1.0 - min(Double(abs(requestedPixels - actualPixels)) / Double(max(requestedPixels, actualPixels)), 1.0)
        let requestedAspect = Double(request.requestedWidth) / Double(max(request.requestedHeight, 1))
        let actualAspect = Double(width) / Double(max(height, 1))
        let aspectScore = 1.0 - min(abs(requestedAspect - actualAspect) / max(requestedAspect, actualAspect), 1.0)
        let fpsDenominator = max(max(request.requestedFrameRate, fps), 1)
        let fpsScore = 1.0 - min(Double(abs(request.requestedFrameRate - fps)) / Double(fpsDenominator), 1.0)
        return max(0.05, min((pixelScore * 0.5 + aspectScore * 0.35 + fpsScore * 0.15), 1.0))
    }

    private nonisolated static func deduplicate(_ results: [CameraResponseResult]) -> [CameraResponseResult] {
        var byKey: [String: CameraResponseResult] = [:]
        for result in results {
            let key = "\(result.request.target.rawValue)-\(result.request.surface.rawValue)-\(result.request.requestedWidth)x\(result.request.requestedHeight)-\(result.request.requestedFrameRate)-\(result.request.sourceLabel)"
            if let existing = byKey[key] {
                if result.confidence >= existing.confidence { byKey[key] = result }
            } else {
                byKey[key] = result
            }
        }
        return byKey.values.sorted { lhs, rhs in
            if lhs.request.target != rhs.request.target { return lhs.request.target.rawValue < rhs.request.target.rawValue }
            if lhs.request.surface != rhs.request.surface { return lhs.request.surface.rawValue < rhs.request.surface.rawValue }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.request.requestedWidth * lhs.request.requestedHeight > rhs.request.requestedWidth * rhs.request.requestedHeight
        }
    }

    private struct ParsedCameraConstraint {
        var target: RequestTarget
        var width: Int?
        var height: Int?
        var frameRate: Int?
        var audioRequested: Bool
        var dimensionSource: CameraRequestDimensionSource
    }

    private nonisolated static func parsedRequest(from entry: ConstraintLogEntry) -> ParsedCameraConstraint {
        let object = jsonObject(from: entry.requestedConstraints) as? [String: Any]
        let video = object?["video"] as? [String: Any]
        let combined = entry.requestedConstraints + " " + entry.negotiatedResult
        let width = intConstraint(video?["width"]) ?? singleValue(named: "width", in: entry.requestedConstraints)
        let height = intConstraint(video?["height"]) ?? singleValue(named: "height", in: entry.requestedConstraints)
        let frameRate = intConstraint(video?["frameRate"]).map(MediaConversionSpec.clampFrameRate) ?? frameRate(in: entry.requestedConstraints) ?? frameRate(in: entry.negotiatedResult)
        let facing = stringConstraint(video?["facingMode"]) ?? facingMode(in: combined)
        let target: RequestTarget
        if facing == "environment" || combined.lowercased().contains("back") || combined.lowercased().contains("rear") {
            target = .back
        } else if facing == "user" || combined.lowercased().contains("front") {
            target = .front
        } else {
            target = .any
        }
        let audio = audioRequested(from: object?["audio"])
        let source: CameraRequestDimensionSource
        switch (width, height) {
        case (.some, .some): source = .explicit
        case (.some, .none): source = .inferredFromWidth
        case (.none, .some): source = .inferredFromHeight
        case (.none, .none): source = .profileDefault
        }
        return ParsedCameraConstraint(target: target, width: width, height: height, frameRate: frameRate, audioRequested: audio, dimensionSource: source)
    }

    private nonisolated static func normalizedRequest(width: Int?, height: Int?, camera: CameraDeviceSpec) -> (width: Int, height: Int, source: CameraRequestDimensionSource) {
        let aspect = Double(max(camera.activeWidth, 1)) / Double(max(camera.activeHeight, 1))
        switch (width, height) {
        case let (.some(w), .some(h)):
            return (w, h, .explicit)
        case let (.some(w), .none):
            let inferred = nearestEven(Int((Double(w) / max(aspect, 0.1)).rounded()))
            return (w, max(inferred, 120), .inferredFromWidth)
        case let (.none, .some(h)):
            let inferred = nearestEven(Int((Double(h) * aspect).rounded()))
            return (max(inferred, 160), h, .inferredFromHeight)
        case (.none, .none):
            return (max(camera.activeWidth, 640), max(camera.activeHeight, 480), .profileDefault)
        }
    }

    private nonisolated static func nearestEven(_ value: Int) -> Int {
        value % 2 == 0 ? value : value + 1
    }

    private nonisolated static func requestWarnings(
        parsed: ParsedCameraConstraint,
        normalized: (width: Int, height: Int, source: CameraRequestDimensionSource),
        predicted: CameraResponseResult?,
        camera: CameraDeviceSpec,
        entry: ConstraintLogEntry
    ) -> [CameraRequestWarning] {
        var warnings: [CameraRequestWarning] = []
        if parsed.dimensionSource == .inferredFromWidth || parsed.dimensionSource == .inferredFromHeight {
            warnings.append(CameraRequestWarning(kind: .partialDimensions, message: "The site requested only one dimension; the other was inferred from the camera's natural aspect ratio before matching a supported format."))
        }
        if let predicted, !predicted.isExact {
            warnings.append(CameraRequestWarning(kind: .impossibleResolution, message: "The requested shape is not an exact supported format, so the closest natural camera response is \(predicted.actualLabel)."))
        }
        let requestedPortrait = normalized.height > normalized.width
        let cameraPortrait = camera.activeHeight > camera.activeWidth
        if requestedPortrait != cameraPortrait {
            warnings.append(CameraRequestWarning(kind: .portraitLandscapeMismatch, message: "The request and camera default use different orientation shapes; the browser may rotate metadata, crop, or scale rather than changing the sensor format."))
        }
        if parsed.target == .front {
            warnings.append(CameraRequestWarning(kind: .frontMirror, message: "Front camera previews are commonly mirrored for the user even when encoded frames remain unmirrored."))
        }
        if parsed.audioRequested {
            warnings.append(CameraRequestWarning(kind: .audioRequested, message: "The site requested audio with video, so microphone route and sample-rate behavior may affect compatibility."))
        }
        if !entry.wasSuccessful {
            warnings.append(CameraRequestWarning(kind: .failedRequest, message: entry.fallbackReason ?? "The browser request failed before a usable camera result was delivered."))
        }
        return warnings
    }

    private nonisolated static func predictionNote(target: RequestTarget, camera: CameraDeviceSpec, predicted: CameraResponseResult?) -> String {
        let side = target == .front ? "front" : (target == .back ? "back" : "selected")
        let response = predicted?.actualLabel ?? "the profile default"
        return "Predicted from the \(side) camera profile (\(camera.label)): \(response)."
    }

    private nonisolated static func requestFromConstraintEntry(_ entry: ConstraintLogEntry) -> CameraResponseRequest? {
        let parsed = parsedRequest(from: entry)
        let actual = size(in: entry.negotiatedResult)
        guard let requestedWidth = parsed.width ?? actual?.width,
              let requestedHeight = parsed.height ?? actual?.height else { return nil }
        let fps = parsed.frameRate ?? frameRate(in: entry.negotiatedResult) ?? 30
        let host = URL(string: entry.siteURL)?.host ?? "Live Site"
        return CameraResponseRequest(target: parsed.target, surface: .liveSite, requestedWidth: requestedWidth, requestedHeight: requestedHeight, requestedFrameRate: fps, sourceLabel: host)
    }

    private nonisolated static func resultFromConstraintEntry(_ entry: ConstraintLogEntry, request: CameraResponseRequest) -> CameraResponseResult? {
        let actual = size(in: entry.negotiatedResult) ?? (request.requestedWidth, request.requestedHeight)
        let fps = frameRate(in: entry.negotiatedResult) ?? request.requestedFrameRate
        let isExact = actual.0 == request.requestedWidth && actual.1 == request.requestedHeight && abs(fps - request.requestedFrameRate) <= 1
        return CameraResponseResult(
            request: request,
            actualWidth: actual.0,
            actualHeight: actual.1,
            actualFrameRate: fps,
            matchType: isExact ? .browserLearned : .closestDeviceMatch,
            confidence: entry.wasSuccessful ? (isExact ? 0.98 : 0.78) : 0.3,
            notes: entry.wasSuccessful ? "Learned from this site's live getUserMedia result." : (entry.fallbackReason ?? "Request failed"),
            capturedAt: entry.timestamp
        )
    }

    private nonisolated static func jsonObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private nonisolated static func intConstraint(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        if let dict = value as? [String: Any] {
            for key in ["exact", "ideal", "max", "min"] {
                if let value = intConstraint(dict[key]) { return value }
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let value = intConstraint(item) { return value }
            }
        }
        return nil
    }

    private nonisolated static func stringConstraint(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let dict = value as? [String: Any] {
            for key in ["exact", "ideal"] {
                if let value = stringConstraint(dict[key]) { return value }
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let value = stringConstraint(item) { return value }
            }
        }
        return nil
    }

    private nonisolated static func audioRequested(from value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if value is [String: Any] { return true }
        return false
    }

    private nonisolated static func size(in text: String) -> (width: Int, height: Int)? {
        if let object = jsonObject(from: text) as? [String: Any],
           let width = intConstraint(object["width"]),
           let height = intConstraint(object["height"]) {
            return (width, height)
        }
        let patterns = [
            #"width[^0-9]{0,40}(\d{2,5}).{0,120}height[^0-9]{0,40}(\d{2,5})"#,
            #"(\d{3,5})\s*[x×]\s*(\d{3,5})"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 3,
                  let wRange = Range(match.range(at: 1), in: text),
                  let hRange = Range(match.range(at: 2), in: text),
                  let width = Int(text[wRange]),
                  let height = Int(text[hRange]),
                  width >= 80,
                  height >= 60 else { continue }
            return (width, height)
        }
        return nil
    }

    private nonisolated static func singleValue(named name: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "\\\"?\(name)\\\"?[^0-9]{0,40}(\\d{2,5})", options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text),
              let value = Int(text[valueRange]) else { return nil }
        return value
    }

    private nonisolated static func frameRate(in text: String) -> Int? {
        if let object = jsonObject(from: text) as? [String: Any],
           let fps = intConstraint(object["frameRate"]) {
            return MediaConversionSpec.clampFrameRate(fps)
        }
        guard let regex = try? NSRegularExpression(pattern: #"frameRate[^0-9]{0,30}(\d{1,3})"#, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let fpsRange = Range(match.range(at: 1), in: text),
              let fps = Int(text[fpsRange]) else { return nil }
        return MediaConversionSpec.clampFrameRate(fps)
    }

    private nonisolated static func facingMode(in text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("environment") { return "environment" }
        if lower.contains("user") { return "user" }
        return nil
    }
}
