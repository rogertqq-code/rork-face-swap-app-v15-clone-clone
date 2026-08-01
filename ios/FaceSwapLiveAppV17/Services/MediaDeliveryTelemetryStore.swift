import AVFoundation
import CoreVideo
import Foundation

nonisolated struct MediaRawSample: Sendable {
    struct Plane: Codable, Sendable, Hashable {
        var offset: Int
        var byteCount: Int
        var bytesPerRow: Int
        var height: Int
    }

    var requestID: UUID
    var sequenceNumber: Int
    var presentationTime: Double?
    var width: Int
    var height: Int
    var pixelFormat: UInt32
    var planes: [Plane]
    var bytes: Data
}

nonisolated struct MediaRawSampleRecord: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var requestID: UUID
    var sequenceNumber: Int
    var presentationTime: Double?
    var width: Int
    var height: Int
    var pixelFormat: UInt32
    var planes: [MediaRawSample.Plane]
    var rawFileURL: URL
    var metadataFileURL: URL
    var byteCount: Int
    var createdAt: Date
}

nonisolated final class MediaRawSampleSelector: @unchecked Sendable {
    static let shared = MediaRawSampleSelector()

    private struct State {
        var mode: MediaRawSampleMode
        var observedFrames = 0
    }

    private let lock = NSLock()
    private var states: [UUID: State] = [:]

    private init() {}

    func configure(requestID: UUID, mode: MediaRawSampleMode) {
        lock.lock()
        states[requestID] = State(mode: mode)
        lock.unlock()
    }

    func remove(requestID: UUID) {
        lock.lock()
        states.removeValue(forKey: requestID)
        lock.unlock()
    }

    func captureIfSelected(requestID: UUID, sampleBuffer: CMSampleBuffer) -> MediaRawSample? {
        lock.lock()
        guard var state = states[requestID] else {
            lock.unlock()
            return nil
        }
        state.observedFrames += 1
        states[requestID] = state
        let selected: Bool
        switch state.mode.kind {
        case .off:
            selected = false
        case .firstFrame:
            selected = state.observedFrames == 1
        case .everyNthFrame:
            selected = state.observedFrames.isMultiple(of: max(1, state.mode.interval ?? 1))
        case .allFrames:
            selected = true
        }
        lock.unlock()
        guard selected else { return nil }
        return Self.copySample(requestID: requestID, sequenceNumber: state.observedFrames, sampleBuffer: sampleBuffer)
    }

    private static func copySample(
        requestID: UUID,
        sequenceNumber: Int,
        sampleBuffer: CMSampleBuffer
    ) -> MediaRawSample? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        var bytes = Data()
        var planes: [MediaRawSample.Plane] = []
        if planeCount > 0 {
            for index in 0..<planeCount {
                guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, index) else { continue }
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
                let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
                let byteCount = bytesPerRow * height
                let offset = bytes.count
                bytes.append(baseAddress.assumingMemoryBound(to: UInt8.self), count: byteCount)
                planes.append(.init(offset: offset, byteCount: byteCount, bytesPerRow: bytesPerRow, height: height))
            }
        } else if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let byteCount = bytesPerRow * height
            bytes.append(baseAddress.assumingMemoryBound(to: UInt8.self), count: byteCount)
            planes.append(.init(offset: 0, byteCount: byteCount, bytesPerRow: bytesPerRow, height: height))
        }
        guard !bytes.isEmpty else { return nil }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = timestamp.isValid && !timestamp.isIndefinite ? CMTimeGetSeconds(timestamp) : nil
        return MediaRawSample(
            requestID: requestID,
            sequenceNumber: sequenceNumber,
            presentationTime: seconds?.isFinite == true ? seconds : nil,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
            planes: planes,
            bytes: bytes
        )
    }
}

actor MediaDeliveryTelemetryStore: MediaDeliveryEventRecording {
    static let shared = MediaDeliveryTelemetryStore()

    private struct RawMetadata: Codable {
        var requestID: UUID
        var sequenceNumber: Int
        var presentationTime: Double?
        var width: Int
        var height: Int
        var pixelFormat: UInt32
        var planes: [MediaRawSample.Plane]
        var byteCount: Int
        var createdAt: Date
    }

    private(set) var events: [MediaDeliveryTraceEvent] = []
    private(set) var rawSamples: [MediaRawSampleRecord] = []
    private let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("FSLMediaDiagnostics", isDirectory: true)
    }

    func record(_ event: MediaDeliveryTraceEvent) async {
        events.append(event)
        let line = "media request=\(event.requestID.uuidString) stage=\(event.stage.rawValue) origin=\(event.origin) source=\(event.sourceKind?.rawValue ?? "") adapter=\(event.adapter?.rawValue ?? "") audio=\(event.audioOutcome?.kind.rawValue ?? "") terminal=\(event.terminalReason?.rawValue ?? "") detail=\(event.detail ?? "") metadata=\(event.metadata)"
        await MainActor.run {
            ConnectionLogService.shared.log(.request, line)
        }
    }

    func recordRawSample(_ sample: MediaRawSample) async throws -> MediaRawSampleRecord {
        let requestDirectory = rootDirectory.appendingPathComponent(sample.requestID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
        let stem = String(format: "frame-%08d", sample.sequenceNumber)
        let rawURL = requestDirectory.appendingPathComponent(stem).appendingPathExtension("raw")
        let metadataURL = requestDirectory.appendingPathComponent(stem).appendingPathExtension("json")
        try sample.bytes.write(to: rawURL, options: .atomic)

        let createdAt = Date()
        let metadata = RawMetadata(
            requestID: sample.requestID,
            sequenceNumber: sample.sequenceNumber,
            presentationTime: sample.presentationTime,
            width: sample.width,
            height: sample.height,
            pixelFormat: sample.pixelFormat,
            planes: sample.planes,
            byteCount: sample.bytes.count,
            createdAt: createdAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)

        let record = MediaRawSampleRecord(
            id: UUID(),
            requestID: sample.requestID,
            sequenceNumber: sample.sequenceNumber,
            presentationTime: sample.presentationTime,
            width: sample.width,
            height: sample.height,
            pixelFormat: sample.pixelFormat,
            planes: sample.planes,
            rawFileURL: rawURL,
            metadataFileURL: metadataURL,
            byteCount: sample.bytes.count,
            createdAt: createdAt
        )
        rawSamples.append(record)
        await MainActor.run {
            ConnectionLogService.shared.log(
                .request,
                "raw media request=\(sample.requestID.uuidString) frame=\(sample.sequenceNumber) bytes=\(sample.bytes.count) size=\(sample.width)x\(sample.height) pixelFormat=\(sample.pixelFormat) file=\(rawURL.path)"
            )
        }
        return record
    }

    func exportEventSnapshot() throws -> URL {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let url = rootDirectory.appendingPathComponent("events-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(events).write(to: url, options: .atomic)
        return url
    }

    func records(for requestID: UUID) -> (events: [MediaDeliveryTraceEvent], rawSamples: [MediaRawSampleRecord]) {
        (events.filter { $0.requestID == requestID }, rawSamples.filter { $0.requestID == requestID })
    }

    func removeDiagnostics(for requestID: UUID) {
        events.removeAll { $0.requestID == requestID }
        rawSamples.removeAll { $0.requestID == requestID }
        try? FileManager.default.removeItem(at: rootDirectory.appendingPathComponent(requestID.uuidString, isDirectory: true))
    }

    func removeAllDiagnostics() {
        events.removeAll()
        rawSamples.removeAll()
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
