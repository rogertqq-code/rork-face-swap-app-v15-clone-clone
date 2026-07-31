import Foundation

nonisolated enum InjectionFindingSeverity: String, Codable, Sendable, CaseIterable, Identifiable {
    case pass
    case info
    case warning
    case blocked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pass: return "Pass"
        case .info: return "Info"
        case .warning: return "Warning"
        case .blocked: return "Blocked"
        }
    }

    var rank: Int {
        switch self {
        case .pass: return 0
        case .info: return 1
        case .warning: return 2
        case .blocked: return 3
        }
    }
}

nonisolated enum InjectionBlockerKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case contentSecurityPolicy
    case permissionsPolicy
    case cameraPermission
    case mediaDelivery
    case apiIntegrity
    case streamShape
    case nativePicker
    case unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .contentSecurityPolicy: return "Security policy"
        case .permissionsPolicy: return "Camera policy"
        case .cameraPermission: return "Camera permission"
        case .mediaDelivery: return "Media delivery"
        case .apiIntegrity: return "API integrity"
        case .streamShape: return "Stream shape"
        case .nativePicker: return "Native picker"
        case .unknown: return "Unknown"
        }
    }
}

nonisolated struct InjectionProbeFinding: Codable, Identifiable, Sendable {
    var id: UUID
    var severity: InjectionFindingSeverity
    var blocker: InjectionBlockerKind
    var title: String
    var detail: String
    var evidence: String

    init(
        id: UUID = UUID(),
        severity: InjectionFindingSeverity,
        blocker: InjectionBlockerKind,
        title: String,
        detail: String,
        evidence: String = ""
    ) {
        self.id = id
        self.severity = severity
        self.blocker = blocker
        self.title = title
        self.detail = detail
        self.evidence = evidence
    }
}

nonisolated struct InjectionInspectionReport: Codable, Identifiable, Sendable {
    var id: UUID
    var siteURL: String
    var host: String
    var pageTitle: String
    var timestamp: Date
    var verdictTitle: String
    var verdictDetail: String
    var mostLikelyBlocker: InjectionBlockerKind
    var riskScore: Int
    var userAgent: String
    var cspPolicyText: String
    var mediaWasActive: Bool
    var sequenceLength: Int
    var findings: [InjectionProbeFinding]

    init(
        id: UUID = UUID(),
        siteURL: String,
        host: String,
        pageTitle: String,
        timestamp: Date = Date(),
        verdictTitle: String,
        verdictDetail: String,
        mostLikelyBlocker: InjectionBlockerKind,
        riskScore: Int,
        userAgent: String,
        cspPolicyText: String,
        mediaWasActive: Bool,
        sequenceLength: Int,
        findings: [InjectionProbeFinding]
    ) {
        self.id = id
        self.siteURL = siteURL
        self.host = host
        self.pageTitle = pageTitle
        self.timestamp = timestamp
        self.verdictTitle = verdictTitle
        self.verdictDetail = verdictDetail
        self.mostLikelyBlocker = mostLikelyBlocker
        self.riskScore = riskScore
        self.userAgent = userAgent
        self.cspPolicyText = cspPolicyText
        self.mediaWasActive = mediaWasActive
        self.sequenceLength = sequenceLength
        self.findings = findings
    }

    var hasBlockingEvidence: Bool {
        findings.contains { $0.severity == .blocked }
    }

    var warningCount: Int {
        findings.filter { $0.severity == .warning }.count
    }

    var blockedCount: Int {
        findings.filter { $0.severity == .blocked }.count
    }

    var displayTitle: String {
        pageTitle.isEmpty ? host : pageTitle
    }
}
