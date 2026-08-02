#if QA_AUTOMATION
import Foundation

nonisolated enum QACommandName: String, Codable, CaseIterable, Sendable, Hashable {
    case getCapabilities
    case getState
    case setFeature
    case navigateTab
    case loadURL
    case selectProfile
    case loadSequence
    case enableMedia
    case startNativeWebRTC
    case stopMedia
    case runDiagnostics
    case exportEvidence
    case clearState
    case simulateMemoryWarning
    case terminateSession
}

nonisolated struct QACommandPayload: Codable, Sendable, Hashable {
    var featureKey: QAFeatureKey?
    var featureValue: QAValue?
    var tab: String?
    var url: String?
    var profileID: UUID?
    var profileName: String?
    var sequenceID: UUID?
    var sequenceName: String?
    var audio: Bool?
    var video: Bool?
    var rawSampleMode: String?
    var rawSampleInterval: Int?
    var audioPolicy: String?
    var labels: [String: String]

    nonisolated init(
        featureKey: QAFeatureKey? = nil,
        featureValue: QAValue? = nil,
        tab: String? = nil,
        url: String? = nil,
        profileID: UUID? = nil,
        profileName: String? = nil,
        sequenceID: UUID? = nil,
        sequenceName: String? = nil,
        audio: Bool? = nil,
        video: Bool? = nil,
        rawSampleMode: String? = nil,
        rawSampleInterval: Int? = nil,
        audioPolicy: String? = nil,
        labels: [String: String] = [:]
    ) {
        self.featureKey = featureKey
        self.featureValue = featureValue
        self.tab = tab
        self.url = url
        self.profileID = profileID
        self.profileName = profileName
        self.sequenceID = sequenceID
        self.sequenceName = sequenceName
        self.audio = audio
        self.video = video
        self.rawSampleMode = rawSampleMode
        self.rawSampleInterval = rawSampleInterval
        self.audioPolicy = audioPolicy
        self.labels = labels
    }
}

nonisolated struct QATraceContext: Codable, Sendable, Hashable {
    let rootTraceID: String
    let traceID: String
    let spanID: String
    let traceparent: String

    nonisolated static func make(
        rootTraceID: String?,
        traceID: String?,
        spanID: String?,
        traceparent: String?,
        fallbackRoot: UUID,
        fallbackOperation: UUID
    ) throws -> QATraceContext {
        let parsedParent = try traceparent.map(parseTraceparent)
        let explicitRoot = try rootTraceID.map { try normalizedUUID($0, field: "rootTraceID") }
        let explicitOperation = try traceID.map { try normalizedUUID($0, field: "traceID") }
        let root = explicitRoot ?? parsedParent?.rootTraceID ?? fallbackRoot.uuidString.lowercased()
        let operation = explicitOperation ?? fallbackOperation.uuidString.lowercased()
        if let parsedParent, parsedParent.rootTraceID != root {
            throw QACommandError.invalidTrace("traceparent root does not match rootTraceID")
        }
        let explicitSpan = try spanID.map { try normalizedSpan($0) }
        if let parsedParent, let explicitSpan, parsedParent.spanID != explicitSpan {
            throw QACommandError.invalidTrace("traceparent span does not match spanID")
        }
        let span = explicitSpan ?? parsedParent?.spanID ?? generatedSpan()
        let parent = parsedParent?.traceparent ?? makeTraceparent(root: root, span: span)
        return QATraceContext(
            rootTraceID: root,
            traceID: operation,
            spanID: span,
            traceparent: parent
        )
    }

    private nonisolated static func normalizedUUID(
        _ value: String,
        field: String
    ) throws -> String {
        guard let uuid = UUID(uuidString: value),
              uuid != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else {
            throw QACommandError.invalidTrace("\(field) must be a non-zero UUID")
        }
        return uuid.uuidString.lowercased()
    }

    private nonisolated static func normalizedSpan(_ value: String) throws -> String {
        let span = value.lowercased()
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard span.count == 16,
              span != "0000000000000000",
              span.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            throw QACommandError.invalidTrace(
                "spanID must be 16 non-zero hexadecimal characters"
            )
        }
        return span
    }

    private nonisolated static func parseTraceparent(
        _ value: String
    ) throws -> (rootTraceID: String, spanID: String, traceparent: String) {
        let parts = value.lowercased().split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "00",
              parts[1].count == 32,
              parts[2].count == 16,
              parts[3] == "00" || parts[3] == "01" else {
            throw QACommandError.invalidTrace("traceparent has an invalid W3C format")
        }
        let rootHex = String(parts[1])
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard rootHex != String(repeating: "0", count: 32),
              rootHex.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            throw QACommandError.invalidTrace("traceparent root is invalid")
        }
        let rootUUID = [
            String(rootHex.prefix(8)),
            String(rootHex.dropFirst(8).prefix(4)),
            String(rootHex.dropFirst(12).prefix(4)),
            String(rootHex.dropFirst(16).prefix(4)),
            String(rootHex.dropFirst(20))
        ].joined(separator: "-")
        let root = try normalizedUUID(rootUUID, field: "traceparent root")
        let span = try normalizedSpan(String(parts[2]))
        return (root, span, "00-\(rootHex)-\(span)-\(parts[3])")
    }

    private nonisolated static func generatedSpan() -> String {
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let span = String(value.prefix(16))
        return span == "0000000000000000" ? "0000000000000001" : span
    }

    private nonisolated static func makeTraceparent(root: String, span: String) -> String {
        "00-\(root.replacingOccurrences(of: "-", with: ""))-\(span)-01"
    }
}

