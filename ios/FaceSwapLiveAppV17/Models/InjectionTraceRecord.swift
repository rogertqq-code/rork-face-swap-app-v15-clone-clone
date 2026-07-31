import Foundation

/// The ordered stages a camera request passes through before a site actually
/// receives media. Recording the exact stage that failed turns "injection is
/// broken" into a precise, actionable report.
nonisolated enum InjectionTraceStage: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A fresh page accepted its versioned native runtime state.
    case pageReady
    /// The camera takeover was installed on the page.
    case takeoverInstalled
    /// The site asked for a camera (live request or a phone-camera control).
    case requestSeen
    /// A queue item was chosen to answer the request.
    case queueResolved
    /// The chosen item's photo or video bytes were prepared.
    case mediaPrepared
    /// A delivery feed was built for the chosen route.
    case feedBuilt
    /// Frames were confirmed flowing into the site's stream.
    case framesFlowing
    /// The site's control confirmed it received the file.
    case deliveryConfirmed
    /// The selected stream was attached to its active request context.
    case mediaConnected
    /// The request delivered successfully after its lifecycle checks.
    case requestCompleted
    /// The request was explicitly rejected with a reason.
    case requestRejected
    /// The request was cancelled by navigation, reset, or lifecycle change.
    case requestCancelled
    /// The app/page went into the background while a request was active.
    case pageSuspended
    /// The app/page resumed and rechecked its current media state.
    case pageResumed

    nonisolated var id: String { rawValue }

    nonisolated var order: Int {
        switch self {
        case .pageReady: 0
        case .takeoverInstalled: 1
        case .requestSeen: 2
        case .queueResolved: 3
        case .mediaPrepared: 4
        case .feedBuilt: 5
        case .mediaConnected: 6
        case .framesFlowing: 7
        case .deliveryConfirmed: 8
        case .requestCompleted: 9
        case .requestRejected: 10
        case .requestCancelled: 11
        case .pageSuspended: 12
        case .pageResumed: 13
        }
    }

    nonisolated var title: String {
        switch self {
        case .pageReady: "Page ready"
        case .takeoverInstalled: "Takeover installed"
        case .requestSeen: "Request seen"
        case .queueResolved: "Queue item chosen"
        case .mediaPrepared: "Media prepared"
        case .feedBuilt: "Feed built"
        case .mediaConnected: "Media connected"
        case .framesFlowing: "Frames flowing"
        case .deliveryConfirmed: "Delivery confirmed"
        case .requestCompleted: "Request completed"
        case .requestRejected: "Request rejected"
        case .requestCancelled: "Request cancelled"
        case .pageSuspended: "Page suspended"
        case .pageResumed: "Page resumed"
        }
    }

    /// Plain-language meaning of a failure at this stage.
    nonisolated var failureMeaning: String {
        switch self {
        case .pageReady:
            "The page never acknowledged the current media state."
        case .takeoverInstalled:
            "The app never took control of this page's camera, so the site would reach the real camera."
        case .requestSeen:
            "The site's camera request never reached the app."
        case .queueResolved:
            "Nothing in your media list could answer this request."
        case .mediaPrepared:
            "The chosen item's photo or video could not be prepared."
        case .feedBuilt:
            "The delivery feed could not be created for this site."
        case .mediaConnected:
            "A feed was made but could not attach to the active request."
        case .framesFlowing:
            "A feed was created but no frames reached the site."
        case .deliveryConfirmed:
            "The site's control never confirmed it received the file."
        case .requestCompleted:
            "The request did not finish its verified delivery lifecycle."
        case .requestRejected:
            "The request was rejected before queued media could be delivered."
        case .requestCancelled:
            "The request was cancelled because its page or state changed."
        case .pageSuspended:
            "The page was suspended before the active request could finish."
        case .pageResumed:
            "The page did not re-establish its media state after resuming."
        }
    }

    nonisolated var iconName: String {
        switch self {
        case .pageReady: "checkmark.circle"
        case .takeoverInstalled: "shield.lefthalf.filled"
        case .requestSeen: "antenna.radiowaves.left.and.right"
        case .queueResolved: "list.bullet"
        case .mediaPrepared: "photo"
        case .feedBuilt: "wave.3.right"
        case .mediaConnected: "link"
        case .framesFlowing: "film"
        case .deliveryConfirmed: "checkmark.circle"
        case .requestCompleted: "checkmark.seal"
        case .requestRejected: "hand.raised"
        case .requestCancelled: "xmark.circle"
        case .pageSuspended: "pause.circle"
        case .pageResumed: "play.circle"
        }
    }
}

/// Which camera surface the request came from.
nonisolated enum InjectionTraceSurface: String, Codable, Sendable {
    case live
    case native
    case unknown

    nonisolated var label: String {
        switch self {
        case .live: "Live camera"
        case .native: "Phone camera"
        case .unknown: "Camera"
        }
    }
}

/// One recorded injection failure. Captured only while the recorder is switched
/// on, and holds no media bytes — only the stage, reason, route and site.
nonisolated struct InjectionTraceRecord: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var timestamp: Date
    var stage: InjectionTraceStage
    var surface: InjectionTraceSurface
    /// Short machine reason from the engine, e.g. "no-media" or "lane-timeout".
    var reason: String
    /// Extra technical context, never media content.
    var detail: String
    var host: String
    /// The delivery route in play when this failed.
    var method: String
    /// Immutable request/session fields emitted by the deterministic bridge.
    var requestID: String?
    var navigationSessionID: String?
    var sequenceVersion: Int?
    var frameTimestampOffsetMs: Double?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        stage: InjectionTraceStage,
        surface: InjectionTraceSurface = .unknown,
        reason: String = "",
        detail: String = "",
        host: String = "",
        method: String = "",
        requestID: String? = nil,
        navigationSessionID: String? = nil,
        sequenceVersion: Int? = nil,
        frameTimestampOffsetMs: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.stage = stage
        self.surface = surface
        self.reason = reason
        self.detail = detail
        self.host = host
        self.method = method
        self.requestID = requestID
        self.navigationSessionID = navigationSessionID
        self.sequenceVersion = sequenceVersion
        self.frameTimestampOffsetMs = frameTimestampOffsetMs
    }

    /// A single human-readable line describing what went wrong.
    nonisolated var summary: String {
        var text = "\(surface.label) request failed at “\(stage.title)”. \(stage.failureMeaning)"
        if !reason.isEmpty {
            text += " Reported reason: \(reason)."
        }
        return text
    }

    nonisolated var exportLine: String {
        let stamp = ISO8601DateFormatter().string(from: timestamp)
        let site = host.isEmpty ? "unknown-site" : host
        let route = method.isEmpty ? "unknown-route" : method
        var line = "\(stamp)  [\(stage.rawValue)]  \(surface.rawValue)  \(site)  route=\(route)"
        if let requestID, !requestID.isEmpty { line += "  request=\(requestID)" }
        if let navigationSessionID, !navigationSessionID.isEmpty { line += "  session=\(navigationSessionID)" }
        if let sequenceVersion { line += "  sequence=\(sequenceVersion)" }
        if let frameTimestampOffsetMs { line += "  frameOffsetMs=\(Int(frameTimestampOffsetMs))" }
        if !reason.isEmpty { line += "  reason=\(reason)" }
        if !detail.isEmpty { line += "  detail=\(detail)" }
        return line
    }
}
