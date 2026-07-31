import Foundation
import UIKit

/// What a single sequence step delivers when a camera request arrives.
nonisolated enum SequenceStepKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case photo
    case video
    /// Blocks one matching WebRTC live-video request, but never consumes or blocks native file/camera picker flows.
    case webRTCBlock
    /// Legacy stream blocker with configurable once/from-here behavior for WebRTC requests only.
    case block

    nonisolated var id: String { rawValue }

    nonisolated var jsValue: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .webRTCBlock: "webrtcBlock"
        case .block: "block"
        }
    }

    nonisolated var title: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        case .webRTCBlock: "Block WebRTC Once"
        case .block: "Stream Block"
        }
    }
}

/// Which camera requests a step responds to.
nonisolated enum RequestTarget: String, Codable, Sendable, CaseIterable, Identifiable {
    case front
    case back
    case any

    nonisolated var id: String { rawValue }
    nonisolated var jsValue: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .front: "Front"
        case .back: "Back"
        case .any: "Any"
        }
    }
}

/// How a block step behaves once reached.
nonisolated enum SequenceBlockMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case once
    case fromHereOn

    nonisolated var id: String { rawValue }
    nonisolated var jsValue: String { self == .once ? "once" : "here" }

    nonisolated var label: String {
        switch self {
        case .once: "Block once"
        case .fromHereOn: "Block from here"
        }
    }
}

/// Per-step switch for the live in-page camera (WebRTC/getUserMedia/srcObject).
/// The file/photo/camera upload picker is always faked independently of this —
/// blocking the live camera never disables the picker fake.
nonisolated enum LiveCameraMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Serve the fake live feed when the site asks for the in-page camera.
    case serveLive
    /// Deny the live in-page camera request (site sees permission denied).
    case block

    nonisolated var id: String { rawValue }
    nonisolated var jsValue: String { self == .block ? "block" : "serve" }

    nonisolated var label: String {
        switch self {
        case .serveLive: "Serve live"
        case .block: "Block"
        }
    }
}

/// Which kind of camera request a media step answers.
///
/// Defaults to `.either` so every existing and saved sequence keeps behaving
/// exactly as it does today. When set, the queue walk skips the step for the
/// other surface: a native camera capture passes over live-camera-only steps,
/// and a live/WebRTC request passes over native-camera-only steps.
nonisolated enum RequestSurface: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Answers both live camera feeds and native camera captures (default).
    case either
    /// Reserved for live in-page camera requests (getUserMedia / WebRTC).
    case liveCamera
    /// Reserved for native camera capture requests (file input with capture).
    case nativeCamera

    nonisolated var id: String { rawValue }

    nonisolated var jsValue: String {
        switch self {
        case .either: "either"
        case .liveCamera: "live"
        case .nativeCamera: "native"
        }
    }

    nonisolated var label: String {
        switch self {
        case .either: "Either request"
        case .liveCamera: "Live camera only"
        case .nativeCamera: "Native camera only"
        }
    }

    nonisolated var shortLabel: String {
        switch self {
        case .either: "Either"
        case .liveCamera: "Live"
        case .nativeCamera: "Native"
        }
    }

    nonisolated var icon: String {
        switch self {
        case .either: "arrow.triangle.branch"
        case .liveCamera: "video.fill"
        case .nativeCamera: "camera.fill"
        }
    }
}

/// How camera requests walk the sequence.
nonisolated enum SequenceAdvanceMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case advanceEach
    case holdCurrent

    nonisolated var id: String { rawValue }

    nonisolated var jsValue: String {
        switch self {
        case .advanceEach: "advance"
        case .holdCurrent: "holdCurrent"
        }
    }

    nonisolated var label: String {
        switch self {
        case .advanceEach: "Advance each request"
        case .holdCurrent: "Hold current"
        }
    }
}

/// What happens once the sequence runs out of steps.
nonisolated enum SequenceEndBehavior: String, Codable, Sendable, CaseIterable, Identifiable {
    case holdLast
    case loop
    case realCamera
    case refuse

    nonisolated var id: String { rawValue }

    nonisolated var jsValue: String {
        switch self {
        case .holdLast: "hold"
        case .loop: "loop"
        case .realCamera: "real"
        case .refuse: "refuse"
        }
    }

    nonisolated var label: String {
        switch self {
        case .holdLast: "Hold last"
        case .loop: "Loop"
        case .realCamera: "Real camera"
        case .refuse: "Refuse all"
        }
    }
}

