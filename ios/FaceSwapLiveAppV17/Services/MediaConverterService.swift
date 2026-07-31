import AVFoundation
import UIKit
import CoreImage

nonisolated private final class UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
    nonisolated init(_ value: T) { self.value = value }
}

nonisolated final class MediaConverterService: @unchecked Sendable {
    private let processingQueue = DispatchQueue(label: "com.app.mediaconvert", qos: .userInitiated, attributes: .concurrent)

    func convertImage(_ image: UIImage, spec: MediaConversionSpec) -> UIImage {
        renderImage(image, width: spec.targetWidth, height: spec.targetHeight, mode: .fillCrop, cropRect: .full)
    }

    func renderImage(
        _ image: UIImage,
        width: Int,
        height: Int,
        mode: MediaResizeMode,
        cropRect: NormalizedCropRect = .full
    ) -> UIImage {
        let targetSize = CGSize(width: max(width, 1), height: max(height, 1))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { ctx in
            ctx.cgContext.setFillColor(UIColor.black.cgColor)
            ctx.cgContext.fill(CGRect(origin: .zero, size: targetSize))

            let normalized = image.normalizedOrientationImage()
            let sourceImage = normalized.cropped(to: cropRect) ?? normalized
            let imageSize = sourceImage.size
            guard imageSize.width > 0, imageSize.height > 0 else { return }

            let drawRect = drawRectForMedia(sourceSize: imageSize, targetSize: targetSize, mode: mode)
            sourceImage.draw(in: drawRect)

            if mode == .squareSafe {
                let safeSide = min(targetSize.width, targetSize.height)
                let safeRect = CGRect(
                    x: (targetSize.width - safeSide) / 2,
                    y: (targetSize.height - safeSide) / 2,
                    width: safeSide,
                    height: safeSide
                )
                ctx.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.18).cgColor)
                ctx.cgContext.setLineWidth(2)
                ctx.cgContext.stroke(safeRect)
            }
        }
    }

    func convertVideo(_ inputURL: URL, spec: MediaConversionSpec) async -> URL? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("converted_\(UUID().uuidString).mov")
        let success = await convertVideoWithProgress(inputURL, spec: spec, outputURL: outputURL, onProgress: nil)
        return success ? outputURL : nil
    }

    func convertVideoWithProgress(
        _ inputURL: URL,
        spec: MediaConversionSpec,
        outputURL: URL,
        onProgress: ((Double) -> Void)?
    ) async -> Bool {
        await convertVideoWithProgress(inputURL, spec: spec, outputURL: outputURL, resizeMode: .fillCrop, cropRect: .full, onProgress: onProgress)
    }

    func convertVideoWithProgress(
        _ inputURL: URL,
        spec: MediaConversionSpec,
        outputURL: URL,
        resizeMode: MediaResizeMode,
        cropRect: NormalizedCropRect = .full,
        onProgress: ((Double) -> Void)?
    ) async -> Bool {
        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else { return false }

        let totalDuration = (try? await asset.load(.duration)) ?? .zero
        let totalSeconds = CMTimeGetSeconds(totalDuration)
        guard totalSeconds > 0 else { return false }

        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let rotationEpsilon: CGFloat = 0.001
        let isPortrait = abs(abs(transform.b) - 1) < rotationEpsilon && abs(abs(transform.c) - 1) < rotationEpsilon

        let targetWidth = spec.targetWidth
        let targetHeight = spec.targetHeight

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let reader = try? AVAssetReader(asset: asset) else { return false }

        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { return false }
        reader.add(readerOutput)

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else { return false }

        let codec: AVVideoCodecType = spec.targetCodec == "hevc" ? .hevc : .h264
        var compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: spec.targetBitrate,
            AVVideoExpectedSourceFrameRateKey: spec.targetFrameRate,
            AVVideoMaxKeyFrameIntervalKey: spec.targetFrameRate
        ]

        if let profileLevel = spec.targetProfileLevel {
            compressionProps[AVVideoProfileLevelKey] = profileLevel
        }

        var writerSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: compressionProps
        ]

        if let colorPrimaries = spec.targetColorPrimaries,
           let transferFunc = spec.targetTransferFunction,
           let colorMatrix = spec.targetColorMatrix {
            writerSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: colorPrimaries,
                AVVideoTransferFunctionKey: transferFunc,
                AVVideoYCbCrMatrixKey: colorMatrix
            ]
        }

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = .identity

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: targetWidth,
                kCVPixelBufferHeightKey as String: targetHeight
            ]
        )

        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)

        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var audioWriterInput: AVAssetWriterInput?

        if let audioTrack {
            let audioReadSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let aro = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioReadSettings)
            aro.alwaysCopiesSampleData = false
            if reader.canAdd(aro) {
                reader.add(aro)
                audioReaderOutput = aro
            }

            let audioWriteSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000
            ]
            let awi = AVAssetWriterInput(mediaType: .audio, outputSettings: audioWriteSettings)
            awi.expectsMediaDataInRealTime = false
            if writer.canAdd(awi) {
                writer.add(awi)
                audioWriterInput = awi
            }
        }

        guard reader.startReading() else { return false }
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(spec.targetFrameRate))
        let capturedIsPortrait = isPortrait
        let capturedTotalSeconds = totalSeconds
        let capturedResizeMode = resizeMode
        let capturedCropRect = cropRect

        let boxedReader = UnsafeSendableBox(reader)
        let boxedWriterInput = UnsafeSendableBox(writerInput)
        let boxedReaderOutput = UnsafeSendableBox(readerOutput)
        let boxedAdaptor = UnsafeSendableBox(adaptor)
        let boxedAudioReaderOutput = UnsafeSendableBox(audioReaderOutput)
        let boxedAudioWriterInput = UnsafeSendableBox(audioWriterInput)
        let boxedWriter = UnsafeSendableBox(writer)

        return await withCheckedContinuation { continuation in
            processingQueue.async {
                let _reader = boxedReader.value
                let _writerInput = boxedWriterInput.value
                let _readerOutput = boxedReaderOutput.value
                let _adaptor = boxedAdaptor.value
                let _audioReaderOutput = boxedAudioReaderOutput.value
                let _audioWriterInput = boxedAudioWriterInput.value
                let _writer = boxedWriter.value
                var frameIndex: Int64 = 0
                var lastProgressUpdate: Double = -1

                while _reader.status == .reading {
                    if !_writerInput.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.005)
                        continue
                    }

                    guard let sampleBuffer = _readerOutput.copyNextSampleBuffer() else { break }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let currentSeconds = CMTimeGetSeconds(pts)
                    let progress = min(currentSeconds / capturedTotalSeconds, 1.0)

                    if progress - lastProgressUpdate >= 0.02 {
                        lastProgressUpdate = progress
                        onProgress?(progress)
                    }

                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

                    var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

                    if capturedIsPortrait {
                        ciImage = ciImage.oriented(.right)
                    }

                    ciImage = self.prepareFrame(ciImage, width: targetWidth, height: targetHeight, mode: capturedResizeMode, cropRect: capturedCropRect)

                    guard let pool = _adaptor.pixelBufferPool else { continue }
                    var outBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                    guard let outputBuffer = outBuffer else { continue }

                    ciContext.render(ciImage, to: outputBuffer)

                    let outputPTS = CMTime(value: frameIndex, timescale: frameDuration.timescale)
                    _adaptor.append(outputBuffer, withPresentationTime: outputPTS)
                    frameIndex += 1
                }

                _writerInput.markAsFinished()

                if let aro = _audioReaderOutput, let awi = _audioWriterInput {
                    while _reader.status == .reading {
                        if !awi.isReadyForMoreMediaData {
                            Thread.sleep(forTimeInterval: 0.005)
                            continue
                        }
                        guard let sample = aro.copyNextSampleBuffer() else { break }
                        awi.append(sample)
                    }
                    awi.markAsFinished()
                }

                let group = DispatchGroup()
                group.enter()
                _writer.finishWriting {
                    group.leave()
                }
                group.wait()

                onProgress?(1.0)
                continuation.resume(returning: _writer.status == .completed)
            }
        }
    }

    func resizeImageForInjection(_ image: UIImage, spec: MediaConversionSpec) -> UIImage {
        renderImage(image, width: spec.targetWidth, height: spec.targetHeight, mode: .fillCrop)
    }

    // MARK: - Phased Transcoding

    func convertVideoWithPhases(
        _ inputURL: URL,
        spec: MediaConversionSpec,
        outputURL: URL,
        onPhase: ((TranscodeProgress) -> Void)?
    ) async -> Bool {
        onPhase?(TranscodeProgress(currentPhase: .analysis, phaseProgress: 0, overallProgress: 0, phaseDetails: "Analyzing source media…"))

        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { return false }

        let totalDuration = (try? await asset.load(.duration)) ?? .zero
        let totalSeconds = CMTimeGetSeconds(totalDuration)
        guard totalSeconds > 0 else { return false }

        onPhase?(TranscodeProgress(currentPhase: .analysis, phaseProgress: 1.0, overallProgress: 0.05, phaseDetails: "Source: \(Int(totalSeconds))s"))

        onPhase?(TranscodeProgress(currentPhase: .audioPrep, phaseProgress: 0, overallProgress: 0.08, phaseDetails: "Preparing audio track…"))
        let hasAudio = (try? await asset.loadTracks(withMediaType: .audio).first) != nil
        onPhase?(TranscodeProgress(currentPhase: .audioPrep, phaseProgress: 1.0, overallProgress: 0.10, phaseDetails: hasAudio ? "Audio track found" : "No audio track"))
        onPhase?(TranscodeProgress(currentPhase: .videoEncode, phaseProgress: 0, overallProgress: 0.12, phaseDetails: "Encoding \(spec.targetWidth)×\(spec.targetHeight) @\(spec.targetFrameRate)fps…"))

        let success = await convertVideoWithProgress(inputURL, spec: spec, outputURL: outputURL) { progress in
            let overall = 0.12 + (progress * 0.70)
            onPhase?(TranscodeProgress(currentPhase: .videoEncode, phaseProgress: progress, overallProgress: overall, phaseDetails: "Encoding: \(Int(progress * 100))%"))
        }

        guard success else {
            onPhase?(TranscodeProgress(currentPhase: .videoEncode, phaseProgress: 1.0, overallProgress: 0.82, phaseDetails: "Encoding failed"))
            return false
        }

        onPhase?(TranscodeProgress(currentPhase: .muxing, phaseProgress: 1.0, overallProgress: 0.85, phaseDetails: "Muxing complete"))
        onPhase?(TranscodeProgress(currentPhase: .verification, phaseProgress: 0, overallProgress: 0.88, phaseDetails: "Verifying output…"))
        let verified = await verifyOutput(at: outputURL, spec: spec)
        onPhase?(TranscodeProgress(currentPhase: .verification, phaseProgress: 1.0, overallProgress: 0.95, phaseDetails: verified ? "Verification passed" : "Verification warning: output may not match spec"))
        onPhase?(TranscodeProgress(currentPhase: .librarySave, phaseProgress: 1.0, overallProgress: 1.0, phaseDetails: "Ready"))

        return success
    }

    // MARK: - Post-Transcode Verification

    func verifyOutput(at url: URL, spec: MediaConversionSpec) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else { return false }

        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let rotationEpsilon: CGFloat = 0.001
        let isPortrait = abs(abs(transform.b) - 1) < rotationEpsilon && abs(abs(transform.c) - 1) < rotationEpsilon
        let width = Int(isPortrait ? naturalSize.height : naturalSize.width)
        let height = Int(isPortrait ? naturalSize.width : naturalSize.height)

        let widthOK = abs(width - spec.targetWidth) <= 2
        let heightOK = abs(height - spec.targetHeight) <= 2

        let duration = (try? await asset.load(.duration)) ?? .zero
        let durationOK = CMTimeGetSeconds(duration) > 0

        return widthOK && heightOK && durationOK
    }

    private func drawRectForMedia(sourceSize: CGSize, targetSize: CGSize, mode: MediaResizeMode) -> CGRect {
        let imageAspect = sourceSize.width / sourceSize.height
        let targetAspect = targetSize.width / targetSize.height

        switch mode {
        case .fillCrop, .squareSafe:
            if imageAspect > targetAspect {
                let height = targetSize.height
                let width = height * imageAspect
                return CGRect(x: (targetSize.width - width) / 2, y: 0, width: width, height: height)
            }
            let width = targetSize.width
            let height = width / imageAspect
            return CGRect(x: 0, y: (targetSize.height - height) / 2, width: width, height: height)
        case .fitWithBars:
            if imageAspect > targetAspect {
                let width = targetSize.width
                let height = width / imageAspect
                return CGRect(x: 0, y: (targetSize.height - height) / 2, width: width, height: height)
            }
            let height = targetSize.height
            let width = height * imageAspect
            return CGRect(x: (targetSize.width - width) / 2, y: 0, width: width, height: height)
        case .stretch:
            return CGRect(origin: .zero, size: targetSize)
        }
    }

    private func prepareFrame(_ image: CIImage, width: Int, height: Int, mode: MediaResizeMode, cropRect: NormalizedCropRect) -> CIImage {
        let targetWidth = CGFloat(max(width, 1))
        let targetHeight = CGFloat(max(height, 1))
        let originalExtent = image.extent
        let cropX = originalExtent.minX + originalExtent.width * CGFloat(max(0, min(cropRect.x, 1)))
        let cropY = originalExtent.minY + originalExtent.height * CGFloat(max(0, min(cropRect.y, 1)))
        let cropW = originalExtent.width * CGFloat(max(0.05, min(cropRect.width, 1)))
        let cropH = originalExtent.height * CGFloat(max(0.05, min(cropRect.height, 1)))
        let crop = CGRect(
            x: cropX,
            y: cropY,
            width: min(cropW, originalExtent.maxX - cropX),
            height: min(cropH, originalExtent.maxY - cropY)
        ).intersection(originalExtent)

        var output = image
        if !crop.isNull, crop.width > 1, crop.height > 1 {
            output = output.cropped(to: crop)
        }

        let extent = output.extent
        guard extent.width > 0, extent.height > 0 else {
            return CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        }

        if mode == .stretch {
            output = output
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: targetWidth / extent.width, y: targetHeight / extent.height))
            return output.cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        }

        let scale: CGFloat = mode == .fitWithBars ? min(targetWidth / extent.width, targetHeight / extent.height) : max(targetWidth / extent.width, targetHeight / extent.height)
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        let offsetX = (targetWidth - scaledWidth) / 2
        let offsetY = (targetHeight - scaledHeight) / 2

        let background = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        output = output
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            .cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        if mode == .fitWithBars {
            return output.composited(over: background)
        }
        return output
    }
}

private extension UIImage {
    nonisolated func normalizedOrientationImage() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    nonisolated func cropped(to rect: NormalizedCropRect) -> UIImage? {
        let clampedX = max(0, min(rect.x, 1))
        let clampedY = max(0, min(rect.y, 1))
        let clampedW = max(0.05, min(rect.width, 1 - clampedX))
        let clampedH = max(0.05, min(rect.height, 1 - clampedY))
        let cropRect = CGRect(
            x: size.width * clampedX * scale,
            y: size.height * clampedY * scale,
            width: size.width * clampedW * scale,
            height: size.height * clampedH * scale
        )
        guard let cgImage,
              let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
    }
}
