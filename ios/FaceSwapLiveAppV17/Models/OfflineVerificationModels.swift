import Foundation

/// The schema version for offline verification evidence. Increment this when a
/// meaningful verification rule changes so stale records are clearly rerun.
nonisolated enum OfflineVerificationEngineVersion {
    static let current: Int = 1
}

/// A stable check identifier stored with an offline device verification report.
nonisolated enum OfflineVerificationCheckID: String, Codable, Sendable, CaseIterable, Identifiable {
    case profileShape
    case cameraPermission
    case microphoneReadiness
    case mediaPreparation
    case guidedCameraCapture
    case browserCompatibility
    case browserFixture

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .profileShape: "Device profile"
        case .cameraPermission: "Camera permission"
        case .microphoneReadiness: "Microphone readiness"
        case .mediaPreparation: "Media preparation"
        case .guidedCameraCapture: "Real camera capture"
        case .browserCompatibility: "External browser compatibility"
        case .browserFixture: "Built-in browser fixture"
        }
    }

    nonisolated var iconName: String {
        switch self {
        case .profileShape: "iphone.gen3"
        case .cameraPermission: "camera.fill"
        case .microphoneReadiness: "mic.fill"
        case .mediaPreparation: "photo.badge.checkmark"
        case .guidedCameraCapture: "camera.aperture"
        case .browserCompatibility: "globe"
        case .browserFixture: "checkmark.shield.fill"
        }
    }
}

/// The result of one verification check. These states intentionally distinguish
/// a failed check from a capability the app cannot prove offline.
nonisolated enum OfflineVerificationCheckStatus: String, Codable, Sendable, CaseIterable {
    case passed
    case needsAttention
    case unavailable
    case needsUserConfirmation
    case skipped

    nonisolated var label: String {
        switch self {
        case .passed: "Passed"
        case .needsAttention: "Needs attention"
        case .unavailable: "Unavailable"
        case .needsUserConfirmation: "Needs confirmation"
        case .skipped: "Skipped"
        }
    }

    nonisolated var iconName: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .unavailable: "minus.circle.fill"
        case .needsUserConfirmation: "hand.tap.fill"
        case .skipped: "forward.fill"
        }
    }

    nonisolated var tintName: String {
        switch self {
        case .passed: "green"
        case .needsAttention: "orange"
        case .unavailable: "secondary"
        case .needsUserConfirmation: "cyan"
        case .skipped: "secondary"
        }
    }

    nonisolated var isPassing: Bool { self == .passed }
}

/// One privacy-conscious assertion from a verification run. `evidence` stores
/// only technical counts, dimensions, or error categories—not captured media.
nonisolated struct OfflineVerificationCheck: Codable, Sendable, Identifiable, Equatable {
    var id: OfflineVerificationCheckID
    var status: OfflineVerificationCheckStatus
    var summary: String
    var evidence: String
    var isRequired: Bool

    init(
        id: OfflineVerificationCheckID,
        status: OfflineVerificationCheckStatus,
        summary: String,
        evidence: String = "",
        isRequired: Bool
    ) {
        self.id = id
        self.status = status
        self.summary = summary
        self.evidence = evidence
        self.isRequired = isRequired
    }
}

/// The overall result of a completed (or deliberately skipped) verification run.
nonisolated enum OfflineVerificationOutcome: String, Codable, Sendable, CaseIterable {
    case verified
    case needsAttention
    case inconclusive
    case skipped

    nonisolated var title: String {
        switch self {
        case .verified: "Offline checks complete"
        case .needsAttention: "Needs verification"
        case .inconclusive: "Verification incomplete"
        case .skipped: "Verification skipped"
        }
    }

    nonisolated var iconName: String {
        switch self {
        case .verified: "checkmark.seal.fill"
        case .needsAttention: "exclamationmark.shield.fill"
        case .inconclusive: "questionmark.diamond.fill"
        case .skipped: "clock.badge.exclamationmark"
        }
    }

    nonisolated var tintName: String {
        switch self {
        case .verified: "green"
        case .needsAttention: "orange"
        case .inconclusive: "orange"
        case .skipped: "secondary"
        }
    }
}

