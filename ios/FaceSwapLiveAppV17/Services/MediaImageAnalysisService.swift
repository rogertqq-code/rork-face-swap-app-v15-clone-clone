import UIKit
import Vision

nonisolated enum MediaImageAnalysisService {
    static func analyze(_ image: UIImage) -> MediaImageAnalysisReport {
        guard let cgImage = image.normalizedForAnalysis().cgImage else {
            return MediaImageAnalysisReport(confidence: 0.2, summary: "Center-safe framing")
        }

        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([faceRequest, textRequest])
        } catch {
            return fallbackReport(for: image)
        }

        let faceBoxes = (faceRequest.results ?? []).map(\.boundingBox)
        let textBoxes = (textRequest.results ?? []).map(\.boundingBox)
        let subjectBoxes = faceBoxes.isEmpty ? [] : faceBoxes
        let importantBoxes = subjectBoxes + textBoxes.prefix(4)

        guard let crop = cropRect(containing: importantBoxes, originalAspect: image.size.width / max(image.size.height, 1)) else {
            return fallbackReport(for: image, textCount: textBoxes.count)
        }

        let confidence = min(0.96, 0.52 + Double(faceBoxes.count) * 0.16 + Double(textBoxes.count) * 0.04)
        let summary: String
        if !faceBoxes.isEmpty && !textBoxes.isEmpty {
            summary = "Faces and text kept in safe frame"
        } else if !faceBoxes.isEmpty {
            summary = faceBoxes.count == 1 ? "Face-centered smart crop" : "Multi-face safe crop"
        } else if !textBoxes.isEmpty {
            summary = "Text-aware safe crop"
        } else {
            summary = "Center-safe framing"
        }

        return MediaImageAnalysisReport(
            suggestedCrop: crop,
            confidence: confidence,
            faceCount: faceBoxes.count,
            textRegionCount: textBoxes.count,
            humanRegionCount: faceBoxes.count,
            summary: summary
        )
    }

    private static func fallbackReport(for image: UIImage, textCount: Int = 0) -> MediaImageAnalysisReport {
        let isPortrait = image.size.height > image.size.width
        let crop = isPortrait
            ? NormalizedCropRect(x: 0.08, y: 0.04, width: 0.84, height: 0.88)
            : NormalizedCropRect(x: 0.10, y: 0.08, width: 0.80, height: 0.84)
        return MediaImageAnalysisReport(
            suggestedCrop: crop,
            confidence: 0.45,
            textRegionCount: textCount,
            summary: "Center-safe framing"
        )
    }

    private static func cropRect(containing boxes: [CGRect], originalAspect: CGFloat) -> NormalizedCropRect? {
        guard !boxes.isEmpty else { return nil }
        var minX: CGFloat = 1
        var minY: CGFloat = 1
        var maxX: CGFloat = 0
        var maxY: CGFloat = 0

        for box in boxes {
            minX = min(minX, box.minX)
            minY = min(minY, box.minY)
            maxX = max(maxX, box.maxX)
            maxY = max(maxY, box.maxY)
        }

        let padding: CGFloat = boxes.count > 1 ? 0.12 : 0.18
        minX = max(0, minX - padding)
        minY = max(0, minY - padding)
        maxX = min(1, maxX + padding)
        maxY = min(1, maxY + padding)

        var width = max(maxX - minX, 0.36)
        var height = max(maxY - minY, 0.36)
        let centerX = min(max((minX + maxX) / 2, width / 2), 1 - width / 2)
        let centerYVision = min(max((minY + maxY) / 2, height / 2), 1 - height / 2)

        if originalAspect > 1.1 {
            height = min(0.94, max(height, width * 0.62))
        } else if originalAspect < 0.9 {
            width = min(0.94, max(width, height * 0.62))
        }

        let x = max(0, min(centerX - width / 2, 1 - width))
        // Vision coordinates start bottom-left; the normalized crop used by UIKit starts top-left.
        let yTop = 1 - centerYVision - height / 2
        let y = max(0, min(yTop, 1 - height))

        return NormalizedCropRect(
            x: Double(x),
            y: Double(y),
            width: Double(min(width, 1 - x)),
            height: Double(min(height, 1 - y))
        )
    }
}

private extension UIImage {
    nonisolated func normalizedForAnalysis() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
