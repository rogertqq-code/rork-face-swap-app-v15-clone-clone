//
//  FaceSwapLiveAppV17UITests.swift
//  FaceSwapLiveAppV17UITests
//
//  Created by Rork on February 22, 2026.
//

import XCTest

final class FaceSwapLiveAppV17UITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it's important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testAppLaunchesToVisibleUI() throws {
        let app = XCUIApplication()
        app.launch()

        // The app must reach a running foreground state and present a window
        // with visible UI (either the access gate or the main content).
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.windows.firstMatch.frame.isEmpty)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
