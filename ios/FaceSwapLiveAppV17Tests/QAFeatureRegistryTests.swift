#if QA_AUTOMATION
import Foundation
import Testing
@testable import FaceSwapLiveAppV17

struct QAFeatureRegistryTests {
    @Test func activationAppliesManifestOverridesAndPersistsSnapshot() async throws {
        let suite = "qa.registry.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = QAFeatureRegistry(defaults: defaults)
        let runID = UUID()
        let manifest = QASessionManifest(
            runID: runID,
            targetURL: URL(string: "https://example.test/qa"),
            featureOverrides: [
                .onboardingComplete: .bool(true),
                .diagnosticsVerbosity: .string("verbose"),
                .rawSampleInterval: .integer(5)
            ]
        )

        let state = try await registry.activate(manifest)

        #expect(state.runID == runID)
        #expect(state.featureValues[.targetURL] == .string("https://example.test/qa"))
        #expect(state.featureValues[.diagnosticsVerbosity] == .string("verbose"))
        #expect(defaults.data(forKey: "qa.activeSession") != nil)
    }

    @Test func invalidFeatureTypeIsRejectedWithoutMutation() async throws {
        let registry = QAFeatureRegistry(defaults: .standard)
        let before = await registry.snapshot()

        do {
            _ = try await registry.set(.string("invalid"), for: .mediaEnabled)
            Issue.record("Expected an invalid feature value error")
        } catch is QAManifestError {
            // Expected typed rejection.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        let after = await registry.snapshot()
        #expect(after.featureValues[.mediaEnabled] == before.featureValues[.mediaEnabled])
    }

    @Test func batchApplyAndResetAreDeterministic() async throws {
        let registry = QAFeatureRegistry(defaults: .standard)
        _ = try await registry.apply([
            .mediaEnabled: .bool(true),
            .activeTab: .string("browser"),
            .sequenceLoopEnabled: .bool(true)
        ])
        let applied = await registry.snapshot()
        #expect(applied.featureValues[.mediaEnabled] == .bool(true))
        #expect(applied.featureValues[.activeTab] == .string("browser"))

        let reset = await registry.reset()
        #expect(reset.runID == nil)
        #expect(reset.featureValues[.mediaEnabled] == .bool(false))
        #expect(reset.featureValues[.activeTab] == .string("preview"))
    }

    @Test func base64ManifestRoundTripsThroughLoader() throws {
        let manifest = QASessionManifest(
            runID: UUID(),
            targetURL: URL(string: "https://example.test/camera"),
            featureOverrides: [.nativeWebRTCEnabled: .bool(true)]
        )
        let base64 = try QASessionManifestLoader.encodeBase64(manifest)
        let loaded = try #require(QASessionManifestLoader.load(
            environment: [QASessionManifestLoader.base64EnvironmentKey: base64],
            arguments: []
        ))
        #expect(loaded == manifest)
    }

    @Test func pathManifestLoadsAndLaunchArgumentsCreateMinimalManifest() throws {
        let manifest = QASessionManifest(runID: UUID())
        let base64 = try QASessionManifestLoader.encodeBase64(manifest)
        let data = try #require(Data(base64Encoded: base64))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa-manifest-\(UUID().uuidString).json")
        try data.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let fromPath = try #require(QASessionManifestLoader.load(
            environment: [QASessionManifestLoader.pathEnvironmentKey: path.path],
            arguments: []
        ))
        #expect(fromPath.runID == manifest.runID)

        let runID = UUID()
        let generated = try #require(QASessionManifestLoader.load(
            environment: ["QA_AUTOMATION": "1", "QA_RUN_ID": runID.uuidString, "QA_RUN_MODE": "cable"],
            arguments: ["app", "-qaAutomation"]
        ))
        #expect(generated.runID == runID)
        #expect(generated.labels["runMode"] == "cable")
    }

    @Test func unsupportedAndExpiredManifestsAreRejected() throws {
        let unsupported = QASessionManifest(version: 99)
        #expect(throws: QAManifestError.self) { try unsupported.validate() }

        let expired = QASessionManifest(expiresAt: Date(timeIntervalSinceNow: -1))
        #expect(throws: QAManifestError.self) { try expired.validate() }
    }
}
#endif
