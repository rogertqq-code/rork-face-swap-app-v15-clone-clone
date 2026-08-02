#if QA_AUTOMATION
import Foundation

nonisolated enum QAFeatureKey: String, Codable, CaseIterable, Sendable, Hashable {
    case onboardingComplete
    case activeTab
    case targetURL
    case activeProfileID
    case mediaEnabled
    case injectionProfile
    case sdkWrappersEnabled
    case nativeWebRTCEnabled
    case sensorSimulationEnabled
    case sequenceLoopEnabled
    case sequenceEndBehavior
    case audioPolicy
    case diagnosticsVerbosity
    case rawSampleMode
    case rawSampleInterval
    case networkRewriteEnabled
    case cameraPromptBehavior
}

nonisolated enum QAValue: Codable, Sendable, Hashable {
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case strings([String])

    private enum CodingKeys: String, CodingKey { case type, bool, integer, double, string, strings }
    private enum ValueType: String, Codable { case bool, integer, double, string, strings }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .bool))
        case .integer: self = .integer(try container.decode(Int.self, forKey: .integer))
        case .double: self = .double(try container.decode(Double.self, forKey: .double))
        case .string: self = .string(try container.decode(String.self, forKey: .string))
        case .strings: self = .strings(try container.decode([String].self, forKey: .strings))
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .bool)
        case .integer(let value):
            try container.encode(ValueType.integer, forKey: .type)
            try container.encode(value, forKey: .integer)
        case .double(let value):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(value, forKey: .double)
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .string)
        case .strings(let value):
            try container.encode(ValueType.strings, forKey: .type)
            try container.encode(value, forKey: .strings)
        }
    }

    nonisolated var typeName: String {
        switch self {
        case .bool: return "bool"
        case .integer: return "integer"
        case .double: return "double"
        case .string: return "string"
        case .strings: return "strings"
        }
    }
}

nonisolated struct QAFeatureDescriptor: Codable, Sendable, Hashable {
    let key: QAFeatureKey
    let defaultValue: QAValue
    let mutableDuringRun: Bool
    let requiresRelaunch: Bool
    let summary: String
}

nonisolated enum QAFixtureKind: String, Codable, Sendable, Hashable {
    case stillImage
    case video
    case audio
    case mediaSequence
    case browserPage
    case profile
}

nonisolated struct QAFixtureReference: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let kind: QAFixtureKind
    let location: String
    var metadata: [String: String]
}

nonisolated struct QAEvidencePolicy: Codable, Sendable, Hashable {
    var screenshotsOnFailure: Bool = true
    var screenRecording: Bool = false
    var deviceLogs: Bool = true
    var webKitTranscript: Bool = true
    var diagnosticsBundle: Bool = true
    var rawMediaSamples: Bool = false
    var maximumArtifactBytes: Int = 512 * 1_024 * 1_024
    var retentionHours: Int = 72
}

nonisolated struct QACleanupPolicy: Codable, Sendable, Hashable {
    var stopMedia: Bool = true
    var clearQAState: Bool = true
    var removeFixtures: Bool = true
    var terminateApplication: Bool = false
}

nonisolated struct QASessionManifest: Codable, Sendable, Hashable {
    static let currentVersion = 1

    let version: Int
    let runID: UUID
    let createdAt: Date
    let expiresAt: Date?
    var targetURL: URL?
    var featureOverrides: [QAFeatureKey: QAValue]
    var fixtures: [QAFixtureReference]
    var evidence: QAEvidencePolicy
    var cleanup: QACleanupPolicy
    var labels: [String: String]

    nonisolated init(
        version: Int = Self.currentVersion,
        runID: UUID = UUID(),
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        targetURL: URL? = nil,
        featureOverrides: [QAFeatureKey: QAValue] = [:],
        fixtures: [QAFixtureReference] = [],
        evidence: QAEvidencePolicy = QAEvidencePolicy(),
        cleanup: QACleanupPolicy = QACleanupPolicy(),
        labels: [String: String] = [:]
    ) {
        self.version = version
        self.runID = runID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.targetURL = targetURL
        self.featureOverrides = featureOverrides
        self.fixtures = fixtures
        self.evidence = evidence
        self.cleanup = cleanup
        self.labels = labels
    }

    nonisolated func validate(now: Date = Date()) throws {
        guard version == Self.currentVersion else {
            throw QAManifestError.unsupportedVersion(version)
        }
        if let expiresAt, expiresAt <= now {
            throw QAManifestError.expired(expiresAt)
        }
    }
}

nonisolated enum QAManifestError: LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case expired(Date)
    case missingManifest
    case invalidEncoding
    case invalidFeatureValue(QAFeatureKey, expected: String, received: String)

    nonisolated var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Unsupported QA manifest version \(version)."
        case .expired(let date): return "The QA manifest expired at \(date)."
        case .missingManifest: return "No QA session manifest was supplied."
        case .invalidEncoding: return "The QA session manifest could not be decoded."
        case .invalidFeatureValue(let key, let expected, let received):
            return "Feature \(key.rawValue) expected \(expected), received \(received)."
        }
    }
}
#endif
