import Foundation

/// Heavy media payloads used by the in-page sequence renderer.
///
/// This cache deliberately lives outside `SequenceStep` so large base64 strings
/// do not sit inside observable UI state or get copied every time SwiftUI reads
/// a sequence step.
@MainActor
final class SequencePayloadCache {
    struct Entry {
        var pixelBase64: String?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var jpegBase64: String?
        var jpegMime: String?
        /// Re-encoded JPEG with metadata stripped, mimicking a photo Safari
        /// hands to a file input after a live camera capture. Served to native
        /// camera-capture requests; the full-EXIF `jpegBase64` serves library picks.
        var strippedJpegBase64: String?
        var firstFrameBase64: String?
        var firstFrameMime: String?
    }

    private var entriesByStepID: [UUID: Entry] = [:]
    private(set) var version: Int = 0

    func entry(for stepID: UUID) -> Entry? {
        entriesByStepID[stepID]
    }

    func setPhotoPayload(
        stepID: UUID,
        pixelBase64: String?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        jpegBase64: String?,
        jpegMime: String?,
        strippedJpegBase64: String?
    ) {
        var entry = entriesByStepID[stepID] ?? Entry()
        entry.pixelBase64 = pixelBase64
        entry.pixelWidth = pixelWidth
        entry.pixelHeight = pixelHeight
        entry.jpegBase64 = jpegBase64
        entry.jpegMime = jpegMime
        entry.strippedJpegBase64 = strippedJpegBase64
        entriesByStepID[stepID] = entry
        bumpVersion()
    }

    /// Fast-path: stores ONLY the stripped JPEG for a step, preserving any
    /// existing pixel/full-JPEG data. Used by the synchronous pre-population
    /// path so native camera hand-offs always have inline bytes available
    /// before the async full-resolution extraction completes.
    func setStrippedPayloadOnly(stepID: UUID, strippedJpegBase64: String?) {
        guard let strippedJpegBase64 else { return }
        var entry = entriesByStepID[stepID] ?? Entry()
        // Only set if there isn't already a stripped payload (don't overwrite
        // a fresher async extraction with a fast-path one).
        guard entry.strippedJpegBase64 == nil else { return }
        entry.strippedJpegBase64 = strippedJpegBase64
        entriesByStepID[stepID] = entry
        bumpVersion()
    }

    func setFirstFramePayload(stepID: UUID, base64: String?, mime: String?) {
        var entry = entriesByStepID[stepID] ?? Entry()
        entry.firstFrameBase64 = base64
        entry.firstFrameMime = mime
        entriesByStepID[stepID] = entry
        bumpVersion()
    }

    func removePayload(for stepID: UUID) {
        guard entriesByStepID.removeValue(forKey: stepID) != nil else { return }
        bumpVersion()
    }

    func removeAll() {
        guard !entriesByStepID.isEmpty else { return }
        entriesByStepID.removeAll()
        bumpVersion()
    }

    private func bumpVersion() {
        version += 1
    }
}
