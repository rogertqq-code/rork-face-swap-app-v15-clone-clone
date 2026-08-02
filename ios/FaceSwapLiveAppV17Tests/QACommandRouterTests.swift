#if QA_AUTOMATION
import Foundation
import Testing
@testable import FaceSwapLiveAppV17

@MainActor
struct QACommandRouterTests {
    @Test func capabilitiesExposeEveryAllowlistedCommandAndFeature() async throws {
        let context = try await makeContext()
        let result = await context.router.execute(QACommandEnvelope(
            runID: context.runID,
            name: .getCapabilities
        ))

        #expect(result.status == .succeeded)
        #expect(result.before.rootMounted == false)
        #expect(result.after.rootMounted == false)
        guard case .strings(let commands) = result.values["commands"] else {
            Issue.record("Missing command capability list")
            return
        }
        guard case .strings(let features) = result.values["features"] else {
            Issue.record("Missing feature capability list")
            return
        }
        #expect(Set(commands) == Set(QACommandName.allCases.map(\.rawValue)))
        #expect(Set(features) == Set(QAFeatureKey.allCases.map(\.rawValue)))
    }

    @Test func unsupportedVersionReturnsStructuredFailureAndIsRecorded() async throws {
        let context = try await makeContext()
        let commandID = UUID()
        let result = await context.router.execute(QACommandEnvelope(
            version: 99,
            runID: context.runID,
            id: commandID,
            name: .getState
        ))

        #expect(result.status == .failed)
        #expect(result.failure?.code == "unsupported_version")
        let recorded = await context.router.result(for: commandID)
        #expect(recorded?.commandID == commandID)
    }

    @Test func legacyVersionOneDerivesStableTraceFromRunAndCommandIDs() async throws {
        let context = try await makeContext()
        let commandID = UUID()
        let result = await context.router.execute(QACommandEnvelope(
            version: 1,
            runID: context.runID,
            id: commandID,
            name: .getState
        ))

        #expect(result.status == .succeeded)
        #expect(result.rootTraceID == context.runID.uuidString.lowercased())
        #expect(result.traceID == commandID.uuidString.lowercased())
        #expect(result.spanID?.count == 16)
        #expect(result.traceparent?.hasPrefix("00-\(context.runID.uuidString.replacingOccurrences(of: "-", with: "").lowercased())-") == true)
    }

    @Test func versionTwoPropagatesExplicitTraceContext() async throws {
        let context = try await makeContext()
        let root = UUID()
        let operation = UUID()
        let rootHex = root.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let span = "abcdef1234567890"
        let parent = "00-\(rootHex)-\(span)-01"
        let result = await context.router.execute(QACommandEnvelope(
            runID: context.runID,
            name: .getState,
            traceID: operation.uuidString,
            rootTraceID: root.uuidString,
            spanID: span,
            traceparent: parent
        ))

        #expect(result.status == .succeeded)
        #expect(result.rootTraceID == root.uuidString.lowercased())
        #expect(result.traceID == operation.uuidString.lowercased())
        #expect(result.spanID == span)
        #expect(result.traceparent == parent)
    }

    @Test func mismatchedTraceparentFailsClosed() async throws {
        let context = try await makeContext()
        let root = UUID()
        let otherRoot = UUID()
        let otherHex = otherRoot.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let result = await context.router.execute(QACommandEnvelope(
            runID: context.runID,
            name: .getState,
            rootTraceID: root.uuidString,
            traceparent: "00-\(otherHex)-abcdef1234567890-01"
        ))

        #expect(result.status == .failed)
        #expect(result.failure?.code == "invalid_trace")
        #expect(result.rootTraceID == nil)
    }

    @Test func stateCommandReflectsActivatedRegistryRun() async throws {
        let context = try await makeContext()
        let result = await context.router.execute(QACommandEnvelope(
            runID: context.runID,
            name: .getState
        ))

        #expect(result.status == .succeeded)
        #expect(result.values["runID"] == .string(context.runID.uuidString))
        let history = await context.router.history()
        #expect(history.count == 1)
    }

    @Test func attachedRootSupportsTabAndOnboardingControl() async throws {
        let adapter = QAApplicationAdapter()
        let profileManager = DeviceProfileManager()
        let verificationStore = OfflineVerificationStore()
        var activeTab = "preview"
        var onboardingComplete = false
        adapter.attachRoot(
            profileManager: profileManager,
            verificationStore: verificationStore,
            activeTab: { activeTab },
            selectTab: { activeTab = $0 },
            setOnboardingComplete: { onboardingComplete = $0 }
        )

        try adapter.navigateTab("diagnostics")
        _ = try await adapter.applyFeature(.onboardingComplete, value: .bool(true))
        let snapshot = await adapter.snapshot()

        #expect(activeTab == "diagnostics")
        #expect(onboardingComplete)
        #expect(snapshot.rootMounted)
        #expect(snapshot.activeTab == "diagnostics")
    }

    @Test func liveCommandWithoutMountedRootFailsWithTypedCode() async throws {
        let context = try await makeContext()
        let result = await context.router.execute(QACommandEnvelope(
            runID: context.runID,
            name: .navigateTab,
            payload: QACommandPayload(tab: "browser")
        ))

        #expect(result.status == .failed)
        #expect(result.failure?.code == "root_unavailable")
    }

    private func makeContext() async throws -> (router: QACommandRouter, runID: UUID) {
        let suite = "qa.command.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let registry = QAFeatureRegistry(defaults: defaults)
        let runID = UUID()
        _ = try await registry.activate(QASessionManifest(runID: runID))
        let router = QACommandRouter(registry: registry, application: QAApplicationAdapter())
        return (router, runID)
    }
}
#endif
