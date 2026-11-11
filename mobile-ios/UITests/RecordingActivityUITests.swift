import XCTest

final class RecordingActivityUITests: XCTestCase {
    func testLiveActivityIsOptInRECLinkedAndEndsWhenStopped() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dedicated synthetic Simulator only")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-language", "en"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Setup"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Setup"].tap()
        let toggle = app.switches["recording-activity-enabled"]
        reveal(app, toggle)
        set(app, toggle, enabled: false)
        XCTAssertEqual(toggle.value as? String, "0")
        capture(app, "SYNTHETIC-live-activity-off")
        set(app, toggle, enabled: true)
        XCTAssertTrue(UIConditionWait.until(timeout: 5) { app.staticTexts["recording-activity-status"].label == "Ready for the next recording" })
        select(app, pickerID: "recording-activity-first-signal", signalID: "existing.coolant")
        select(app, pickerID: "recording-activity-second-signal", signalID: "existing.rpm")
        capture(app, "SYNTHETIC-live-activity-opted-in")
        app.tabBars.buttons["Live"].tap()
        let rec = app.buttons["toggle-recording"]
        reveal(app, rec)
        XCTAssertEqual(rec.value as? String, "Recording off")
        rec.tap()
        app.tabBars.buttons["Setup"].tap()
        let status = app.staticTexts["recording-activity-status"]
        reveal(app, status)
        XCTAssertTrue(UIConditionWait.until(timeout: 10) { status.label == "Live Activity active" }, status.label)
        capture(app, "SYNTHETIC-live-activity-recording")
        let screen = app.windows.firstMatch.frame
        XCUIDevice.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(home.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(UIConditionWait.until(timeout: 10) { home.icons["Telemetry"].isHittable }, "Home screen must settle before capture")
        captureSystem("SYNTHETIC-live-activity-home")
        // Read-only Notification Center observation. Never handle permissions.
        let origin = home.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: screen.width * 0.1, dy: 2))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: screen.width * 0.1, dy: screen.height * 0.8)))
        captureSystem("SYNTHETIC-live-activity-notification-center")
        let permissionChoice = home.buttons.matching(NSPredicate(format: "label IN %@",
            ["Allow", "Always Allow", "Don't Allow", "Don’t Allow", "허용", "항상 허용", "허용 안 함"])).firstMatch
        if home.alerts.firstMatch.exists || permissionChoice.exists {
            XCTFail("Live Activity system choice requires separate review; leave it untouched")
            return
        }
        // Widget text is not exposed in this Simulator's SpringBoard AX tree.
        // Give iOS its observed stale-render scheduling window, then preserve
        // real pixels for mandatory direct review; this is not a latency SLA.
        let staleWindow = expectation(description: "Observe the system stale rendering window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 130) { staleWindow.fulfill() }
        wait(for: [staleWindow], timeout: 150)
        captureSystem("SYNTHETIC-live-activity-stale")
        XCUIDevice.shared.press(.home)
        app.activate()
        app.tabBars.buttons["Live"].tap()
        reveal(app, rec); rec.tap()
        app.tabBars.buttons["Setup"].tap()
        reveal(app, status)
        XCTAssertTrue(UIConditionWait.until(timeout: 10) { status.label == "Live Activity stopped" })
        capture(app, "SYNTHETIC-live-activity-stopped")
        set(app, toggle, enabled: false)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(home.wait(for: .runningForeground, timeout: 10))
        let endOrigin = home.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        endOrigin.withOffset(CGVector(dx: screen.width * 0.1, dy: 2))
            .press(forDuration: 0.05, thenDragTo: endOrigin.withOffset(CGVector(dx: screen.width * 0.1, dy: screen.height * 0.8)))
        // Direct pixel review must confirm removal. Absence from AX alone
        // would not prove removal because widget text is not exposed there.
        captureSystem("SYNTHETIC-live-activity-system-ended")
        XCUIDevice.shared.press(.home)
    }

    func testRelaunchReconcilesPreviousActivityWithoutRestartingREC() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dedicated synthetic Simulator only")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-language", "en"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Setup"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Setup"].tap()
        let toggle = app.switches["recording-activity-enabled"]
        reveal(app, toggle)
        set(app, toggle, enabled: true)
        app.tabBars.buttons["Live"].tap()
        let rec = app.buttons["toggle-recording"]
        reveal(app, rec); rec.tap()
        app.tabBars.buttons["Setup"].tap()
        let status = app.staticTexts["recording-activity-status"]
        reveal(app, status)
        XCTAssertTrue(UIConditionWait.until(timeout: 10) { status.label == "Live Activity active" }, status.label)
        app.terminate(); app.launch()
        app.tabBars.buttons["Setup"].tap()
        reveal(app, status)
        XCTAssertTrue(UIConditionWait.until(timeout: 10) { status.label == "Ready for the next recording" }, status.label)
        capture(app, "SYNTHETIC-live-activity-relaunched")
        app.tabBars.buttons["Live"].tap()
        reveal(app, rec)
        XCTAssertEqual(rec.value as? String, "Recording off")
        app.tabBars.buttons["Setup"].tap(); reveal(app, toggle)
        set(app, toggle, enabled: false)
    }

    func testKoreanLargestTextSettingsRemainReachable() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dedicated synthetic Simulator only")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-language", "ko", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["설정"].waitForExistence(timeout: 15))
        app.tabBars.buttons["설정"].tap()
        let toggle = app.switches["recording-activity-enabled"]
        reveal(app, toggle)
        set(app, toggle, enabled: false)
        capture(app, "SYNTHETIC-live-activity-ko-largest-toggle")
        set(app, toggle, enabled: true)
        let status = app.staticTexts["recording-activity-status"]
        reveal(app, status)
        XCTAssertEqual(status.label, "다음 기록부터 표시합니다")
        capture(app, "SYNTHETIC-live-activity-ko-largest-status")
        set(app, toggle, enabled: false)
    }

    private func select(_ app: XCUIApplication, pickerID: String, signalID: String) {
        let picker = app.buttons[pickerID]
        reveal(app, picker); picker.tap()
        let option = app.buttons[signalID]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Requires a dedicated synthetic profile with \(signalID)")
        option.tap()
    }

    private func set(_ app: XCUIApplication, _ toggle: XCUIElement, enabled: Bool) {
        let expected = enabled ? "1" : "0"
        if toggle.value as? String == expected { return }
        // SwiftUI exposes a containing switch and an actual UISwitch child on
        // iOS 27. Tapping the container's label does not toggle that control.
        let control = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        reveal(app, control)
        XCTAssertTrue(control.isEnabled && control.isHittable)
        control.tap()
        XCTAssertTrue(UIConditionWait.until(timeout: 5) { toggle.value as? String == expected })
    }

    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        var lastY: CGFloat?
        var stalled = 0
        for _ in 0..<20 {
            let screen = app.windows.firstMatch.frame
            let top = (app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 100) + 12
            let bottom = (app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : screen.height - 30) - 12
            let frame = element.frame
            if element.exists && element.isHittable && frame.midY >= top && frame.midY <= bottom {
                var stableSamples = 0
                let settled = UIConditionWait.until(timeout: 3) {
                    if element.isHittable && abs(element.frame.midY - frame.midY) < 1 { stableSamples += 1 }
                    else { stableSamples = 0 }
                    return stableSamples >= 2
                }
                if settled { return }
            }
            if let lastY, abs(lastY - frame.midY) < 1 { stalled += 1 } else { stalled = 0 }
            if stalled >= 2 {
                capture(app, "SYNTHETIC-activity-scroll-stalled")
                XCTFail("Scroll made no progress for \(element.identifier): \(frame), safe \(top)...\(bottom)")
                return
            }
            lastY = frame.midY
            let movingDown = element.exists && frame.midY < top
            let distance = min(180, max(50, movingDown ? top + 24 - frame.midY : frame.midY - bottom + 24))
            let startY = (top + bottom) / 2
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: screen.width * 0.5, dy: startY))
            let end = origin.withOffset(CGVector(dx: screen.width * 0.5, dy: startY + (movingDown ? distance : -distance)))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        capture(app, "SYNTHETIC-activity-scroll-exhausted")
        XCTFail("Expected reachable Activity setting or REC control")
    }
    private func captureSystem(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