nonisolated struct QACommandEnvelope: Codable, Sendable, Hashable, Identifiable {
    static let minimumSupportedVersion = 1
    static let currentVersion = 2

    let version: Int
    let runID: UUID
    let id: UUID
    let issuedAt: Date
    let name: QACommandName
    var payload: QACommandPayload
    var traceID: String?
    var rootTraceID: String?
    var spanID: String?
    var traceparent: String?

    nonisolated init(
        version: Int = Self.currentVersion,
        runID: UUID,
        id: UUID = UUID(),
        issuedAt: Date = Date(),
        name: QACommandName,
        payload: QACommandPayload = QACommandPayload(),
        traceID: String? = nil,
        rootTraceID: String? = nil,
        spanID: String? = nil,
        traceparent: String? = nil
    ) {
        self.version = version
        self.runID = runID
        self.id = id
        self.issuedAt = issuedAt
        self.name = name
        self.payload = payload
        self.traceID = traceID
        self.rootTraceID = rootTraceID
        self.spanID = spanID
        self.traceparent = traceparent
    }

    nonisolated func validatedTraceContext() throws -> QATraceContext {
        try QATraceContext.make(
            rootTraceID: rootTraceID,
            traceID: traceID,
            spanID: spanID,
            traceparent: traceparent,
            fallbackRoot: runID,
            fallbackOperation: id
        )
    }
}

nonisolated struct QAApplicationSnapshot: Codable, Sendable, Hashable {
    var capturedAt: Date
    var rootMounted: Bool
    var browserMounted: Bool
    var diagnosticsMounted: Bool
    var activeTab: String
    var activeProfileID: UUID?
    var activeProfileName: String
    var currentURL: String
    var pageTitle: String
    var sequenceCount: Int
    var sequencePointer: Int
    var mediaActive: Bool
    var injectionProfile: String
    var blockDetectionScripts: Bool
    var rewriteProxy: Bool
    var mediaDeliveryStatus: String
    var mediaDeliveryDetail: String
    var diagnosticsRunning: Bool
    var diagnosticsProgress: Double
    var diagnosticsSummary: String
    var diagnosticsError: String
    var telemetryEventCount: Int
    var rawSampleCount: Int
}

nonisolated enum QACommandResultStatus: String, Codable, Sendable, Hashable {
    case succeeded
    case failed
}

nonisolated struct QACommandFailure: Codable, Sendable, Hashable {
    let code: String
    let message: String
}

nonisolated struct QACommandResult: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let runID: UUID
    let commandID: UUID
    let command: QACommandName
    let startedAt: Date
    let completedAt: Date
    let status: QACommandResultStatus
    let traceID: String?
    let rootTraceID: String?
    let spanID: String?
    let traceparent: String?
    let before: QAApplicationSnapshot
    let after: QAApplicationSnapshot
    let values: [String: QAValue]
    let artifacts: [String]
    let failure: QACommandFailure?
}

nonisolated enum QACommandError: LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case missingPayload(String)
    case invalidPayload(String)
    case invalidTrace(String)
    case rootUnavailable
    case browserUnavailable
    case diagnosticsUnavailable
    case profileNotFound
    case sequenceNotFound
    case commandFailed(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Unsupported QA command version \(version)."
        case .missingPayload(let field): return "The QA command requires \(field)."
        case .invalidPayload(let detail): return "The QA command payload is invalid: \(detail)."
        case .invalidTrace(let detail): return "The QA command trace is invalid: \(detail)."
        case .rootUnavailable: return "The app root is not mounted."
        case .browserUnavailable: return "The browser control surface is not mounted."
        case .diagnosticsUnavailable: return "The diagnostics harness is not mounted."
        case .profileNotFound: return "The requested device profile was not found."
        case .sequenceNotFound: return "The requested media sequence was not found."
        case .commandFailed(let message): return message
        }
    }

    nonisolated var code: String {
        switch self {
        case .unsupportedVersion: return "unsupported_version"
        case .missingPayload: return "missing_payload"
        case .invalidPayload: return "invalid_payload"
        case .invalidTrace: return "invalid_trace"
        case .rootUnavailable: return "root_unavailable"
        case .browserUnavailable: return "browser_unavailable"
        case .diagnosticsUnavailable: return "diagnostics_unavailable"
        case .profileNotFound: return "profile_not_found"
        case .sequenceNotFound: return "sequence_not_found"
        case .commandFailed: return "command_failed"
        }
    }
}
#endif
