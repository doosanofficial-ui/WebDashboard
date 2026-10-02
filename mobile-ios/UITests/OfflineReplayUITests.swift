import XCTest

/// Runs only on a disposable, pre-seeded Simulator. No acquisition button is tapped.
final class OfflineReplayUITests: XCTestCase {
    func testSeededSessionPickerSnapshotAndReadOnlyControls() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Offline fixture UI is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Sessions"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Sessions"].tap()
        let picker = app.buttons["saved-session-picker"]
        for _ in 0..<6 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let fixture = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "DEMO", "1970")).firstMatch
        guard fixture.waitForExistence(timeout: 5) else {
            throw XCTSkip("Requires the dedicated offline-replay-fixture Simulator seed")
        }
        fixture.tap()
        let replay = app.buttons["replay-saved-session"]
        XCTAssertTrue(replay.isEnabled)
        replay.tap()
        XCTAssertTrue(app.buttons["stop-replay"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["stop-replay-header"].isHittable)
        let savedCard = app.otherElements["saved-sessions-card"]
        for _ in 0..<5 where savedCard.frame.maxY > app.frame.height - 140 { app.swipeUp() }
        let saved = XCTAttachment(screenshot: app.screenshot())
        saved.name = "offline-fixture-sessions-replay"; saved.lifetime = .keepAlways; add(saved)
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.staticTexts["48.5"].waitForExistence(timeout: 5))
        let values = XCTAttachment(screenshot: app.screenshot())
        values.name = "offline-fixture-replayed-soc"; values.lifetime = .keepAlways; add(values)
        app.tabBars.buttons["Live"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "replay-banner").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["toggle-recording"].isEnabled)
        XCTAssertFalse(app.buttons["toggle-gps"].isEnabled)
        XCTAssertFalse(app.buttons["mark-event"].isEnabled)
        let custom = app.buttons["Open custom profile"]
        for _ in 0..<10 where !custom.isHittable { app.swipeUp() }
        XCTAssertTrue(custom.exists)
        custom.images["collapsed"].tap()
        for _ in 0..<5 where !app.descendants(matching: .any).matching(identifier: "profile-widget-fixture-0").firstMatch.exists { app.swipeUp() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "profile-widget-fixture-0").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "profile-widget-fixture-1").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "profile-widget-fixture-2").firstMatch.exists)
        let lastWidget = app.descendants(matching: .any).matching(identifier: "profile-widget-fixture-2").firstMatch
        for _ in 0..<5 where lastWidget.frame.maxY > app.frame.height - 200 { app.swipeUp() }
        let widgets = XCTAttachment(screenshot: app.screenshot())
        widgets.name = "offline-fixture-replayed-widgets"; widgets.lifetime = .keepAlways; add(widgets)
        app.tabBars.buttons["Sessions"].tap()
        let stop = app.buttons["stop-replay-header"]
        stop.tap()
        XCTAssertTrue(app.buttons["replay-saved-session"].exists)
        #endif
    }
}
