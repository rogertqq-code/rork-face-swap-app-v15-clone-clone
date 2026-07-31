import Foundation

/// Outcome of a single detector self-test check.
nonisolated enum DetectorCheckStatus: String, Codable, Sendable {
    case pass
    case warn
    case fail
    case skip

    nonisolated var label: String {
        switch self {
        case .pass: "Pass"
        case .warn: "Warn"
        case .fail: "Fail"
        case .skip: "Skipped"
        }
    }

    nonisolated var icon: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.circle.fill"
        case .skip: "minus.circle"
        }
    }

    nonisolated var tintName: String {
        switch self {
        case .pass: "green"
        case .warn: "orange"
        case .fail: "red"
        case .skip: "gray"
        }
    }
}

/// A single check run by the detector self-test (e.g. "Feed timing looks real").
nonisolated struct DetectorSelfTestCheck: Codable, Sendable, Identifiable {
    var checkID: String
    var title: String
    var status: DetectorCheckStatus
    var detail: String

    nonisolated var id: String { checkID }
}

/// The full result of running the detector self-test against the live page and
/// whatever injection method is currently active.
nonisolated struct DetectorSelfTestReport: Codable, Sendable, Identifiable {
    var id: UUID
    var methodRaw: String
    var active: Bool
    var score: Int
    var checks: [DetectorSelfTestCheck]
    var timestamp: Date

    init(
        id: UUID = UUID(),
        methodRaw: String,
        active: Bool,
        score: Int,
        checks: [DetectorSelfTestCheck],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.methodRaw = methodRaw
        self.active = active
        self.score = max(0, min(100, score))
        self.checks = checks
        self.timestamp = timestamp
    }

    /// Human-readable name of the method that was tested.
    nonisolated var methodLabel: String {
        InjectionMethodKind(rawValue: methodRaw)?.label ?? "Current method"
    }

    nonisolated var passCount: Int { checks.filter { $0.status == .pass }.count }
    nonisolated var failCount: Int { checks.filter { $0.status == .fail }.count }
    nonisolated var warnCount: Int { checks.filter { $0.status == .warn }.count }

    /// Confidence band for color-coding the overall score.
    nonisolated var scoreTintName: String {
        if failCount > 0 || score < 50 { return "red" }
        if warnCount > 0 || score < 80 { return "orange" }
        return "green"
    }
}
