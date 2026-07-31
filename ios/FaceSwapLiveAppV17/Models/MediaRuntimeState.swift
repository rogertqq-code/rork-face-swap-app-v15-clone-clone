import Foundation

/// Versioned state delivered from native code to a fresh document through the WebKit reply bridge.
nonisolated struct MediaRuntimeState: Codable, Sendable {
    let schemaVersion: Int
    let runtimeVersion: Int
    let navigationSessionID: String
    let sequenceVersion: Int
    let payloadVersion: Int
    let sequence: [MediaRuntimeStep]
    let payloads: [String: MediaRuntimePayload]
    let mode: String
    let end: String
    let method: String
    let isActive: Bool
    let isAuto: Bool
    let photoMotion: Bool
    let eyedeekitMode: Bool
    let documentHoldMinimumMs: Int?
    let documentHoldMaximumMs: Int?
    let askEnabled: Bool
    let askKinds: String
    let askTimeoutMs: Int
    let askDefault: String
    let askRule: String
    let permissionReset: String
    let traceEnabled: Bool

    init(
        runtimeVersion: Int,
        navigationSessionID: String,
        sequenceVersion: Int,
        payloadVersion: Int,
        sequence: [MediaRuntimeStep],
        payloads: [String: MediaRuntimePayload],
        mode: String,
        end: String,
        method: String,
        isActive: Bool,
        isAuto: Bool,
        photoMotion: Bool,
        eyedeekitMode: Bool,
        documentHoldMinimumMs: Int?,
        documentHoldMaximumMs: Int?,
        askEnabled: Bool,
        askKinds: String,
        askTimeoutMs: Int,
        askDefault: String,
        askRule: String,
        permissionReset: String,
        traceEnabled: Bool
    ) {
        self.schemaVersion = 1
        self.runtimeVersion = runtimeVersion
        self.navigationSessionID = navigationSessionID
        self.sequenceVersion = sequenceVersion
        self.payloadVersion = payloadVersion
        self.sequence = sequence
        self.payloads = payloads
        self.mode = mode
        self.end = end
        self.method = method
        self.isActive = isActive
        self.isAuto = isAuto
        self.photoMotion = photoMotion
        self.eyedeekitMode = eyedeekitMode
        self.documentHoldMinimumMs = documentHoldMinimumMs
        self.documentHoldMaximumMs = documentHoldMaximumMs
        self.askEnabled = askEnabled
        self.askKinds = askKinds
        self.askTimeoutMs = askTimeoutMs
        self.askDefault = askDefault
        self.askRule = askRule
        self.permissionReset = permissionReset
        self.traceEnabled = traceEnabled
    }

    nonisolated static func idle(sessionID: String = "diagnostics") -> MediaRuntimeState {
        MediaRuntimeState(
            runtimeVersion: 1,
            navigationSessionID: sessionID,
            sequenceVersion: 0,
            payloadVersion: 0,
            sequence: [],
            payloads: [:],
            mode: "advance",
            end: "hold",
            method: "canvasPipeline",
            isActive: false,
            isAuto: false,
            photoMotion: false,
            eyedeekitMode: false,
            documentHoldMinimumMs: nil,
            documentHoldMaximumMs: nil,
            askEnabled: false,
            askKinds: "",
            askTimeoutMs: 20_000,
            askDefault: "serve",
            askRule: "",
            permissionReset: "never",
            traceEnabled: false
        )
    }

    nonisolated func serializedJSON() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MediaRuntimeStateError.encodingFailed
        }
        return text
    }
}

nonisolated enum MediaRuntimeStateError: Error {
    case encodingFailed
}

/// A single ordered queued-media item sent to the document runtime.
nonisolated struct MediaRuntimeStep: Codable, Sendable {
    let id: String
    let kind: String
    let block: String
    let live: String
    let surface: String
    let imageURL: String?
    let videoURL: String?
    let isEmpty: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case block
        case live
        case surface
        case imageURL = "img"
        case videoURL = "vid"
        case isEmpty = "empty"
    }
}

/// Inline media data and optional fallback references for a queued item.
nonisolated struct MediaRuntimePayload: Codable, Sendable {
    let resourceID: String
    let hash: String
    let version: Int
    let chunksURL: String?

    enum CodingKeys: String, CodingKey {
        case resourceID = "rid"
        case hash = "hsh"
        case version = "v"
        case chunksURL = "chk"
    }
}
