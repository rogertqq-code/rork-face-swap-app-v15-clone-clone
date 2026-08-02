import XCTest

final class FaceSwapLiveAppV17UITestsLaunchTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDeterministicQALaunchScreenshot() throws {
        let harness = QAUITestHarness()
        try harness.launch()
        defer { harness.terminate() }

        XCTAssertTrue(harness.waitForElement("qa.banner").exists)
        XCTAssertTrue(harness.waitForElement("browser.screen").exists)
        XCTAssertEqual(harness.probeValue("qa.value.lastError"), "none")

        let screenshot = XCTAttachment(screenshot: harness.app.screenshot())
        screenshot.name = "QA Launch - \(harness.runMode.rawValue) - \(harness.runID.uuidString)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let state = XCTAttachment(
            string: "runID=\(harness.runID.uuidString)\nrunMode=\(harness.runMode.rawValue)\nfeatures=\(harness.probeValue("qa.value.featureMatrix"))"
        )
        state.name = "QA Launch State"
        state.lifetime = .keepAlways
        add(state)
    }
}
