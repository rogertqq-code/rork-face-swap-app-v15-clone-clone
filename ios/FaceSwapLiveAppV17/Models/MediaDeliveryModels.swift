import Foundation

/// The user-visible health of the queued-media delivery pipeline.
nonisolated enum MediaDeliveryStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case idle
    case pageReady
    case preparing
    case receivingFrames
    case completed
    case blocked
    case needsAttention

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .idle: "Waiting for a request"
        case .pageReady: "Page ready"
        case .preparing: "Preparing media"
        case .receivingFrames: "Receiving frames"
        case .completed: "Delivery completed"
        case .blocked: "Request blocked"
        case .needsAttention: "Needs attention"
        }
    }

    nonisolated var symbolName: String {
        switch self {
        case .idle: "circle.dotted"
        case .pageReady: "checkmark.circle"
        case .preparing: "arrow.triangle.2.circlepath"
        case .receivingFrames: "waveform.path.ecg"
        case .completed: "checkmark.seal.fill"
        case .blocked: "hand.raised.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }
}

/// A deterministic state transition emitted by the page runtime.
nonisolated enum MediaDeliveryPhase: String, Codable, Sendable, CaseIterable, Identifiable {
    case pageReady
    case requestSeen
    case queueResolved
    case mediaPrepared
    case feedBuilt
    case mediaConnected
    case framesFlowing
    case requestCompleted
    case requestRejected
    case requestCancelled
    case pageSuspended
    case pageResumed

    nonisolated var id: String { rawValue }

    nonisolated var status: MediaDeliveryStatus {
        switch self {
        case .pageReady, .pageResumed:
            .pageReady
        case .requestSeen, .queueResolved, .mediaPrepared, .feedBuilt, .mediaConnected:
            .preparing
        case .framesFlowing:
            .receivingFrames
        case .requestCompleted:
            .completed
        case .requestRejected:
            .blocked
        case .requestCancelled, .pageSuspended:
            .needsAttention
        }
    }
}

/// Immutable context derived from WebKit frame information, never from page-provided origin fields.
nonisolated struct MediaBridgeContext: Sendable, Equatable {
    let navigationSessionID: String
    let origin: String
    let frameURL: String
    let isMainFrame: Bool

    nonisolated var frameIdentity: String {
        "\(origin)|\(isMainFrame ? "main" : "frame")|\(frameURL)"
    }
}

/// One observable lifecycle event for the active or most recent delivery request.
nonisolated struct MediaDeliveryEvent: Identifiable, Sendable, Equatable {
    let id: UUID
    let phase: MediaDeliveryPhase
    let requestID: String
    let navigationSessionID: String
    let sequenceVersion: Int
    let context: MediaBridgeContext
    let reason: String
    let detail: String
    let frameTimestampOffsetMs: Double?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        phase: MediaDeliveryPhase,
        requestID: String,
        navigationSessionID: String,
        sequenceVersion: Int,
        context: MediaBridgeContext,
        reason: String = "",
        detail: String = "",
        frameTimestampOffsetMs: Double? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.phase = phase
        self.requestID = requestID
        self.navigationSessionID = navigationSessionID
        self.sequenceVersion = sequenceVersion
        self.context = context
        self.reason = reason
        self.detail = detail
        self.frameTimestampOffsetMs = frameTimestampOffsetMs
        self.timestamp = timestamp
    }
}