/// The maximum number of steps a sequence may ever contain.
nonisolated let maxSequenceSteps: Int = 10

/// A live, editable sequence step held on the main actor. Holds a decoded
/// `UIImage` / converted video URL for previews; the actual bytes served to the
/// page are vended by `LocalResourceHandler` keyed on this step's `id`.
struct SequenceStep: Identifiable {
    let id: UUID
    var kind: SequenceStepKind
    var blockMode: SequenceBlockMode
    /// Whether the live in-page camera is served or blocked for this step.
    /// Photo/video steps only; ignored for block steps. Defaults to serve.
    var liveCamera: LiveCameraMode
    /// Which kind of camera request this step answers. Defaults to `.either`,
    /// preserving the original behavior for every existing sequence.
    var requestSurface: RequestSurface
    var image: UIImage?
    var videoURL: URL?
    /// True when this step created (and therefore owns) a temp video file that
    /// should be deleted when the step is removed. Library-backed URLs are false.
    var ownsVideoFile: Bool
    var displayName: String
    var isConverting: Bool
    var conversionProgress: Double


    init(
        id: UUID = UUID(),
        kind: SequenceStepKind,
        blockMode: SequenceBlockMode = .once,
        liveCamera: LiveCameraMode = .serveLive,
        requestSurface: RequestSurface = .either,
        image: UIImage? = nil,
        videoURL: URL? = nil,
        ownsVideoFile: Bool = false,
        displayName: String = "",
        isConverting: Bool = false,
        conversionProgress: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.blockMode = blockMode
        self.liveCamera = liveCamera
        self.requestSurface = requestSurface
        self.image = image
        self.videoURL = videoURL
        self.ownsVideoFile = ownsVideoFile
        self.displayName = displayName
        self.isConverting = isConverting
        self.conversionProgress = conversionProgress
    }

    /// A media step that has no media yet (an empty placeholder slot).
    var isPlaceholder: Bool {
        (kind == .photo || kind == .video) && image == nil && videoURL == nil
    }

    /// Whether this step can actually serve or intentionally refuse a live WebRTC request.
    var isServable: Bool {
        kind == .block || kind == .webRTCBlock || image != nil || videoURL != nil
    }
}

/// A persisted step — media is referenced by a filename inside the sequence
/// library directory (nil for templates and block steps).
nonisolated struct SavedSequenceStep: Codable, Sendable, Identifiable {
    var id: UUID
    var kind: SequenceStepKind
    var blockMode: SequenceBlockMode
    /// Optional for backward compatibility: sequences saved before the per-step
    /// live switch existed decode as nil and are treated as `.serveLive`.
    var liveCamera: LiveCameraMode?
    /// Optional for backward compatibility: sequences saved before the per-step
    /// request-surface setting existed decode as nil and are treated as `.either`.
    var requestSurface: RequestSurface?
    var mediaFileName: String?
    var thumbnailFileName: String?
    var displayName: String

    init(
        id: UUID = UUID(),
        kind: SequenceStepKind,
        blockMode: SequenceBlockMode = .once,
        liveCamera: LiveCameraMode? = nil,
        requestSurface: RequestSurface? = nil,
        mediaFileName: String? = nil,
        thumbnailFileName: String? = nil,
        displayName: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.blockMode = blockMode
        self.liveCamera = liveCamera
        self.requestSurface = requestSurface
        self.mediaFileName = mediaFileName
        self.thumbnailFileName = thumbnailFileName
        self.displayName = displayName
    }
}

/// A saved sequence (full, with media) or template (placeholders only).
nonisolated struct SavedMediaSequence: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var isTemplate: Bool
    var createdAt: Date
    var advanceMode: SequenceAdvanceMode
    var endBehavior: SequenceEndBehavior
    var steps: [SavedSequenceStep]

    init(
        id: UUID = UUID(),
        name: String,
        isTemplate: Bool,
        createdAt: Date = Date(),
        advanceMode: SequenceAdvanceMode = .advanceEach,
        endBehavior: SequenceEndBehavior = .holdLast,
        steps: [SavedSequenceStep]
    ) {
        self.id = id
        self.name = name
        self.isTemplate = isTemplate
        self.createdAt = createdAt
        self.advanceMode = advanceMode
        self.endBehavior = endBehavior
        self.steps = steps
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    nonisolated static func == (lhs: SavedMediaSequence, rhs: SavedMediaSequence) -> Bool {
        lhs.id == rhs.id
    }
}
