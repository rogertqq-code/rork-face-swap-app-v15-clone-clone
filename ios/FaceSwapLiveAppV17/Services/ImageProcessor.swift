import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

nonisolated struct ImageAnalysisResult: Sendable {
    let boundingBox: CGRect
    let confidence: Float
    let roll: CGFloat
    let bufferWidth: Int
    let bufferHeight: Int
    let landmarkPoints: [CGPoint]
}

nonisolated struct ImageProcessingResult: @unchecked Sendable {
    let overlay: UIImage
    let aspectRatio: CGFloat
}

nonisolated struct CaptureContext: @unchecked Sendable {
    let overlayImage: UIImage
    let overlayRect: CGRect
    let viewSize: CGSize
    let bufferSize: CGSize
    let isFrontPosition: Bool
    let sourceAspectRatio: CGFloat
}

nonisolated final class ImageProcessor: @unchecked Sendable {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func processSourceImage(_ image: UIImage) -> ImageProcessingResult? {
        let normalized = normalizeOrientation(image)
        guard let cgImage = normalized.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)

        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(ciImage: ciImage, orientation: .up)
        try? handler.perform([request])

        guard let face = request.results?.first else { return nil }

        let imageSize = ciImage.extent.size
        let faceRect = VNImageRectForNormalizedRect(face.boundingBox, Int(imageSize.width), Int(imageSize.height))

        let paddingX = faceRect.width * 0.35
        let paddingY = faceRect.height * 0.5
        var expandedRect = faceRect.insetBy(dx: -paddingX, dy: -paddingY)
        expandedRect = expandedRect.intersection(ciImage.extent)

        guard expandedRect.width > 0, expandedRect.height > 0 else { return nil }

        let cropped = ciImage
            .cropped(to: expandedRect)
            .transformed(by: CGAffineTransform(translationX: -expandedRect.origin.x, y: -expandedRect.origin.y))

        let extent = cropped.extent
        let centerX = extent.width / 2
        let centerY = extent.height / 2
        let minDim = min(extent.width, extent.height)
        let maxDim = max(extent.width, extent.height)

        let gradient = CIFilter.radialGradient()
        gradient.center = CGPoint(x: centerX, y: centerY)
        gradient.radius0 = Float(minDim * 0.35)
        gradient.radius1 = Float(maxDim * 0.55)
        gradient.color0 = CIColor.white
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let maskOutput = gradient.outputImage?.cropped(to: extent) else { return nil }

        let clearBG = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)

        let blendFilter = CIFilter.blendWithMask()
        blendFilter.inputImage = cropped
        blendFilter.backgroundImage = clearBG
        blendFilter.maskImage = maskOutput

        guard let output = blendFilter.outputImage,
              let resultCG = ciContext.createCGImage(output, from: output.extent) else { return nil }

        return ImageProcessingResult(
            overlay: UIImage(cgImage: resultCG),
            aspectRatio: extent.width / extent.height
        )
    }

    func detectFeatures(in pixelBuffer: CVPixelBuffer, isFrontPosition: Bool) -> ImageAnalysisResult? {
        let rawWidth = CVPixelBufferGetWidth(pixelBuffer)
        let rawHeight = CVPixelBufferGetHeight(pixelBuffer)

        let orientation: CGImagePropertyOrientation = isFrontPosition ? .leftMirrored : .right

        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        try? handler.perform([request])

        guard let face = request.results?
            .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
            face.confidence >= 0.45 else { return nil }

        let effectiveWidth = rawHeight
        let effectiveHeight = rawWidth

        var landmarkPoints: [CGPoint] = []
        if let landmarks = face.landmarks {
            let imageSize = CGSize(width: effectiveWidth, height: effectiveHeight)

            func addCenter(_ region: VNFaceLandmarkRegion2D?) {
                guard let region else { return }
                let pts = region.pointsInImage(imageSize: imageSize)
                guard !pts.isEmpty else { return }
                let n = CGFloat(pts.count)
                let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                landmarkPoints.append(CGPoint(
                    x: sum.x / (n * CGFloat(effectiveWidth)),
                    y: sum.y / (n * CGFloat(effectiveHeight))
                ))
            }

            addCenter(landmarks.leftEye)
            addCenter(landmarks.rightEye)
            addCenter(landmarks.nose)
            addCenter(landmarks.outerLips)
        }

        return ImageAnalysisResult(
            boundingBox: face.boundingBox,
            confidence: face.confidence,
            roll: CGFloat(face.roll?.doubleValue ?? 0),
            bufferWidth: effectiveWidth,
            bufferHeight: effectiveHeight,
            landmarkPoints: landmarkPoints
        )
    }

    func compositeCapture(pixelBuffer: CVPixelBuffer, context: CaptureContext) -> UIImage? {
        let orientation: CGImagePropertyOrientation = context.isFrontPosition ? .leftMirrored : .right
        let rawCI = CIImage(cvPixelBuffer: pixelBuffer)
        let orientedCI = rawCI.oriented(orientation)
        let ciImage = orientedCI.transformed(by: CGAffineTransform(
            translationX: -orientedCI.extent.origin.x,
            y: -orientedCI.extent.origin.y
        ))
        let imageExtent = ciImage.extent
        var output = ciImage

        guard let overlayCI = CIImage(image: context.overlayImage),
              context.overlayRect.width > 0,
              context.viewSize.width > 0,
              context.bufferSize.width > 0 else {
            guard let cgImg = ciContext.createCGImage(output, from: imageExtent) else { return nil }
            return UIImage(cgImage: cgImg)
        }

        let bw = context.bufferSize.width
        let bh = context.bufferSize.height
        let vw = context.viewSize.width
        let vh = context.viewSize.height

        let videoAspect = bw / bh
        let viewAspect = vw / vh

        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat

        if videoAspect > viewAspect {
            scale = vh / bh
            offsetX = (bw * scale - vw) / 2
            offsetY = 0
        } else {
            scale = vw / bw
            offsetX = 0
            offsetY = (bh * scale - vh) / 2
        }

        let faceRect = context.overlayRect
        let expandedWidth = faceRect.width * 1.8
        let expandedHeight = expandedWidth / context.sourceAspectRatio

        let screenCenterX = faceRect.midX
        let screenCenterY = faceRect.midY - faceRect.height * 0.03

        let pixCenterX = (screenCenterX + offsetX) / scale
        let pixCenterYTopLeft = (screenCenterY + offsetY) / scale
        let pixCenterY = bh - pixCenterYTopLeft

        let pixWidth = expandedWidth / scale
        let pixHeight = expandedHeight / scale

        let destRect = CGRect(
            x: pixCenterX - pixWidth / 2,
            y: pixCenterY - pixHeight / 2,
            width: pixWidth,
            height: pixHeight
        )

        let sx = destRect.width / overlayCI.extent.width
        let sy = destRect.height / overlayCI.extent.height

        let positioned = overlayCI
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: destRect.origin.x, y: destRect.origin.y))

        let compositeFilter = CIFilter.sourceOverCompositing()
        compositeFilter.inputImage = positioned
        compositeFilter.backgroundImage = output

        if let composited = compositeFilter.outputImage {
            output = composited
        }

        guard let cgImage = ciContext.createCGImage(output, from: imageExtent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func normalizeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
