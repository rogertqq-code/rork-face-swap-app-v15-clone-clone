import Foundation

/// Which surface a camera request arrived on.
nonisolated enum CameraRequestKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A live in-page feed request (getUserMedia / WebRTC / srcObject).
    case liveCamera
    /// A native camera capture request (file input with `capture`).
    case nativeCamera
    /// An ordinary library / file pick (no `capture` attribute).
    case filePick

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .liveCamera: "Live camera feed"
        case .nativeCamera: "Native camera capture"
        case .filePick: "Library / file pick"
        }
    }

    nonisolated var icon: String {
        switch self {
        case .liveCamera: "video.fill"
        case .nativeCamera: "camera.fill"
        case .filePick: "photo.on.rectangle"
        }
    }
}

/// What to do with a camera request.
nonisolated enum CameraRequestAction: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Serve the next queued item (the app's normal behavior).
    case serveNext
    /// Deny the request — the site sees a permission denial.
    case block
    /// Let the real device camera answer this request.
    case realCamera

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .serveNext: "Serve next queued item"
        case .block: "Block this request"
        case .realCamera: "Allow the real camera"
        }
    }

    nonisolated var icon: String {
        switch self {
        case .serveNext: "play.fill"
        case .block: "hand.raised.fill"
        case .realCamera: "camera.aperture"
        }
    }

    /// The token the page engine understands.
    nonisolated var jsValue: String {
        switch self {
        case .serveNext: "serve"
        case .block: "block"
        case .realCamera: "real"
        }
    }
}

/// When the site's camera permission is released so the next request must ask again.
nonisolated enum CameraPermissionResetPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case never
    case whenFeedEnds
    case afterEveryRequest

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .never: "Never release"
        case .whenFeedEnds: "When a feed ends"
        case .afterEveryRequest: "After every request"
        }
    }

    nonisolated var detail: String {
        switch self {
        case .never: "Keep the site's camera permission for the whole visit."
        case .whenFeedEnds: "Release it once a live feed stops, so the next feed has to ask again."
        case .afterEveryRequest: "Release it after every single request — strictest, and most like a fresh visit each time."
        }
    }
}

/// Every option for the opt-in "ask me every request" mode. Off by default, so
/// nothing changes until it is explicitly enabled.
nonisolated struct CameraPromptSettings: Codable, Sendable, Equatable {
    /// Master switch. When false the app behaves exactly as it always has.
    var isEnabled: Bool
    /// Which request kinds pause and ask.
    var askForLiveCamera: Bool
    var askForNativeCamera: Bool
    var askForFilePick: Bool
    /// Used when no answer arrives before `timeoutSeconds` elapses.
    var defaultAction: CameraRequestAction
    /// How long a request waits for an answer before the default applies.
    var timeoutSeconds: Int
    /// Offer (and honor) "always do this for this site".
    var rememberPerSite: Bool
    /// When the site's camera permission is released.
    var permissionReset: CameraPermissionResetPolicy

    init(
        isEnabled: Bool = false,
        askForLiveCamera: Bool = true,
        askForNativeCamera: Bool = true,
        askForFilePick: Bool = false,
        defaultAction: CameraRequestAction = .serveNext,
        timeoutSeconds: Int = 20,
        rememberPerSite: Bool = true,
        permissionReset: CameraPermissionResetPolicy = .never
    ) {
        self.isEnabled = isEnabled
        self.askForLiveCamera = askForLiveCamera
        self.askForNativeCamera = askForNativeCamera
        self.askForFilePick = askForFilePick
        self.defaultAction = defaultAction
        self.timeoutSeconds = timeoutSeconds
        self.rememberPerSite = rememberPerSite
        self.permissionReset = permissionReset
    }

    nonisolated static let off = CameraPromptSettings()

    /// Whether a given request kind should pause and ask.
    nonisolated func asks(for kind: CameraRequestKind) -> Bool {
        guard isEnabled else { return false }
        switch kind {
        case .liveCamera: return askForLiveCamera
        case .nativeCamera: return askForNativeCamera
        case .filePick: return askForFilePick
        }
    }

    /// The request kinds currently enabled, for a compact settings summary.
    nonisolated var enabledKindsSummary: String {
        guard isEnabled else { return "Off" }
        var parts: [String] = []
        if askForLiveCamera { parts.append("Live") }
        if askForNativeCamera { parts.append("Native") }
        if askForFilePick { parts.append("Files") }
        return parts.isEmpty ? "Nothing selected" : parts.joined(separator: " · ")
    }
}

/// A single paused camera request awaiting the user's decision.
nonisolated struct PendingCameraRequest: Identifiable, Sendable, Equatable {
    let id: String
    let kind: CameraRequestKind
    /// "user" (front) / "environment" (back) / "" when the site didn't say.
    let facing: String
    let requestedWidth: Int?
    let requestedHeight: Int?
    let requestedFrameRate: Int?
    /// The page or embedded frame that asked.
    let origin: String
    /// True when the request came from an embedded frame rather than the page.
    let isFrame: Bool
    let receivedAt: Date

    nonisolated var facingLabel: String {
        switch facing {
        case "environment": "Back camera"
        case "user": "Front camera"
        default: "Camera side not specified"
        }
    }

    nonisolated var sizeLabel: String {
        guard let w = requestedWidth, let h = requestedHeight, w > 0, h > 0 else {
            return "Size not specified"
        }
        return "\(w) × \(h)"
    }

    nonisolated var frameRateLabel: String {
        guard let fps = requestedFrameRate, fps > 0 else { return "Frame rate not specified" }
        return "\(fps) fps"
    }

    nonisolated var sourceLabel: String {
        isFrame ? "Embedded frame" : "Main page"
    }
}
