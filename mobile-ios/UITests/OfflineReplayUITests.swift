import XCTest

/// Runs only on a disposable, pre-seeded Simulator. No acquisition button is tapped.
final class OfflineReplayUITests: XCTestCase {

    #if targetEnvironment(simulator)
    private func openFixtureSession(_ app: XCUIApplication, startedAt: Double = 100, sessionID: String? = nil) {
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Sessions"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        let picker = app.buttons["saved-session-picker"]
        for _ in 0..<8 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.isHittable)
        picker.tap()
        let fixture = app.buttons["saved-session-" + (sessionID ?? (startedAt == 300 ? "offline-seek-fixture" : "offline-replay-fixture"))]
        XCTAssertTrue(fixture.waitForExistence(timeout: 5), app.debugDescription)
        fixture.tap()
    }

    private func revealHistoryElement(_ element: XCUIElement, in app: XCUIApplication, upperHalf: Bool = false) -> Bool {
        for attempt in 0...24 {
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            var bottom = app.tabBars.firstMatch.frame.minY - 8
            let controls = app.otherElements["replay-cockpit-controls"]
            if controls.exists && controls.frame.minY > top { bottom = min(bottom, controls.frame.minY - 8) }
            let stop = app.buttons["cockpit-replay-stop"]
            if stop.exists && stop.frame.minY > top { bottom = min(bottom, stop.frame.minY - 8) }
            let exists = element.exists
            let rect = exists ? element.frame : .zero
            let upperBottom = (top + bottom) / 2
            let visibleBottom = upperHalf && rect.height + 8 <= upperBottom - top ? upperBottom : bottom
            if exists && rect.minY >= top && rect.maxY <= visibleBottom { return true }
            if attempt == 24 { return false }
            let preferred = upperHalf ? top + min(60, (bottom - top) / 4) : (top + bottom) / 2
            let desired = min(max(preferred, top + rect.height / 2 + 4), visibleBottom - rect.height / 2 - 4)
            let delta = exists ? rect.midY - desired : (bottom - top) / 3
            let center = (top + bottom) / 2
            let distance = min(max(abs(delta), 12), max(24, (bottom - top) / 3))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: center / app.frame.height))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98,
                dy: (center - (delta >= 0 ? distance : -distance)) / app.frame.height))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        return false
    }

    private func nativeSaveButton(_ app: XCUIApplication) -> XCUIElement {
        // Files exposes this action by identifier on iOS 27 and by label on iOS 26.
        let identified = app.buttons["DOCPicker.actionButton"]
        if identified.exists { return identified }
        return app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons
            .matching(NSPredicate(format: "label IN %@", ["Save", "저장"])).firstMatch
    }

    private func nativeExporterIsVisible(_ app: XCUIApplication) -> Bool {
        app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].exists
            || app.buttons["DOCPicker.actionButton"].exists
    }

    private func readyNativeSaveButton(_ app: XCUIApplication) -> XCUIElement {
        // Files may expose its navigation before an action or filename editor.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.nativeExporterIsVisible(app)
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, app.debugDescription)
        let save = nativeSaveButton(app)
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        return save
    }

    private func nativeExporterClosed(_ app: XCUIApplication) -> XCTNSPredicateExpectation {
        // Flat root queries avoid walking children of an already removed Files bar.
        XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.nativeExporterIsVisible(app)
        }, object: app)
    }

    private func revealExport(_ app: XCUIApplication, format: String) -> XCUIElement {
        let button = app.buttons["sessions-export-" + format]
        for _ in 0..<8 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable, app.debugDescription)
        return button
    }
    #endif

    func testRecordedSignalHistoryContainsOnlySelectedTimePrefix() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recorded graph audit is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        openFixtureSession(app, startedAt: 300)
        app.buttons["replay-saved-session"].tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5))
        func captureHistory(expectedCount: Int, name: String) {
            app.tabBars.buttons["Live"].tap()
            let title = app.staticTexts["Recorded SOC history fixture"]
            XCTAssertTrue(revealHistoryElement(title, in: app, upperHalf: true), app.debugDescription)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
            XCTAssertTrue(app.staticTexts["Recorded samples: \(expectedCount)"].exists, app.debugDescription)
        }
        func seek(_ seconds: String) {
            app.tabBars.buttons["Sessions"].tap()
            let input = app.textFields["replay-seek-seconds"]
            XCTAssertTrue(revealHistoryElement(input, in: app), app.debugDescription)
            XCTAssertTrue(input.isHittable, app.debugDescription)
            input.tap()
            let existing = (input.value as? String) ?? ""
            if Double(existing) != nil { input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)) }
            input.typeText(seconds)
            app.buttons["replay-seek-go"].tap()
            XCTAssertTrue(app.staticTexts[seconds + " / 5.0 seconds"].waitForExistence(timeout: 5), app.debugDescription)
        }
        captureHistory(expectedCount: 2, name: "DEMO-recorded-history-end-two-original-samples")
        seek("2.5")
        captureHistory(expectedCount: 1, name: "DEMO-recorded-history-backward-one-original-sample")
        seek("0.0")
        captureHistory(expectedCount: 0, name: "DEMO-recorded-history-start-no-future-sample")
        XCTAssertTrue(app.staticTexts["No recorded samples in this window"].exists)
        #endif
    }

    func testRecordedGPSRouteContainsOnlySelectedTimePrefix() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recorded route audit is Simulator-only")
        #else
        continueAfterFailure = false
        for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", category, "--audit-ui-layout"]
        openFixtureSession(app, sessionID: "offline-route-fixture")
        app.buttons["replay-saved-session"].tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5))
        let typeAudit = app.staticTexts["ui-dynamic-type-audit"]
        XCTAssertTrue(revealHistoryElement(typeAudit, in: app), app.debugDescription)
        let expectedType = category == "UICTContentSizeCategoryL" ? "large" : "accessibility5"
        XCTAssertEqual(typeAudit.label, "Dynamic Type: " + expectedType)
        let typeProof = XCTAttachment(string: "requested " + category + "; observed " + typeAudit.label)
        typeProof.name = "DEMO-observed-content-size-category"; typeProof.lifetime = .keepAlways; add(typeProof)
        func captureHistory(expectedCount: Int, name: String) {
            app.tabBars.buttons["Live"].tap()
            let title = app.staticTexts["Recorded GPS route fixture"]
            let revealed = revealHistoryElement(title, in: app, upperHalf: true)
            XCTAssertEqual(app.state, .runningForeground)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name + "-" + category; shot.lifetime = .keepAlways; add(shot)
            XCTAssertTrue(revealed, app.debugDescription)
            let count = app.staticTexts["Recorded fixes: \(expectedCount)"]
            XCTAssertTrue(revealHistoryElement(count, in: app), app.debugDescription)
            if expectedCount == 2 {
                let quality = app.staticTexts["Latest recorded fix not plottable"]
                XCTAssertTrue(revealHistoryElement(quality, in: app), app.debugDescription)
                let controls = app.otherElements["replay-cockpit-controls"]
                let visibleTop = app.navigationBars.firstMatch.frame.maxY + 8
                XCTAssertGreaterThanOrEqual(count.frame.minY, visibleTop)
                XCTAssertGreaterThanOrEqual(quality.frame.minY, visibleTop)
                XCTAssertLessThanOrEqual(count.frame.maxY, controls.frame.minY - 8)
                XCTAssertLessThanOrEqual(quality.frame.maxY, controls.frame.minY - 8)
                let statusShot = XCTAttachment(screenshot: app.screenshot())
                statusShot.name = "DEMO-recorded-route-visible-status-" + category
                statusShot.lifetime = .keepAlways; add(statusShot)
            }
        }
        func seek(_ seconds: String) {
            app.tabBars.buttons["Sessions"].tap()
            let input = app.textFields["replay-seek-seconds"]
            XCTAssertTrue(revealHistoryElement(input, in: app), app.debugDescription)
            XCTAssertTrue(input.isHittable, app.debugDescription)
            input.tap()
            let existing = (input.value as? String) ?? ""
            if Double(existing) != nil { input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)) }
            input.typeText(seconds)
            app.buttons["replay-seek-go"].tap()
            XCTAssertTrue(app.staticTexts[seconds + " / 5.0 seconds"].waitForExistence(timeout: 5), app.debugDescription)
        }
        captureHistory(expectedCount: 2, name: "DEMO-recorded-route-end-two-original-samples")
        XCTAssertTrue(app.staticTexts["Latest recorded fix not plottable"].exists)
        seek("2.5")
        captureHistory(expectedCount: 1, name: "DEMO-recorded-route-backward-one-original-sample")
        seek("0.0")
        captureHistory(expectedCount: 0, name: "DEMO-recorded-route-start-no-future-sample")
        XCTAssertTrue(app.staticTexts["No plottable recorded fixes at this time"].exists)
        app.terminate()
        }
        #endif
    }

    func testPlayingLongSliderDragPreservesCapturedUserTarget() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Held slider gesture is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments.append("--audit-replay-slider")
        openFixtureSession(app, sessionID: "offline-slider-fixture")
        app.buttons["replay-saved-session"].tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5))
        func reveal(_ id: String) -> XCUIElement {
            let b = app.buttons[id]
            for _ in 0..<8 where !b.isHittable { app.swipeUp() }
            for _ in 0..<8 where !b.isHittable { app.swipeDown() }
            XCTAssertTrue(b.isHittable, app.debugDescription)
            return b
        }
        reveal("replay-seek-start").tap()
        app.segmentedControls["replay-speed"].buttons["0.5×"].tap()
        reveal("replay-play").tap()
        XCTAssertTrue(app.buttons["replay-pause"].waitForExistence(timeout: 5))
        let slider = app.sliders["replay-time-slider"]
        XCTAssertTrue(slider.isHittable, app.debugDescription)
        let position = app.staticTexts["replay-position"]
        let seconds = Double(position.label.split(separator: " ").first.map(String.init) ?? "0") ?? 0
        let thumb = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.04 + 0.92 * seconds / 30, dy: 0.5))
        let target = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        thumb.press(forDuration: 2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 3)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "DEMO-held-slider-target"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertEqual(app.staticTexts["slider-editing-audit"].label, "Playback held during editing",
            "Actual editing must pause accepted playback ticks from touch-down through release")
        let wanted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = Double(position.label.split(separator: " ").first.map(String.init) ?? "") ?? -1
            return abs(value - 22.5) <= 1.5
        }, object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [wanted], timeout: 5), .completed,
            "Held75% thumb must seek near22.5s, not a timer-overwritten position: " + position.label + "\n" + app.debugDescription)
        XCTAssertFalse(app.buttons["replay-pause"].exists)
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.staticTexts["53.0"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Sessions"].tap()
        app.buttons["stop-replay-header"].tap()
        #endif
    }

    func testNativeExportBackgroundReturnCancelAndReentry() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Native lifecycle fixture is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        openFixtureSession(app)
        revealExport(app, format: "json").tap()
        _ = readyNativeSaveButton(app)
        // This is the owned test Simulator's Home, never a physical device.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        if nativeExporterIsVisible(app) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.085))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        }
        let closed = nativeExporterClosed(app)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, app.debugDescription)
        revealExport(app, format: "csv").tap()
        _ = readyNativeSaveButton(app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "DEMO-native-export-background-return-csv"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.085))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        let closedAgain = nativeExporterClosed(app)
        XCTAssertEqual(XCTWaiter.wait(for: [closedAgain], timeout: 5), .completed, app.debugDescription)
        let replay = app.buttons["replay-saved-session"]
        for _ in 0..<8 where !replay.isHittable { app.swipeDown() }
        replay.tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.staticTexts["48.5"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Sessions"].tap()
        app.buttons["stop-replay-header"].tap()
        #endif
    }

    func testRecordedPlaybackPauseSpeedAndAutomaticEnd() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Offline fixture playback is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        openFixtureSession(app, startedAt: 300)
        app.buttons["replay-saved-session"].tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5))
        func reveal(_ id: String) -> XCUIElement {
            let button = app.buttons[id]
            for _ in 0..<8 where !button.isHittable { app.swipeUp() }
            for _ in 0..<8 where !button.isHittable { app.swipeDown() }
            XCTAssertTrue(button.isHittable, app.debugDescription)
            return button
        }
        reveal("replay-seek-start").tap()
        let speed = app.segmentedControls["replay-speed"]
        XCTAssertTrue(speed.waitForExistence(timeout: 5), app.debugDescription)
        speed.buttons["0.5×"].tap()
        reveal("replay-play").tap()
        let position = app.staticTexts["replay-position"]
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "0.0 / 5.0 seconds"), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
        reveal("replay-pause").tap()
        let paused = position.label
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", paused), object: position)
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1), .completed)
        app.tabBars.buttons["Signals"].tap()
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        XCTAssertEqual(position.label, paused)
        reveal("replay-seek-start").tap()
        speed.buttons["0.5×"].tap()
        reveal("replay-play").tap()
        XCTAssertTrue(app.buttons["replay-pause"].waitForExistence(timeout: 5))
        speed.buttons["2×"].tap() // Change rate during playback, not only while paused.
        XCTAssertTrue(app.staticTexts["5.0 / 5.0 seconds"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["replay-pause"].exists)
        XCTAssertFalse(app.buttons["replay-play"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "DEMO-recorded-playback-end"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.staticTexts["53.0"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["replay-pause"].exists)
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5))
        app.buttons["stop-replay-header"].tap()
        #endif
    }

    func testRecordedTimeSeekingAcrossTabsAndEditorReturn() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Offline fixture UI is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        openFixtureSession(app, startedAt: 300)
        app.buttons["replay-saved-session"].tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5))
        func reveal(_ id: String) -> XCUIElement {
            let item = app.buttons[id]
            for _ in 0..<10 where !item.isHittable { app.swipeUp() }
            XCTAssertTrue(item.isHittable, app.debugDescription)
            return item
        }
        reveal("replay-seek-start").tap()
        XCTAssertTrue(app.staticTexts["0.0 / 5.0 seconds"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.staticTexts["No recorded signal at this time"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["53.0"].exists)
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        func seek(_ text: String) {
            _ = reveal("replay-seek-go")
            let field = app.textFields["replay-seek-seconds"]
            field.tap()
            if let value = field.value as? String, value != "Seconds" {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            }
            field.typeText(text + "\n")
            reveal("replay-seek-go").tap()
        }
        seek("2.5")
        XCTAssertTrue(app.staticTexts["2.5 / 5.0 seconds"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.staticTexts["48.5"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        seek("100")
        XCTAssertTrue(app.staticTexts["5.0 / 5.0 seconds"].waitForExistence(timeout: 5))
        seek("nan")
        XCTAssertTrue(app.staticTexts["5.0 / 5.0 seconds"].exists)
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.staticTexts["53.0"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Live"].tap()
        let edit = app.buttons["edit-dashboard"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["5.0 / 5.0 seconds"].exists)
        _ = reveal("replay-seek-start")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "DEMO-recorded-time-exploration"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["stop-replay-header"].tap()
        XCTAssertFalse(app.buttons["stop-replay-header"].exists)
        openFixtureSession(app, startedAt: 300)
        app.buttons["replay-saved-session"].tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5))
        app.buttons["stop-replay-header"].tap()
        #endif
    }

    func testNativeExportCancelReentryAndReplayAcrossTabs() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Offline fixture UI is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        openFixtureSession(app)
        for format in ["json", "csv", "json"] {
            revealExport(app, format: format).tap()
            let save = readyNativeSaveButton(app)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "native-" + format + "-export"; attachment.lifetime = .keepAlways; add(attachment)
            // Dismiss the native sheet with the same drag a user performs.
            // A Files accessibility element labelled Cancel can overlap its menu.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.085))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
            let closed = nativeExporterClosed(app)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, app.debugDescription)
            XCTAssertTrue(app.tabBars.buttons["Sessions"].waitForExistence(timeout: 5))
        }
        let replay = app.buttons["replay-saved-session"]
        for _ in 0..<8 where !replay.isHittable { app.swipeDown() }
        replay.tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.navigationBars["Signals"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["48.5"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        app.buttons["stop-replay-header"].tap()
        XCTAssertFalse(app.buttons["stop-replay-header"].exists)
        #endif
    }

    func testNativeJSONCSVSaveConfirmsCompletion() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Offline fixture UI is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        openFixtureSession(app)
        for format in ["json", "csv"] {
            revealExport(app, format: format).tap()
            let save = readyNativeSaveButton(app)
            XCTAssertTrue(save.isEnabled)
            save.tap()
            XCTAssertTrue(app.staticTexts[format.uppercased() + " file saved"].waitForExistence(timeout: 15), app.debugDescription)
            let dismissed = nativeExporterClosed(app)
            let completion = XCTWaiter.wait(for: [dismissed], timeout: 5)
            if completion != .completed {
                let state = XCTAttachment(string: app.debugDescription)
                state.name = "DEMO-native-save-not-dismissed-" + format; state.lifetime = .keepAlways; add(state)
                let image = XCTAttachment(screenshot: app.screenshot())
                image.name = "DEMO-native-save-not-dismissed-" + format; image.lifetime = .keepAlways; add(image)
            }
            XCTAssertEqual(completion, .completed)
            XCTAssertTrue(app.staticTexts[format.uppercased() + " file saved"].waitForExistence(timeout: 5), app.debugDescription)
        }
        #endif
    }

    func testSetupPresentsLocalWorkflowWithoutServerOrCredential() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Offline fixture UI is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Setup"].tap()
        XCTAssertTrue(app.otherElements["setup-first-run"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["CAN diagnostics, GPS, recording, CSV/JSON and Replay work locally without a server or account."].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Connect to server")).firstMatch.exists)
        XCTAssertFalse(app.otherElements["setup-server-card"].exists)
        XCTAssertFalse(app.secureTextFields["Pairing credential"].exists)
        openFixtureSession(app)
        let replay = app.buttons["replay-saved-session"]
        replay.tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.navigationBars["Signals"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["48.5"].waitForExistence(timeout: 5))
        #endif
    }

    func testSeededSessionPickerSnapshotAndReadOnlyControls() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Offline fixture UI is Simulator-only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Sessions"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        let picker = app.buttons["saved-session-picker"]
        for _ in 0..<6 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let fixture = app.buttons["saved-session-offline-replay-fixture"]
        guard fixture.waitForExistence(timeout: 5) else {
            throw XCTSkip("Requires the dedicated offline-replay-fixture Simulator seed")
        }
        fixture.tap()
        let replay = app.buttons["replay-saved-session"]
        XCTAssertTrue(replay.isEnabled)
        replay.tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["stop-replay-header"].isHittable)
        let savedCard = app.otherElements["saved-sessions-card"]
        for _ in 0..<5 where savedCard.frame.maxY > app.frame.height - 140 { app.swipeUp() }
        let saved = XCTAttachment(screenshot: app.screenshot())
        saved.name = "offline-fixture-sessions-replay"; saved.lifetime = .keepAlways; add(saved)
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.navigationBars["Signals"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["48.5"].waitForExistence(timeout: 5))
        let values = XCTAttachment(screenshot: app.screenshot())
        values.name = "offline-fixture-replayed-soc"; values.lifetime = .keepAlways; add(values)
        app.tabBars.buttons["Live"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "replay-banner").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["toggle-recording"].exists)
        XCTAssertFalse(app.buttons["toggle-gps"].exists)
        XCTAssertFalse(app.buttons["mark-event"].exists)
        for _ in 0..<5 where !app.descendants(matching: .any).matching(identifier: "profile-widget-fixture-0").firstMatch.exists { app.swipeUp() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "profile-widget-fixture-0").firstMatch.exists, app.debugDescription)
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
