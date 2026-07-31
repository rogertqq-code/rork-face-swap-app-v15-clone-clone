import Foundation

/// The kind of camera / anti-spoof / anti-bot system the scanner believes a
/// site is running. Each category maps to a default recommended profile and
/// carries plain-language guide copy.
nonisolated enum DetectedSystemCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case consistencyChecker
    case livenessDetection
    case deepCameraProbe
    case cspLockdown
    case permissionGate
    case nativePicker
    case standardWebRTC
    case unknown

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .consistencyChecker: "Consistency checker"
        case .livenessDetection: "Liveness / face challenge"
        case .deepCameraProbe: "Deep camera probe"
        case .cspLockdown: "Strict policy lockdown"
        case .permissionGate: "Permission gate"
        case .nativePicker: "Native photo picker"
        case .standardWebRTC: "Standard WebRTC camera"
        case .unknown: "Unidentified"
        }
    }

    nonisolated var icon: String {
        switch self {
        case .consistencyChecker: "magnifyingglass.circle.fill"
        case .livenessDetection: "faceid"
        case .deepCameraProbe: "camera.metering.matrix"
        case .cspLockdown: "lock.shield.fill"
        case .permissionGate: "hand.raised.fill"
        case .nativePicker: "photo.on.rectangle.angled"
        case .standardWebRTC: "video.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    nonisolated var tintName: String {
        switch self {
        case .consistencyChecker: "orange"
        case .livenessDetection: "purple"
        case .deepCameraProbe: "blue"
        case .cspLockdown: "red"
        case .permissionGate: "pink"
        case .nativePicker: "teal"
        case .standardWebRTC: "green"
        case .unknown: "gray"
        }
    }

    /// The injection method the scanner recommends before any per-site learning is applied.
    nonisolated var recommendedProfile: InjectionMethodKind {
        switch self {
        case .consistencyChecker: .rawFramePipe
        case .livenessDetection: .canvasPipeline
        case .deepCameraProbe: .canvasPipeline
        case .cspLockdown: .canvasPipeline
        case .permissionGate: .passthrough
        case .nativePicker: .canvasPipeline
        case .standardWebRTC: .canvasPipeline
        case .unknown: .canvasPipeline
        }
    }

    nonisolated var guideSummary: String {
        switch self {
        case .consistencyChecker:
            "Assumes the browser is lying and hunts for tampering — a wrapped function, a fingerprint that shifts, a prototype that behaves slightly off. Raw Frame Pipe reduces detection surface by avoiding canvas artifacts."
        case .livenessDetection:
            "Asks the camera to prove a real person is present with flashes, head turns, or blink prompts. Needs a smooth, live-looking feed — Canvas Pipeline works best here."
        case .deepCameraProbe:
            "Inspects the camera in detail — resolution, capabilities, frame timing — and expects rich, internally consistent answers. Canvas Pipeline provides the richest track surface."
        case .cspLockdown:
            "Uses strict content and permission policies to stop injected media from ever loading. Beaten with CSP-immune pixel-data delivery through Canvas Pipeline."
        case .permissionGate:
            "Blocks camera access at the browser permission or secure-context level before any masking can run. Usually unbeatable from inside the page."
        case .nativePicker:
            "Requests photos through the native file/camera picker rather than a live stream. Handled by feeding the picker your chosen media through any method."
        case .standardWebRTC:
            "An ordinary camera request with no special anti-spoof checks. The Canvas Pipeline method works cleanly here."
        case .unknown:
            "No strong detection signals were found. Start with Canvas Pipeline and adjust if it misbehaves."
        }
    }
}

/// A confidence band used for color-coded badges.
nonisolated enum ConfidenceBand: String, Codable, Sendable {
    case low
    case medium
    case high

    nonisolated var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    nonisolated var tintName: String {
        switch self {
        case .low: "orange"
        case .medium: "yellow"
        case .high: "green"
        }
    }
}

/// The result of scanning a site: the most likely detection system, its
/// category, a confidence score, the signals that informed the guess, and the
/// recommended profile (already blended with any per-site learning).
nonisolated struct DetectedSystem: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var host: String
    var systemName: String
    var category: DetectedSystemCategory
    var confidence: Int
    var signals: [String]
    /// Final recommendation after blending the scanner default with learning memory.
    var recommendedProfile: InjectionProfileKind
    /// The scanner's own pick, before learning memory adjusted it.
    var baseRecommendation: InjectionProfileKind
    /// True when per-site or per-category memory changed the recommendation.
    var memoryInformed: Bool
    var timestamp: Date

    init(
        id: UUID = UUID(),
        host: String,
        systemName: String,
        category: DetectedSystemCategory,
        confidence: Int,
        signals: [String],
        recommendedProfile: InjectionProfileKind,
        baseRecommendation: InjectionProfileKind,
        memoryInformed: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.systemName = systemName
        self.category = category
        self.confidence = max(0, min(100, confidence))
        self.signals = signals
        self.recommendedProfile = recommendedProfile
        self.baseRecommendation = baseRecommendation
        self.memoryInformed = memoryInformed
        self.timestamp = timestamp
    }

    nonisolated var confidenceBand: ConfidenceBand {
        if confidence >= 75 { return .high }
        if confidence >= 45 { return .medium }
        return .low
    }
}
