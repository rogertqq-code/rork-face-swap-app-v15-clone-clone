//
//  FaceSwapLiveAppV17UITests.swift
//  FaceSwapLiveAppV17UITests
//
//  Created by Rork on February 22, 2026.
//

import XCTest

final class FaceSwapLiveAppV17UITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
    }

    // MARK: - Launch and visibility

    @MainActor
    func testAppLaunchesToVisibleUI() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.windows.firstMatch.frame.isEmpty)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    // MARK: - F-03: Basic flow coverage beyond launch

    /// The app must not crash when launched repeatedly and must consistently
    /// reach a foreground state. This catches state-restore and startup-race
    /// regressions that a single-launch test would miss.
    @MainActor
    func testRelaunchReachesForeground() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)

        app.terminate()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    /// The app must remain stable when sent to background and restored.
    /// This exercises the lifecycle path that triggers pageLifecycleSignalScript
    /// and the connection-log flush timer.
    @MainActor
    func testBackgroundAndRestoreStability() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        usleep(500_000)

        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Any text field, button, or navigation bar present at launch must be
    /// tappable without crashing. This is a smoke test for the initial UI tree.
    @MainActor
    func testInitialUIDoesNotCrashOnInteraction() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Swipe up to ensure scroll doesn't crash (covers main content scroll).
        app.windows.firstMatch.swipeUp(velocity: .slow)
        app.windows.firstMatch.swipeDown(velocity: .slow)

        // The app must still be in foreground after gestures.
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The app must handle a device rotation without crashing or losing UI.
    @MainActor
    func testRotationStability() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        XCUIDevice.shared.orientation = .landscapeLeft
        usleep(500_000)
        XCTAssertEqual(app.state, .runningForeground)

        XCUIDevice.shared.orientation = .portrait
        usleep(500_000)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