/// The current verification state for a profile, including invalidation when the
/// app's verification rules or the profile's hardware signature have changed.
nonisolated enum OfflineVerificationStatus: Equatable, Sendable {
    case notStarted
    case verified
    case needsAttention
    case inconclusive
    case skipped
    case outdated

    nonisolated var title: String {
        switch self {
        case .notStarted: "Verification required"
        case .verified: "Offline checks complete"
        case .needsAttention: "Needs verification"
        case .inconclusive: "Verification incomplete"
        case .skipped: "Verification skipped"
        case .outdated: "Verification needs rerun"
        }
    }

    nonisolated var iconName: String {
        switch self {
        case .notStarted: "exclamationmark.circle.fill"
        case .verified: "checkmark.seal.fill"
        case .needsAttention: "exclamationmark.shield.fill"
        case .inconclusive: "questionmark.diamond.fill"
        case .skipped: "clock.badge.exclamationmark"
        case .outdated: "arrow.triangle.2.circlepath"
        }
    }

    nonisolated var tintName: String {
        switch self {
        case .verified: "green"
        case .notStarted, .needsAttention, .inconclusive, .outdated: "orange"
        case .skipped: "secondary"
        }
    }
}

/// A compact capability snapshot kept with the report rather than any photo,
/// audio sample, device identifier, or browser history.
nonisolated struct OfflineVerificationCapabilitySummary: Codable, Sendable, Equatable {
    var modelIdentifier: String
    var systemVersion: String
    var cameraCount: Int
    var microphoneCount: Int
    var cameraAuthorized: Bool
    var microphoneAuthorized: Bool
}

/// Persisted profile-scoped evidence from an offline verification run.
nonisolated struct OfflineVerificationReport: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var profileID: UUID
    var timestamp: Date
    var appVersion: String
    var engineVersion: Int
    var hardwareSignature: String
    var capabilities: OfflineVerificationCapabilitySummary
    var checks: [OfflineVerificationCheck]
    var outcome: OfflineVerificationOutcome
    /// A concrete method is only stored after the app-owned mounted browser fixture
    /// has observed that method's expected behavior.
    var fixtureMethod: InjectionMethodKind?
    var fixtureSummary: String

    init(
        id: UUID = UUID(),
        profileID: UUID,
        timestamp: Date = Date(),
        appVersion: String = AppVersion.marketing,
        engineVersion: Int = OfflineVerificationEngineVersion.current,
        hardwareSignature: String,
        capabilities: OfflineVerificationCapabilitySummary,
        checks: [OfflineVerificationCheck],
        outcome: OfflineVerificationOutcome,
        fixtureMethod: InjectionMethodKind? = nil,
        fixtureSummary: String = ""
    ) {
        self.id = id
        self.profileID = profileID
        self.timestamp = timestamp
        self.appVersion = appVersion
        self.engineVersion = engineVersion
        self.hardwareSignature = hardwareSignature
        self.capabilities = capabilities
        self.checks = checks
        self.outcome = outcome
        self.fixtureMethod = fixtureMethod
        self.fixtureSummary = fixtureSummary
    }

    nonisolated var passCount: Int {
        checks.filter { $0.status == .passed }.count
    }

    nonisolated var requiredChecksPassed: Bool {
        checks.filter(\.isRequired).allSatisfy { $0.status == .passed }
    }

    nonisolated func check(_ id: OfflineVerificationCheckID) -> OfflineVerificationCheck? {
        checks.first { $0.id == id }
    }

    nonisolated func isCurrent(for profile: DeviceProfile) -> Bool {
        engineVersion == OfflineVerificationEngineVersion.current
            && hardwareSignature == Self.hardwareSignature(for: profile)
    }

    nonisolated static func hardwareSignature(for profile: DeviceProfile) -> String {
        let cameraIdentity = profile.cameras
            .map { "\($0.id)|\($0.position)|\($0.activeWidth)x\($0.activeHeight)" }
            .sorted()
            .joined(separator: ";")
        let microphoneIdentity = profile.microphones
            .map { "\($0.id)|\($0.sampleRate)|\($0.channelCount)" }
            .sorted()
            .joined(separator: ";")
        return "\(profile.deviceHardware.modelIdentifier)|\(profile.deviceHardware.systemVersion)|\(cameraIdentity)|\(microphoneIdentity)"
    }
}
