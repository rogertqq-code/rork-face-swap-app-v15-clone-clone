import Foundation
@preconcurrency import AVFoundation
import UIKit

@Observable
@MainActor
final class VideoLibraryService {
    var videos: [SavedVideo] = []

    private let metadataKey = "video_library_v1"
    private let libraryDirName = "VideoLibrary"
    private let converter = MediaConverterService()

    var libraryDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(libraryDirName)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    init() {
        loadMetadata()
    }

    func fileURL(for fileName: String) -> URL {
        libraryDirectory.appendingPathComponent(fileName)
    }

    func mediaURL(for media: SavedVideo) -> URL? {
        let url = fileURL(for: media.originalFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func variantURL(for variant: SavedMediaVariant) -> URL? {
        let url = fileURL(for: variant.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func variantThumbnailURL(for variant: SavedMediaVariant) -> URL? {
        guard let fileName = variant.thumbnailFileName else { return nil }
        let url = fileURL(for: fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func frontVideoURL(for video: SavedVideo) -> URL? {
        if let variant = video.allVariants.first(where: { $0.kind == .video && $0.target == .front }) {
            return variantURL(for: variant)
        }
        guard let name = video.frontCameraFileName else { return nil }
        let url = fileURL(for: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func backVideoURL(for video: SavedVideo) -> URL? {
        if let variant = video.allVariants.first(where: { $0.kind == .video && $0.target == .back }) {
            return variantURL(for: variant)
        }
        guard let name = video.backCameraFileName else { return nil }
        let url = fileURL(for: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func thumbnailURL(for video: SavedVideo) -> URL? {
        guard let name = video.thumbnailFileName else { return nil }
        let url = fileURL(for: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func thumbnailImage(for media: SavedVideo) -> UIImage? {
        guard let url = thumbnailURL(for: media),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func variantThumbnailImage(for variant: SavedMediaVariant) -> UIImage? {
        if let url = variantThumbnailURL(for: variant),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            return image
        }
        if variant.kind == .image,
           let url = variantURL(for: variant),
           let data = try? Data(contentsOf: url) {
            return UIImage(data: data)
        }
        return nil
    }

    func importImage(data: Data, name: String) async -> SavedVideo? {
        guard let image = UIImage(data: data) else { return nil }
        let mediaID = UUID()
        let originalFileName = "\(mediaID.uuidString)_original.jpg"
        let originalURL = fileURL(for: originalFileName)
        let normalized = converter.renderImage(image, width: Int(image.size.width), height: Int(image.size.height), mode: .stretch)
        guard let jpeg = normalized.jpegData(compressionQuality: 0.94) else { return nil }

        do {
            try jpeg.write(to: originalURL)
        } catch {
            return nil
        }

        let thumbnailFileName = writeThumbnail(normalized, id: mediaID)
        let fileSize = fileSize(at: originalURL)
        let analysis = MediaImageAnalysisService.analyze(normalized)
        let media = SavedVideo(
            id: mediaID,
            name: name.isEmpty ? "Imported Image" : name,
            originalFileName: originalFileName,
            originalWidth: Int(normalized.size.width),
            originalHeight: Int(normalized.size.height),
            originalDuration: 0,
            thumbnailFileName: thumbnailFileName,
            fileSizeBytes: fileSize,
            mediaKind: .image,
            variants: [],
            imageAnalysis: analysis
        )
        videos.insert(media, at: 0)
        saveMetadata()
        return media
    }

    func importVideo(
        sourceURL: URL,
        name: String,
        profile: DeviceProfile?,
        onProgress: @escaping @MainActor (Double, String) -> Void
    ) async -> SavedVideo? {
        let mediaID = UUID()
        let originalExt = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let originalFileName = "\(mediaID.uuidString)_original.\(originalExt)"
        let originalDest = fileURL(for: originalFileName)

        do {
            if FileManager.default.fileExists(atPath: originalDest.path) {
                try FileManager.default.removeItem(at: originalDest)
            }
            try FileManager.default.copyItem(at: sourceURL, to: originalDest)
        } catch {
            return nil
        }

        let asset = AVURLAsset(url: originalDest)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let dimensions = await videoDimensions(for: originalDest)
        let fileSize = fileSize(at: originalDest)
        let thumbnail = await generateThumbnail(from: originalDest)
        let thumbnailFileName = thumbnail.flatMap { writeThumbnail($0, id: mediaID) }

        var savedVideo = SavedVideo(
            id: mediaID,
            name: name.isEmpty ? "Imported Video" : name,
            originalFileName: originalFileName,
            originalWidth: dimensions.width,
            originalHeight: dimensions.height,
            originalDuration: duration,
            thumbnailFileName: thumbnailFileName,
            fileSizeBytes: fileSize,
            mediaKind: .video,
            variants: []
        )

        // Backwards-compatible automatic front/back variants for existing flows.
        if let profile {
            if let backCam = profile.backCamera {
                let spec = profile.conversionSpec(for: backCam)
                let preset = MediaVariantPreset(target: .back, width: spec.targetWidth, height: spec.targetHeight, frameRate: spec.targetFrameRate, sourceGroup: .backCamera, sourceLabel: backCam.label)
                let variant = await createVideoVariant(
                    mediaID: mediaID,
                    sourceURL: originalDest,
                    preset: preset,
                    spec: spec,
                    resizeMode: .fillCrop,
                    cropRect: .full
                ) { progress in
                    Task { @MainActor in onProgress(progress * 0.5, "Back camera: \(Int(progress * 100))%") }
                }
                if let variant {
                    savedVideo.backCameraFileName = variant.fileName
                    savedVideo.backSpec = variant.specLabel
                    savedVideo.variants = (savedVideo.variants ?? []) + [variant]
                }
            }
            if let frontCam = profile.frontCamera {
                let spec = profile.conversionSpec(for: frontCam)
                let preset = MediaVariantPreset(target: .front, width: spec.targetWidth, height: spec.targetHeight, frameRate: spec.targetFrameRate, sourceGroup: .frontCamera, sourceLabel: frontCam.label)
                let variant = await createVideoVariant(
                    mediaID: mediaID,
                    sourceURL: originalDest,
                    preset: preset,
                    spec: spec,
                    resizeMode: .fillCrop,
                    cropRect: .full
                ) { progress in
                    Task { @MainActor in onProgress(0.5 + progress * 0.5, "Front camera: \(Int(progress * 100))%") }
                }
                if let variant {
                    savedVideo.frontCameraFileName = variant.fileName
                    savedVideo.frontSpec = variant.specLabel
                    savedVideo.variants = (savedVideo.variants ?? []) + [variant]
                }
            }
        }

        await onProgress(1.0, "Complete")
        videos.insert(savedVideo, at: 0)
        saveMetadata()
        return savedVideo
    }

    func generateVariant(
        for media: SavedVideo,
        preset: MediaVariantPreset,
        resizeMode: MediaResizeMode,
        cropRect: NormalizedCropRect,
        profile: DeviceProfile?,
        onProgress: @escaping @MainActor (Double, String) -> Void
    ) async -> SavedMediaVariant? {
        guard let sourceURL = mediaURL(for: media) else { return nil }
        let spec = SmartMediaPresetService.spec(from: preset, profile: profile)
        await onProgress(0.02, "Preparing \(preset.specLabel)…")

        let variant: SavedMediaVariant?
        switch media.resolvedKind {
        case .image:
            variant = createImageVariant(media: media, sourceURL: sourceURL, preset: preset, spec: spec, resizeMode: resizeMode, cropRect: cropRect)
        case .video:
            variant = await createVideoVariant(mediaID: media.id, sourceURL: sourceURL, preset: preset, spec: spec, resizeMode: resizeMode, cropRect: cropRect) { progress in
                Task { @MainActor in onProgress(progress, "Encoding \(preset.specLabel): \(Int(progress * 100))%") }
            }
        }

        guard let variant else { return nil }
        if let index = videos.firstIndex(where: { $0.id == media.id }) {
            var variants = videos[index].variants ?? []
            let replacedVariants = variants.filter {
                $0.kind == variant.kind &&
                $0.width == variant.width &&
                $0.height == variant.height &&
                $0.target == variant.target &&
                $0.resizeMode == variant.resizeMode &&
                $0.sourceGroup == variant.sourceGroup
            }
            variants.removeAll { existing in
                replacedVariants.contains { $0.id == existing.id }
            }
            for replaced in replacedVariants {
                removeVariantFiles(replaced)
            }
            variants.append(variant)
            videos[index].variants = variants.sorted { $0.createdAt > $1.createdAt }
            if variant.kind == .video {
                if variant.target == .front {
                    videos[index].frontCameraFileName = variant.fileName
                    videos[index].frontSpec = variant.specLabel
                } else if variant.target == .back {
                    videos[index].backCameraFileName = variant.fileName
                    videos[index].backSpec = variant.specLabel
                }
            }
            saveMetadata()
        }
        await onProgress(1.0, "Variant ready")
        return variant
    }

    func deleteVideo(_ video: SavedVideo) {
        var filesToRemove = [
            video.originalFileName,
            video.frontCameraFileName,
            video.backCameraFileName,
            video.thumbnailFileName
        ].compactMap { $0 }

        for variant in video.allVariants {
            filesToRemove.append(variant.fileName)
            if let thumb = variant.thumbnailFileName { filesToRemove.append(thumb) }
        }

        for fileName in Set(filesToRemove) {
            try? FileManager.default.removeItem(at: fileURL(for: fileName))
        }

        videos.removeAll { $0.id == video.id }
        saveMetadata()
    }

    func deleteVariant(_ variant: SavedMediaVariant) {
        removeVariantFiles(variant)
        guard let mediaIndex = videos.firstIndex(where: { $0.id == variant.mediaID }) else { return }
        videos[mediaIndex].variants = videos[mediaIndex].allVariants.filter { $0.id != variant.id }
        if videos[mediaIndex].frontCameraFileName == variant.fileName { videos[mediaIndex].frontCameraFileName = nil }
        if videos[mediaIndex].backCameraFileName == variant.fileName { videos[mediaIndex].backCameraFileName = nil }
        saveMetadata()
    }

    func renameVideo(_ video: SavedVideo, to newName: String) {
        guard let idx = videos.firstIndex(where: { $0.id == video.id }) else { return }
        videos[idx].name = newName
        saveMetadata()
    }

    private func removeVariantFiles(_ variant: SavedMediaVariant) {
        try? FileManager.default.removeItem(at: fileURL(for: variant.fileName))
        if let thumb = variant.thumbnailFileName {
            try? FileManager.default.removeItem(at: fileURL(for: thumb))
        }
    }

    private func createImageVariant(
        media: SavedVideo,
        sourceURL: URL,
        preset: MediaVariantPreset,
        spec: MediaConversionSpec,
        resizeMode: MediaResizeMode,
        cropRect: NormalizedCropRect
    ) -> SavedMediaVariant? {
        guard let data = try? Data(contentsOf: sourceURL), let image = UIImage(data: data) else { return nil }
        let rendered = converter.renderImage(image, width: spec.targetWidth, height: spec.targetHeight, mode: resizeMode, cropRect: cropRect)
        let variantID = UUID()
        let fileName = "\(media.id.uuidString)_\(variantID.uuidString)_\(preset.width)x\(preset.height).jpg"
        let url = fileURL(for: fileName)
        guard let jpeg = rendered.jpegData(compressionQuality: 0.92) else { return nil }
        do {
            try jpeg.write(to: url)
        } catch {
            return nil
        }
        let thumb = writeThumbnail(rendered, id: variantID)
        return SavedMediaVariant(
            id: variantID,
            mediaID: media.id,
            kind: .image,
            target: preset.target,
            fileName: fileName,
            thumbnailFileName: thumb,
            displayName: "\(media.name) · \(preset.sourceLabel)",
            width: spec.targetWidth,
            height: spec.targetHeight,
            frameRate: spec.targetFrameRate,
            resizeMode: resizeMode,
            sourceGroup: preset.sourceGroup,
            sourceLabel: preset.sourceLabel,
            cropRect: cropRect,
            fileSizeBytes: fileSize(at: url),
            requestedWidth: preset.responseResult?.request.requestedWidth,
            requestedHeight: preset.responseResult?.request.requestedHeight,
            requestedFrameRate: preset.responseResult?.request.requestedFrameRate,
            responseSurface: preset.responseResult?.request.surface,
            responseMatchType: preset.responseResult?.matchType,
            responseConfidence: preset.responseResult?.confidence,
            responseNotes: preset.responseResult?.notes
        )
    }

    private func createVideoVariant(
        mediaID: UUID,
        sourceURL: URL,
        preset: MediaVariantPreset,
        spec: MediaConversionSpec,
        resizeMode: MediaResizeMode,
        cropRect: NormalizedCropRect,
        onProgress: ((Double) -> Void)?
    ) async -> SavedMediaVariant? {
        let variantID = UUID()
        let fileName = "\(mediaID.uuidString)_\(variantID.uuidString)_\(preset.width)x\(preset.height).mov"
        let outputURL = fileURL(for: fileName)
        let success = await converter.convertVideoWithProgress(sourceURL, spec: spec, outputURL: outputURL, resizeMode: resizeMode, cropRect: cropRect, onProgress: onProgress)
        guard success else { return nil }
        let thumbnail = await generateThumbnail(from: outputURL)
        let thumbName = thumbnail.flatMap { writeThumbnail($0, id: variantID) }
        return SavedMediaVariant(
            id: variantID,
            mediaID: mediaID,
            kind: .video,
            target: preset.target,
            fileName: fileName,
            thumbnailFileName: thumbName,
            displayName: preset.sourceLabel,
            width: spec.targetWidth,
            height: spec.targetHeight,
            frameRate: spec.targetFrameRate,
            resizeMode: resizeMode,
            sourceGroup: preset.sourceGroup,
            sourceLabel: preset.sourceLabel,
            cropRect: cropRect,
            fileSizeBytes: fileSize(at: outputURL),
            requestedWidth: preset.responseResult?.request.requestedWidth,
            requestedHeight: preset.responseResult?.request.requestedHeight,
            requestedFrameRate: preset.responseResult?.request.requestedFrameRate,
            responseSurface: preset.responseResult?.request.surface,
            responseMatchType: preset.responseResult?.matchType,
            responseConfidence: preset.responseResult?.confidence,
            responseNotes: preset.responseResult?.notes
        )
    }

    private func generateThumbnail(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 500, height: 500)

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        return try? await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, error in
                if let image {
                    continuation.resume(returning: UIImage(cgImage: image))
                } else {
                    continuation.resume(throwing: error ?? URLError(.unknown))
                }
            }
        }
    }

    private func writeThumbnail(_ image: UIImage, id: UUID) -> String? {
        let thumbName = "\(id.uuidString)_thumb.jpg"
        let thumbURL = fileURL(for: thumbName)
        let thumb = converter.renderImage(image, width: 480, height: 360, mode: .fillCrop)
        guard let data = thumb.jpegData(compressionQuality: 0.72) else { return nil }
        do {
            try data.write(to: thumbURL)
            return thumbName
        } catch {
            return nil
        }
    }

    private func videoDimensions(for url: URL) async -> (width: Int, height: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return (0, 0) }
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        // Use an epsilon instead of exact float equality: preferredTransform
        // values for 90/270 rotations can be 0.9999… and miss `== 1`, which
        // would report swapped (wrong) dimensions for rotated clips.
        let rotationEpsilon: CGFloat = 0.001
        let isPortrait = abs(abs(transform.b) - 1) < rotationEpsilon && abs(abs(transform.c) - 1) < rotationEpsilon
        return (Int(isPortrait ? size.height : size.width), Int(isPortrait ? size.width : size.height))
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func loadMetadata() {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let decoded = try? JSONDecoder().decode([SavedVideo].self, from: data) else { return }
        videos = decoded.map { media in
            var updated = media
            if updated.mediaKind == nil { updated.mediaKind = .video }
            if updated.variants == nil { updated.variants = [] }
            if updated.imageAnalysis == nil, updated.isImage, let image = thumbnailImage(for: updated) {
                updated.imageAnalysis = MediaImageAnalysisService.analyze(image)
            }
            return updated
        }
    }

    private func saveMetadata() {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        UserDefaults.standard.set(data, forKey: metadataKey)
    }
}
