import XCTest

/// Synthetic data and app interactions on the runner's disposable Simulator only.
final class UIClarityUITests: XCTestCase {
    override func tearDown() {
        #if targetEnvironment(simulator)
        XCUIDevice.shared.orientation = .portrait
        #endif
        super.tearDown()
    }
    private func launchPortrait(_ app: XCUIApplication) {
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let upright = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.height > app.frame.width
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [upright], timeout: 5), .completed)
    }
    // Static/disabled elements need geometry, not hittability. Scroll in the
    // target's direction so a small viewport cannot overshoot it indefinitely.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<16 {
            guard element.exists else { app.swipeUp(); continue }
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            var bottom = app.tabBars.firstMatch.frame.minY - 8
            let controls = app.otherElements["replay-cockpit-controls"]
            if controls.exists && controls.frame.minY > top { bottom = min(bottom, controls.frame.minY - 8) }
            let stickyStop = app.buttons["cockpit-replay-stop"]
            if stickyStop.exists && stickyStop.frame.minY > top {
                bottom = min(bottom, stickyStop.frame.minY - 8)
            }
            let rect = element.frame
            if rect.minY >= top && rect.maxY <= bottom { return true }
            let center = (top + bottom) / 2
            let delta = rect.midY - center
            let distance = min(max(abs(delta), 12), max(24, (bottom - top) / 3))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: center / app.frame.height))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98,
                dy: (center - (delta >= 0 ? distance : -distance)) / app.frame.height))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        return false
    }
    private func revealMenuItem(_ item: XCUIElement, in app: XCUIApplication) -> Bool {
        let menu = app.collectionViews.firstMatch
        guard menu.waitForExistence(timeout: 5) else { return false }
        for _ in 0..<16 {
            let sheet = app.navigationBars["Saved sessions"]
            let top = sheet.exists ? sheet.frame.maxY + 8 : max(app.frame.minY, menu.frame.minY) + 8
            let bottom = sheet.exists ? app.frame.maxY - 24 : min(menu.frame.maxY - 8, app.tabBars.firstMatch.frame.minY - 60)
            var delta = menu.frame.height / 4
            if item.exists {
                let rect = item.frame
                if rect.minY >= top && rect.maxY <= bottom { return true }
                delta = rect.midY - (top + bottom) / 2
            }
            // The collection's AX frame can extend below the visible popup.
            // Start in its upper half and limit movement to avoid tapping or
            // swiping the obscured underlying screen.
            let startFraction: CGFloat = sheet.exists
                ? ((top + bottom) / 2 - menu.frame.minY) / menu.frame.height
                : (delta >= 0 ? 0.4 : 0.1)
            let distance = min(max(abs(delta), 12), menu.frame.height / 4)
            let endFraction = startFraction - (delta >= 0 ? distance : -distance) / menu.frame.height
            let start = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startFraction))
            let end = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endFraction))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        return false
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func replayFixture(_ app: XCUIApplication, sessionID: String = "offline-replay-fixture") {
        launchPortrait(app)
        selectReplayFixture(app, sessionID: sessionID)
    }
    private func selectReplayFixture(_ app: XCUIApplication, sessionID: String) {
        app.tabBars.buttons["Sessions"].tap()
        let picker = app.buttons["saved-session-picker"]
        XCTAssertTrue(reveal(picker, in: app), app.debugDescription)
        XCTAssertTrue(picker.isHittable, app.debugDescription)
        picker.tap()
        let item = app.buttons["saved-session-\(sessionID)"]
        screenshot(app, "DEMO-session-menu-before-scroll")
        XCTAssertTrue(revealMenuItem(item, in: app), app.debugDescription)
        screenshot(app, "DEMO-session-menu-before-selection")
        let selectedLabel = item.label
        item.tap()
        func waitForPickerClosed() {
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !app.navigationBars["Saved sessions"].exists
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, app.debugDescription)
        }
        waitForPickerClosed()
        // Duplicate start timestamps do not prove which session was selected.
        // Reopen the production sheet and verify the exact row's selected trait.
        picker.tap()
        let selectedRow = app.buttons["saved-session-\(sessionID)"]
        XCTAssertTrue(revealMenuItem(selectedRow, in: app), app.debugDescription)
        XCTAssertTrue(selectedRow.isSelected, app.debugDescription)
        app.navigationBars["Saved sessions"].buttons["Cancel"].tap()
        waitForPickerClosed()
        let boundSelection = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picker.label.contains(selectedLabel)
        }, object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [boundSelection], timeout: 5), .completed, app.debugDescription)
        let openReplay = app.buttons["replay-saved-session"]
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: openReplay)
        let selectionResult = XCTWaiter.wait(for: [selected], timeout: 5)
        if selectionResult != .completed { screenshot(app, "DEMO-session-selection-not-accepted") }
        XCTAssertEqual(selectionResult, .completed, app.debugDescription)
        XCTAssertTrue(reveal(openReplay, in: app), app.debugDescription)
        XCTAssertTrue(openReplay.isHittable, app.debugDescription)
        screenshot(app, "DEMO-selected-session-open-replay-ready")
        openReplay.tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5), app.debugDescription)
    }
    func testSyntheticDemoNeverClaimsLiveVehicleAcquisition() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic UI audit is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication(); launchPortrait(app)
        app.tabBars.buttons["Signals"].tap()
        let controls = app.otherElements["adapter-controls"]
        for _ in 0..<10 where !controls.isHittable { app.swipeUp() }
        XCTAssertTrue(controls.isHittable, app.debugDescription)
        controls.images["collapsed"].tap()
        let demo = app.buttons["Demo adapter"]
        for _ in 0..<5 where !demo.isHittable { app.swipeUp() }
        XCTAssertTrue(demo.isHittable, app.debugDescription); demo.tap()
        app.tabBars.buttons["Live"].tap()
        XCTAssertTrue(app.staticTexts["DEMO · synthetic CAN data"].exists, app.debugDescription)
        screenshot(app, "DEMO-audit-active-dashboard")
        app.tabBars.buttons["Signals"].tap()
        for _ in 0..<8 { app.swipeDown() }
        screenshot(app, "DEMO-audit-active-signals")
        XCTAssertTrue(app.staticTexts["DEMO · synthetic CAN data"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["ADAPTER LIVE"].exists)
        XCTAssertFalse(app.staticTexts["LIVE TELEMETRY"].exists)
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.staticTexts["DEMO · synthetic CAN data"].exists)
        app.tabBars.buttons["Setup"].tap()
        XCTAssertTrue(app.staticTexts["DEMO · synthetic CAN data"].exists)
        #endif
    }
    func testReplayUnknownFreshnessDoesNotBecomeProvenStale() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recording UI audit is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication(); replayFixture(app)
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.staticTexts["48.5"].waitForExistence(timeout: 5))
        screenshot(app, "DEMO-audit-replay-signal-quality")
        let stale = app.buttons["Show stale signals"]
        for _ in 0..<8 where !stale.isHittable { app.swipeDown() }
        XCTAssertTrue(stale.isHittable, app.debugDescription)
        stale.tap()
        screenshot(app, "DEMO-audit-replay-unknown-stale-filter")
        XCTAssertTrue(app.staticTexts["No confirmed stale signals"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Freshness is unknown for this recording."].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "signal-row-SANTAFEHYB_HVBAT_SOC").firstMatch.exists)
        #endif
    }
    func testSelectedSOCProfileIsVisibleBeforeGenericUnavailableSignals() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dashboard UI audit is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication(); replayFixture(app)
        app.tabBars.buttons["Live"].tap()
        screenshot(app, "DEMO-audit-selected-profile-first-screen")
        let widget = app.descendants(matching: .any).matching(identifier: "profile-widget-fixture-0").firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(widget.isHittable, app.debugDescription)
        XCTAssertFalse(app.staticTexts["FRONT LEFT WHEEL"].exists)
        let statusText = app.staticTexts.matching(identifier: "profile-widget-fixture-status")
            .matching(NSPredicate(format: "label == %@", "VALID RECORDED\nFRESHNESS UNKNOWN")).firstMatch
        XCTAssertTrue(reveal(statusText, in: app), app.debugDescription)
        screenshot(app, "DEMO-audit-status-icon-recorded-quality-after-fix")
        XCTAssertTrue(statusText.exists, app.debugDescription)
        let condition = app.staticTexts["NOT EVALUATED"]
        XCTAssertTrue(reveal(condition, in: app), app.debugDescription)
        XCTAssertTrue(condition.exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["CLEAR"].exists)
        screenshot(app, "DEMO-audit-recorded-condition-not-evaluated")
        let gps = app.otherElements["location-card"]
        XCTAssertTrue(reveal(app.staticTexts["RECORDED FIX"], in: app), app.debugDescription)
        XCTAssertTrue(app.staticTexts["RECORDED FIX"].exists, app.debugDescription)
        XCTAssertLessThanOrEqual(condition.frame.maxY, gps.frame.minY,
            "The complete selected profile must occupy space before the GPS card")
        XCTAssertFalse(app.buttons["mark-event"].exists)
        XCTAssertFalse(app.buttons["toggle-recording"].exists)
        XCTAssertFalse(app.buttons["toggle-gps"].exists)
        XCTAssertTrue(app.buttons["cockpit-replay-stop"].isHittable, app.debugDescription)
        screenshot(app, "DEMO-audit-recorded-gps-not-current-position")
        app.terminate()
        replayFixture(app, sessionID: "offline-seek-fixture")
        let slider = app.sliders["replay-time-slider"]
        XCTAssertTrue(reveal(slider, in: app), app.debugDescription)
        XCTAssertTrue(slider.isHittable)
        XCTAssertEqual(slider.label, "Recorded time")
        screenshot(app, "DEMO-audit-default-size-recorded-time-controls-after-fix")
        #endif
    }
    func testRecordedTimeAccessibilityAtLargeTextAndLandscape() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Layout/accessibility audit is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                                "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--audit-ui-layout"]
        replayFixture(app)
        let slider = app.sliders["replay-time-slider"]
        XCTAssertTrue(reveal(slider, in: app), app.debugDescription)
        screenshot(app, "DEMO-audit-large-text-portrait-time-controls")
        XCTAssertTrue(slider.isHittable, app.debugDescription)
        XCTAssertEqual(slider.label, "Recorded time")
        XCTAssertTrue((slider.value as? String)?.contains("seconds") == true, app.debugDescription)
        XCTAssertEqual(app.staticTexts["ui-dynamic-type-audit"].label, "Dynamic Type: accessibility5")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed, app.debugDescription)
        let go = app.buttons["replay-seek-go"]
        XCTAssertTrue(go.waitForExistence(timeout: 5))
        // Keep gestures inside the content area. Whole-app swipes in a short
        // landscape window can pull a system overlay over the app.
        app.activate()
        let foreground = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningForeground
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [foreground], timeout: 5), .completed, app.debugDescription)
        XCTAssertTrue(reveal(go, in: app), app.debugDescription)
        XCTAssertEqual(app.state, .runningForeground, app.debugDescription)
        let window = app.windows.firstMatch
        let windowRotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.frame.width > window.frame.height
        }, object: window)
        XCTAssertEqual(XCTWaiter.wait(for: [windowRotated], timeout: 5), .completed, app.debugDescription)
        let landscapeImage = window.screenshot()
        let attachment = XCTAttachment(screenshot: landscapeImage)
        attachment.name = "DEMO-audit-large-text-landscape-time-controls"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThan(landscapeImage.image.size.width, landscapeImage.image.size.height,
                             "Landscape evidence must contain the landscape app window")
        XCTAssertTrue(go.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(go.frame.height, 44)
        #endif
    }

    func testSingleInstantRecordingExplainsUnavailableTimeNavigation() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Single-instant display audit is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication(); replayFixture(app, sessionID: "offline-instant-fixture")
        XCTAssertTrue(reveal(app.staticTexts["Single recorded instant · no time range"], in: app), app.debugDescription)
        screenshot(app, "DEMO-single-instant-recording-hint")
        let slider = app.sliders["replay-time-slider"]
        XCTAssertTrue(reveal(slider, in: app), app.debugDescription)
        screenshot(app, "DEMO-single-instant-recording-time-controls")
        XCTAssertTrue(app.staticTexts["Single recorded instant · no time range"].exists, app.debugDescription)
        XCTAssertFalse(slider.isEnabled)
        XCTAssertFalse(app.buttons["replay-play"].isEnabled)
        XCTAssertFalse(app.buttons["replay-seek-start"].isEnabled)
        XCTAssertFalse(app.buttons["replay-seek-end"].isEnabled)
        XCTAssertFalse(app.buttons["replay-seek-go"].isEnabled)
        XCTAssertFalse(app.segmentedControls["replay-speed"].isEnabled)
        XCTAssertTrue(app.buttons["stop-replay-header"].isEnabled)
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.staticTexts["48.5"].waitForExistence(timeout: 5))
        // Keep the same app process: replace the existing recorded state without
        // relaunching, so this catches stale values left by a session transition.
        app.tabBars.buttons["Sessions"].tap()
        selectReplayFixture(app, sessionID: "offline-empty-fixture")
        XCTAssertTrue(app.staticTexts["No recorded samples · no time range"].waitForExistence(timeout: 5))
        let emptySlider = app.sliders["replay-time-slider"]
        XCTAssertTrue(reveal(app.staticTexts["No recorded samples · no time range"], in: app), app.debugDescription)
        screenshot(app, "DEMO-empty-recording-hint")
        XCTAssertTrue(reveal(emptySlider, in: app), app.debugDescription)
        screenshot(app, "DEMO-empty-recording-no-time-range")
        XCTAssertTrue(app.staticTexts["No recorded samples · no time range"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Single recorded instant · no time range"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Recorded range:")).count, 0)
        XCTAssertFalse(emptySlider.isEnabled)
        XCTAssertFalse(app.buttons["replay-seek-go"].isEnabled)
        XCTAssertTrue(app.buttons["stop-replay-header"].isEnabled)
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.staticTexts["No recorded signal at this time"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["48.5"].exists)
        #endif
    }

}
