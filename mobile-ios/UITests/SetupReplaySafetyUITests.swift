import XCTest

/// Focused synthetic fixture gate kept separate from the fixed 31-test matrix.
final class SetupReplaySafetyUITests: XCTestCase {
    func testSetupStopIsDisabledDuringReplay() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-language", "en"]
        app.launch()
        app.tabBars.buttons["Sessions"].tap()
        let picker = app.buttons["saved-session-picker"]
        for _ in 0..<8 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.isHittable, app.debugDescription)
        picker.tap()
        let fixture = app.buttons["saved-session-offline-replay-fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 5), app.debugDescription)
        fixture.tap()
        app.buttons["replay-saved-session"].tap()
        let replayPosition = app.staticTexts["session-replay-position"]
        XCTAssertTrue(replayPosition.waitForExistence(timeout: 8), app.debugDescription)
        let recordedTime = replayPosition.value as? String
        XCTAssertNotNil(recordedTime)

        app.tabBars.buttons["Setup"].tap()
        let stopLive = app.buttons["stop-live-adapter"]
        XCTAssertTrue(stopLive.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(stopLive.isEnabled, "A live-adapter Stop must not clear a Replay snapshot")
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5))
        XCTAssertEqual(replayPosition.value as? String, recordedTime)
    }
}
