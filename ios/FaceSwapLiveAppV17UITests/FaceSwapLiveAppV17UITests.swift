import Foundation
import XCTest

final class FaceSwapLiveAppV17UITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test01ManifestLaunchPublishesRunIdentityAndCapabilities() throws {
        let harness = try launchedHarness()
        defer { finish(harness, scenario: #function) }

        XCTAssertEqual(harness.app.state, .runningForeground)
        XCTAssertTrue(harness.waitForElement("qa.banner").exists)
        harness.openControlSurface()
        harness.waitForElementValue("qa.control.runID", contains: harness.runID.uuidString)
        harness.closeControlSurface()

        let result = try harness.execute(.getCapabilities)
        XCTAssertTrue(result.contains("onboardingComplete"))
        XCTAssertTrue(result.contains("startNativeWebRTC"))
        XCTAssertTrue(result.contains("simulateMemoryWarning"))
        XCTAssertEqual(harness.probeValue("qa.value.lastError"), "none")
    }

    @MainActor
    func test02AllRootTabsAreCommandNavigable() throws {
        let harness = try launchedHarness()
        defer { finish(harness, scenario: #function) }

        let scenarios: [(tab: String, screen: String)] = [
            ("preview", "preview.screen"),
            ("browser", "browser.screen"),
            ("eyedeekit", "eyedeekit.screen"),
            ("media", "media.screen"),
            ("diagnostics", "diagnostics.screen"),
            ("profile", "profile.screen")
        ]

        for scenario in scenarios {
            try harness.execute(.navigate(tab: scenario.tab))
            XCTAssertTrue(harness.waitForElement(scenario.screen).exists, "Tab \(scenario.tab) did not expose \(scenario.screen)")
        }
    }

    @MainActor
    func test03BrowserLoadURLUpdatesChromeWebContentAndState() throws {
        let harness = try launchedHarness()
        defer { finish(harness, scenario: #function) }

        try harness.execute(.navigate(tab: "browser"))
        harness.waitForElement("browser.screen")
        try harness.execute(.loadURL("https://example.com/qa-cable-run"), timeout: 45)

        harness.waitForProbe("qa.value.currentURL", contains: "https://example.com/qa-cable-run", timeout: 30)
        harness.waitForElementValue("browser.urlField", contains: "example.com/qa-cable-run", timeout: 30)
        harness.waitForElementValue("browser.webContent", contains: "example.com/qa-cable-run", timeout: 30)

        let state = try harness.execute(.getState)
        XCTAssertTrue(state.contains("\"browserMounted\" : true"))
        XCTAssertTrue(state.contains("example.com/qa-cable-run"))
    }

    @MainActor
    func test04FeatureRegistryMutatesLiveInjectionAndRejectsBadVersion() throws {
        let harness = try launchedHarness()
        defer { finish(harness, scenario: #function) }

        try harness.execute(.navigate(tab: "browser"))
        try harness.execute(.setFeature(.injectionProfile, .string("rawFramePipe")))
        harness.waitForProbe("qa.value.featureMatrix", contains: "injectionProfile=rawFramePipe")

        try harness.execute(.setFeature(.sensorSimulationEnabled, .bool(true)))
        harness.waitForProbe("qa.value.featureMatrix", contains: "sensorSimulationEnabled=true")

        var invalid = QAUITestCommand.getState
        invalid.version = 99
        let failure = try harness.execute(invalid, expectedStatus: "failed")
        XCTAssertTrue(failure.contains("unsupported_version"))
        harness.waitForProbe("qa.value.lastError", contains: "Unsupported QA command version 99")

        try harness.execute(.setFeature(.injectionProfile, .string("canvasPipeline")))
        harness.waitForProbe("qa.value.featureMatrix", contains: "injectionProfile=canvasPipeline")
    }

    @MainActor
    func test05DeterministicSequenceDrivesMediaAndNativeWebRTC() throws {
        let harness = try launchedHarness()
        defer { finish(harness, scenario: #function) }

        try harness.execute(.navigate(tab: "browser"))
        try harness.execute(.loadSequence(named: "QA Deterministic Photo Sequence"))
        harness.waitForProbe("qa.value.sequenceStep", contains: "/1")

        try harness.execute(.enableMedia)
        harness.waitForProbe("qa.value.captureState", contains: "active:", timeout: 30)
        harness.waitForElementValue("browser.media.status", contains: "active=true", timeout: 30)

        try harness.execute(.loadURL("https://example.com/qa-native-webrtc"), timeout: 45)
        harness.waitForProbe("qa.value.currentURL", contains: "qa-native-webrtc", timeout: 30)
        let nativeResult = try harness.execute(.startNativeWebRTC, timeout: 60)
        let videoTracks = (harness.resultValue("videoTracks", in: nativeResult) as? NSNumber)?.intValue ?? 0
        let structuredRequestID = (harness.resultValue("requestID", in: nativeResult) as? String) ?? ""
        XCTAssertGreaterThanOrEqual(videoTracks, 1)
        XCTAssertFalse(structuredRequestID.isEmpty)

        let requestID = harness.probeValue("qa.value.webRTCState")
        XCTAssertFalse(["", "none", "idle", "starting"].contains(requestID), "Native WebRTC did not publish a request ID")

        try harness.execute(.stopMedia)
        harness.waitForProbe("qa.value.captureState", contains: "inactive:", timeout: 30)
    }

    @MainActor
    func test06DiagnosticsRunsAgainstBuiltInFixture() throws {
        let harness = try launchedHarness()
        defer { finish(harness, scenario: #function) }

        let result = try harness.execute(.runDiagnostics, timeout: 120)
        let progress = (harness.resultValue("progress", in: result) as? NSNumber)?.doubleValue ?? 0
        let summary = (harness.resultValue("summary", in: result) as? String) ?? ""
        XCTAssertEqual(progress, 1, accuracy: 0.001)
        XCTAssertFalse(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        harness.waitForElement("diagnostics.screen")
        harness.waitForElement("diagnostics.fullTest.summary", timeout: 30)
        XCTAssertEqual(harness.probeValue("qa.value.lastError"), "none")
    }

    @MainActor
    func test07LifecycleRecoveryEvidenceAndStateCleanup() throws {
        let harness = try launchedHarness()
        defer { finish(harness, scenario: #function) }

        try harness.execute(.navigate(tab: "browser"))
        try harness.execute(.loadSequence(named: "QA Deterministic Photo Sequence"))
        try harness.execute(.enableMedia)
        harness.waitForProbe("qa.value.captureState", contains: "active:")

        try harness.execute(.simulateMemoryWarning)
        XCTAssertEqual(harness.probeValue("qa.value.lastCommand"), "simulateMemoryWarning")

        let evidence = try harness.execute(.exportEvidence, timeout: 45)
        XCTAssertTrue(evidence.contains("\"artifacts\""))
        XCTAssertTrue(evidence.contains("events-"))

        try harness.execute(.clearState)
        harness.waitForProbe("qa.value.sequenceStep", contains: "0/0")
        harness.waitForProbe("qa.value.captureState", contains: "inactive:")
    }

    @MainActor
    func test08CableDevicePublishesPhysicalCaptureAndAudioOutcome() throws {
        let harness = try launchedHarness(installPermissionHandlers: true)
        defer { finish(harness, scenario: #function) }
        try XCTSkipUnless(harness.runMode == .cable, "Physical capture assertions run only in the Cable Device test-plan configuration.")

        try harness.execute(.navigate(tab: "preview"))
        harness.app.tap()
        harness.waitForElement("preview.screen")
        harness.waitForElementValue("preview.screen", contains: "capture=running", timeout: 45)
        let cameraBefore = harness.probeValue("preview.camera.position")
        let flip = harness.waitForElement("preview.camera.flip")
        if flip.isHittable {
            flip.tap()
            harness.waitForElementValue("preview.camera.position", contains: cameraBefore.contains("Front") ? "Back" : "Front", timeout: 20)
        }

        try harness.execute(.navigate(tab: "browser"))
        try harness.execute(.loadSequence(named: "QA Deterministic Photo Sequence"))
        try harness.execute(.enableMedia)
        try harness.execute(.loadURL("https://example.com/qa-cable-native"), timeout: 45)
        let result = try harness.execute(.startNativeWebRTC, timeout: 60)
        let audioTracks = (harness.resultValue("audioTracks", in: result) as? NSNumber)?.intValue ?? 0
        let audioOutcome = (harness.resultValue("audioOutcome", in: result) as? String) ?? ""
        XCTAssertGreaterThanOrEqual(audioTracks, 1)
        XCTAssertTrue(["realMicrophone", "silentFallback", "mockFixture"].contains(audioOutcome))
        XCTAssertEqual(harness.probeValue("qa.value.audioOutcome"), audioOutcome)
        try harness.execute(.stopMedia)
    }

    @MainActor
    private func launchedHarness(installPermissionHandlers: Bool = false) throws -> QAUITestHarness {
        let harness = QAUITestHarness()
        if installPermissionHandlers {
            harness.installPermissionHandlers(testCase: self)
        }
        try harness.launch()
        return harness
    }

    @MainActor
    private func finish(_ harness: QAUITestHarness, scenario: String) {
        if (testRun?.failureCount ?? 0) > 0 {
            harness.attachFailureEvidence(to: self, name: scenario)
        }
        harness.terminate()
    }
}
