import AVFoundation
import CoreVideo
import Foundation
import UIKit

@MainActor
enum PlainMockFrameRenderer {
    static func normalizedImage(_ source: UIImage) -> UIImage {
        let normalized = source.normalizedForInjection()
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: normalized.size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: normalized.size)
            UIColor.black.setFill()
            context.fill(bounds)
            normalized.draw(in: bounds)
        }
    }

    static func generatedFrame(size: CGSize, frameIndex: Int) -> UIImage {
        let renderSize = CGSize(
            width: max(32, size.width.rounded(.down)),
            height: max(24, size.height.rounded(.down))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: renderSize, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: renderSize)
            UIColor(red: 0.06, green: 0.10, blue: 0.18, alpha: 1).setFill()
            context.fill(bounds)

            let colors: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
            let barWidth = renderSize.width / CGFloat(colors.count)
            for (index, color) in colors.enumerated() {
                color.withAlphaComponent(0.72).setFill()
                context.fill(CGRect(
                    x: CGFloat(index) * barWidth,
                    y: 0,
                    width: barWidth + 1,
                    height: renderSize.height
                ))
            }

            let pulse = CGFloat(frameIndex % 60) / 60
            UIColor.white.withAlphaComponent(0.22).setFill()
            context.fill(CGRect(
                x: pulse * max(1, renderSize.width - 24),
                y: 0,
                width: 24,
                height: renderSize.height
            ))
        }
    }
}

@MainActor
final class MockMediaFixtureFactory {
    enum FixtureError: Error, LocalizedError {
        case imageEncodingFailed
        case pixelBufferAllocationFailed
        case videoWriterCreationFailed(String)
        case videoWriterStartFailed(String)
        case videoFrameAppendFailed(Int)
        case videoWriterFinishFailed(String)

        var errorDescription: String? {
            switch self {
            case .imageEncodingFailed:
                "The mock still could not be encoded."
            case .pixelBufferAllocationFailed:
                "A mock video frame buffer could not be allocated."
            case .videoWriterCreationFailed(let detail):
                "The mock video writer could not be created: \(detail)"
            case .videoWriterStartFailed(let detail):
                "The mock video writer could not start: \(detail)"
            case .videoFrameAppendFailed(let index):
                "Mock video frame \(index) could not be appended."
            case .videoWriterFinishFailed(let detail):
                "The mock video could not be finalized: \(detail)"
            }
        }
    }

    private let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("FSLMockMedia", isDirectory: true)
    }

    func makeStillFixture(
        size: MediaDimensions = MediaDimensions(width: 640, height: 480),
        frameIndex: Int = 0
    ) throws -> MediaSourceDescriptor {
        let image = PlainMockFrameRenderer.generatedFrame(
            size: CGSize(width: CGFloat(size.width), height: CGFloat(size.height)),
            frameIndex: frameIndex
        )
        return try writeStill(image, dimensions: size)
    }

    func makeFrameFixture(
        size: MediaDimensions = MediaDimensions(width: 640, height: 480),
        frameIndex: Int
    ) throws -> MediaSourceDescriptor {
        try makeStillFixture(size: size, frameIndex: frameIndex)
    }

    func makeStillFixture(from source: UIImage) throws -> MediaSourceDescriptor {
        let image = PlainMockFrameRenderer.normalizedImage(source)
        return try writeStill(
            image,
            dimensions: MediaDimensions(
                width: Int(image.size.width.rounded()),
                height: Int(image.size.height.rounded())
            )
        )
    }

    func makeVideoFixture(
        size: MediaDimensions = MediaDimensions(width: 640, height: 480),
        frameRate: Int = 15,
        duration: TimeInterval = 2
    ) async throws -> MediaSourceDescriptor {
        try ensureDirectory()
        let outputURL = rootDirectory.appendingPathComponent("qa-media-\(UUID().uuidString).mp4")
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw FixtureError.videoWriterCreationFailed(error.localizedDescription)
        }
        let fps = max(1, min(frameRate, 60))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
            ]
        )
        guard writer.canAdd(input) else {
            throw FixtureError.videoWriterCreationFailed("The writer rejected its video input.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.videoWriterStartFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(1, Int((duration * Double(fps)).rounded(.up)))
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let image = PlainMockFrameRenderer.generatedFrame(
                size: CGSize(width: CGFloat(size.width), height: CGFloat(size.height)),
                frameIndex: index
            )
            guard let pixelBuffer = try makePixelBuffer(from: image, size: size),
                  adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) else {
                writer.cancelWriting()
                throw FixtureError.videoFrameAppendFailed(index)
            }
            await Task.yield()
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw FixtureError.videoWriterFinishFailed(writer.error?.localizedDescription ?? "unknown error")
        }

        return MediaSourceDescriptor(
            kind: .mockVideo,
            contentType: "video/mp4",
            resourceURL: outputURL,
            filename: outputURL.lastPathComponent,
            dimensions: size,
            duration: duration,
            isMock: true
        )
    }

    func removeFixture(_ source: MediaSourceDescriptor) {
        guard source.isMock, source.resourceURL.isFileURL else { return }
        try? FileManager.default.removeItem(at: source.resourceURL)
    }

    func removeAllFixtures() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    private func writeStill(_ image: UIImage, dimensions: MediaDimensions) throws -> MediaSourceDescriptor {
        try ensureDirectory()
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw FixtureError.imageEncodingFailed
        }
        let url = rootDirectory.appendingPathComponent("qa-media-\(UUID().uuidString).jpg")
        try data.write(to: url, options: .atomic)
        return MediaSourceDescriptor(
            kind: .mockStill,
            contentType: "image/jpeg",
            resourceURL: url,
            filename: url.lastPathComponent,
            dimensions: dimensions,
            isMock: true
        )
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    private func makePixelBuffer(from image: UIImage, size: MediaDimensions) throws -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            size.width,
            size.height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer, let cgImage = image.cgImage else {
            throw FixtureError.pixelBufferAllocationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: baseAddress,
                width: size.width,
                height: size.height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            throw FixtureError.pixelBufferAllocationFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height)))
        context.translateBy(x: 0, y: CGFloat(size.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height)))
        return pixelBuffer
    }
}
