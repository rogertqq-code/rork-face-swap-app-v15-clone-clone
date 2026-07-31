import Foundation
import UIKit

/// Persists saved media sequences and templates. Full sequences copy their
/// photo/video files into the app's own storage (mirroring `VideoLibraryService`)
/// so they survive relaunches; templates store only the ordered placeholders.
@Observable
@MainActor
final class SequenceLibraryService {
    var saved: [SavedMediaSequence] = []

    private let metadataKey = "sequence_library_v1"
    private let libraryDirName = "SequenceLibrary"

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

    func existingFileURL(for fileName: String?) -> URL? {
        guard let fileName else { return nil }
        let url = fileURL(for: fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Persists a snapshot of the live steps. When `asTemplate` is true the media
    /// is intentionally dropped, leaving only the ordered placeholders.
    func save(
        name: String,
        steps: [SequenceStep],
        advanceMode: SequenceAdvanceMode,
        endBehavior: SequenceEndBehavior,
        asTemplate: Bool
    ) -> SavedMediaSequence {
        let sequenceID = UUID()
        var savedSteps: [SavedSequenceStep] = []

        for step in steps.prefix(maxSequenceSteps) {
            var mediaFileName: String?
            var thumbnailFileName: String?

            if !asTemplate {
                switch step.kind {
                case .photo:
                    if let image = step.image, let data = image.jpegData(compressionQuality: 0.92) {
                        let fileName = "\(sequenceID.uuidString)_\(step.id.uuidString).jpg"
                        try? data.write(to: fileURL(for: fileName))
                        mediaFileName = fileName
                    }
                case .video:
                    if let videoURL = step.videoURL {
                        let ext = videoURL.pathExtension.isEmpty ? "mov" : videoURL.pathExtension
                        let fileName = "\(sequenceID.uuidString)_\(step.id.uuidString).\(ext)"
                        try? FileManager.default.copyItem(at: videoURL, to: fileURL(for: fileName))
                        mediaFileName = fileName
                    }
                case .webRTCBlock, .block:
                    break
                }
            }

            savedSteps.append(
                SavedSequenceStep(
                    id: step.id,
                    kind: step.kind,
                    blockMode: step.blockMode,
                    liveCamera: step.liveCamera,
                    requestSurface: step.requestSurface,
                    mediaFileName: mediaFileName,
                    thumbnailFileName: thumbnailFileName,
                    displayName: step.displayName
                )
            )
        }

        let record = SavedMediaSequence(
            id: sequenceID,
            name: name.isEmpty ? defaultName(asTemplate: asTemplate) : name,
            isTemplate: asTemplate,
            advanceMode: advanceMode,
            endBehavior: endBehavior,
            steps: savedSteps
        )

        saved.insert(record, at: 0)
        saveMetadata()
        return record
    }

    func delete(_ record: SavedMediaSequence) {
        for step in record.steps {
            if let fileName = step.mediaFileName {
                try? FileManager.default.removeItem(at: fileURL(for: fileName))
            }
            if let thumb = step.thumbnailFileName {
                try? FileManager.default.removeItem(at: fileURL(for: thumb))
            }
        }
        saved.removeAll { $0.id == record.id }
        saveMetadata()
    }

    private func defaultName(asTemplate: Bool) -> String {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        return asTemplate ? "Template \(stamp)" : "Sequence \(stamp)"
    }

    private func loadMetadata() {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let decoded = try? JSONDecoder().decode([SavedMediaSequence].self, from: data) else { return }
        saved = decoded
    }

    private func saveMetadata() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: metadataKey)
    }
}
