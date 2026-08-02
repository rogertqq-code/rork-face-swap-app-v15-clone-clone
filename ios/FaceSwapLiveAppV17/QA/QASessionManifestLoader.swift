#if QA_AUTOMATION
import Foundation

nonisolated enum QASessionManifestLoader {
    static let base64EnvironmentKey = "QA_SESSION_MANIFEST_BASE64"
    static let pathEnvironmentKey = "QA_SESSION_MANIFEST_PATH"
    static let runIDEnvironmentKey = "QA_RUN_ID"

    nonisolated static func load(processInfo: ProcessInfo = .processInfo) throws -> QASessionManifest? {
        try load(environment: processInfo.environment, arguments: processInfo.arguments)
    }

    nonisolated static func load(environment: [String: String], arguments: [String]) throws -> QASessionManifest? {
        if let encoded = environment[base64EnvironmentKey], !encoded.isEmpty {
            return try decodeBase64(encoded)
        }

        if let path = environment[pathEnvironmentKey], !path.isEmpty {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try decode(data)
        }

        if let index = arguments.firstIndex(of: "-qaManifestBase64"), arguments.indices.contains(index + 1) {
            return try decodeBase64(arguments[index + 1])
        }

        if environment["QA_AUTOMATION"] == "1" || arguments.contains("-qaAutomation") {
            let runID = environment[runIDEnvironmentKey].flatMap(UUID.init(uuidString:)) ?? UUID()
            return QASessionManifest(
                runID: runID,
                featureOverrides: [.onboardingComplete: .bool(true)],
                labels: ["runMode": environment["QA_RUN_MODE"] ?? "interactive"]
            )
        }

        return nil
    }

    nonisolated static func decode(_ data: Data) throws -> QASessionManifest {
        do {
            let manifest = try decoder.decode(QASessionManifest.self, from: data)
            try manifest.validate()
            return manifest
        } catch let error as QAManifestError {
            throw error
        } catch {
            throw QAManifestError.invalidEncoding
        }
    }

    nonisolated static func encodeBase64(_ manifest: QASessionManifest) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest).base64EncodedString()
    }

    private nonisolated static func decodeBase64(_ encoded: String) throws -> QASessionManifest {
        guard let data = Data(base64Encoded: encoded) else {
            throw QAManifestError.invalidEncoding
        }
        return try decode(data)
    }

    private nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
#endif
