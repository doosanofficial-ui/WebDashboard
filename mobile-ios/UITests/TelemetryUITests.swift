import XCTest

final class TelemetryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testDashboardMarkAndConnectionValidation() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        let mark = app.buttons["mark-event"]
        for _ in 0..<5 where !mark.isHittable { app.swipeUp() }
        XCTAssertTrue(mark.waitForExistence(timeout: 3))
        mark.tap()
        XCTAssertTrue(app.otherElements["session-mark"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Setup"].tap()
        let server = app.textFields["server-url"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.tap()
        let existing = server.value as? String ?? ""
        if existing.hasPrefix("http") { server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)) }
        server.typeText("http://example.invalid")
        app.buttons["connect-server"].tap()
        XCTAssertTrue(app.staticTexts["Enter a trusted HTTPS server URL"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Connection validation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDashboardShowsLocalMeasurementRecorderState() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.otherElements["sessions-hero"].waitForExistence(timeout: 5))
    }

    func testRecordingToggleIsVisibleInLiveCockpit() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["toggle-recording"].waitForExistence(timeout: 5))
    }

    func testSessionControlsCanStartRecordingAndGPS() {
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let locationPermission = addUIInterruptionMonitor(withDescription: "Location permission") { alert in
            for label in ["Allow While Using App", "Allow Once", "Change to Always Allow", "Allow"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        defer { _ = locationPermission }

        let existingAlwaysPermission = springboard.buttons["Change to Always Allow"]
        if existingAlwaysPermission.waitForExistence(timeout: 2) {
            existingAlwaysPermission.tap()
        }

        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))

        let recording = app.buttons["toggle-recording"]
        XCTAssertTrue(recording.waitForExistence(timeout: 5))
        recording.tap()
        let recordingState = app.staticTexts.matching(NSPredicate(format: "label == %@", "RECORDING")).firstMatch
        XCTAssertTrue(recordingState.waitForExistence(timeout: 5))

        let gps = app.buttons["toggle-gps"]
        XCTAssertTrue(gps.waitForExistence(timeout: 5))
        gps.tap()
        app.tap()
        let newAlwaysPermission = springboard.buttons["Change to Always Allow"]
        if newAlwaysPermission.waitForExistence(timeout: 5) {
            newAlwaysPermission.tap()
        }
        let gpsState = app.staticTexts.matching(NSPredicate(format: "label == %@", "GPS ON")).firstMatch
        XCTAssertTrue(gpsState.waitForExistence(timeout: 15))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Physical session controls started"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBackgroundTransitionReturnsToLiveCockpit() {
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let locationPermission = addUIInterruptionMonitor(withDescription: "Location permission") { alert in
            for label in ["Allow While Using App", "Allow Once", "Change to Always Allow", "Allow"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        defer { _ = locationPermission }

        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))

        let recordingState = app.staticTexts.matching(NSPredicate(format: "label == %@", "RECORDING")).firstMatch
        if !recordingState.exists {
            XCTAssertTrue(app.buttons["toggle-recording"].waitForExistence(timeout: 5))
            app.buttons["toggle-recording"].tap()
        }
        XCTAssertTrue(recordingState.waitForExistence(timeout: 5))

        let gpsState = app.staticTexts.matching(NSPredicate(format: "label == %@", "GPS ON")).firstMatch
        if !gpsState.exists {
            XCTAssertTrue(app.buttons["toggle-gps"].waitForExistence(timeout: 5))
            app.buttons["toggle-gps"].tap()
            app.tap()
            let always = springboard.buttons["Change to Always Allow"]
            if always.waitForExistence(timeout: 5) {
                always.tap()
            }
        }
        XCTAssertTrue(gpsState.waitForExistence(timeout: 15))

        XCUIDevice.shared.press(.home)
        sleep(10)
        app.activate()

        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        XCTAssertTrue(recordingState.waitForExistence(timeout: 5))
        XCTAssertTrue(gpsState.waitForExistence(timeout: 5))
    }

    func testCockpitAnchorsAreVisible() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["live-status-strip"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["primary-metric"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["session-mark"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["location-card"].waitForExistence(timeout: 5))
    }

    func testDashboardRendersProfileDefinedWidgetLabel() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Speed"].waitForExistence(timeout: 5))
    }

    func testDemoAdapterControlIsExplicitlyAvailable() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Signals"].tap()
        app.buttons["Developer / Adapter"].tap()
        XCTAssertTrue(app.buttons["start-adapter-demo"].waitForExistence(timeout: 5))
    }

    func testSignalCatalogAddsNumericWidgetToDashboard() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Signals"].tap()
        app.buttons["Developer / Adapter"].tap()
        app.buttons["start-adapter-demo"].tap()
        let addControl = app.buttons["add-signal-widget-demo.signal"]
        for _ in 0..<12 where !addControl.exists { app.swipeUp() }
        XCTAssertTrue(addControl.waitForExistence(timeout: 10), "The synthetic signal needs a direct dashboard action")
        addControl.tap()
        // The offline fixture restores its own dashboard page; a fresh install uses Main.
        let fixturePage = app.buttons["Fixture"]
        let targetPage = fixturePage.exists ? fixturePage : app.buttons["Main"]
        XCTAssertTrue(targetPage.waitForExistence(timeout: 5))
        targetPage.tap()
        let numeric = app.buttons["Numeric Gauge"]
        XCTAssertTrue(numeric.waitForExistence(timeout: 5))
        XCTAssertTrue(app.frame.contains(numeric.frame), "The menu action must be on screen")
        numeric.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["signal-dashboard-action-status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["signal-dashboard-action-status"].label, "Widget added to dashboard")
        func revealAddedWidget() {
            let addedWidget = app.staticTexts["DEMO SIGNAL"]
            for _ in 0..<20 where !addedWidget.isHittable { app.swipeUp() }
            XCTAssertTrue(addedWidget.isHittable, "The added signal must appear on the dashboard")
        }
        app.tabBars.buttons["Live"].tap()
        revealAddedWidget()
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "signal-added-to-dashboard-synthetic"
        capture.lifetime = .keepAlways
        add(capture)

        app.terminate()
        app.launch()
        revealAddedWidget()
    }

    func testAdapterProfileImportAndLiveControlsAreVisible() {
        func reveal(_ control: XCUIElement, in app: XCUIApplication) -> Bool {
            for _ in 0..<24 {
                if control.exists {
                    let frame = control.frame
                    let viewport = app.frame
                    if frame.height > 0, frame.minX >= viewport.minX + 8,
                       frame.maxX <= viewport.maxX - 8,
                       frame.midY > viewport.minY + 140,
                       frame.midY < viewport.maxY - 140 { return true }
                }
                app.swipeUp()
            }
            return false
        }

        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Setup"].tap()
        let export = app.buttons["export-adapter-profile"]
        XCTAssertTrue(reveal(export, in: app), "Profile actions must be reachable above the tab bar")
        XCTAssertTrue(app.buttons["import-adapter-profile"].exists)
        XCTAssertFalse(export.isEnabled)
        let englishActions = XCTAttachment(screenshot: app.screenshot())
        englishActions.name = "setup-en-profile-actions-visible"
        englishActions.lifetime = .keepAlways
        add(englishActions)
        let start = app.buttons["start-live-adapter"]
        XCTAssertTrue(reveal(start, in: app), "Live acquisition must be reachable without opening developer tools")
        XCTAssertFalse(start.isEnabled, "A verified adapter profile is required before acquisition")
        XCTAssertTrue(app.staticTexts["setup-live-adapter-status"].exists)
        XCTAssertTrue(app.buttons["stop-live-adapter"].exists)
        XCTAssertTrue(app.buttons["edit-signal-catalog"].waitForExistence(timeout: 5))
        let englishCapture = XCTAttachment(screenshot: app.screenshot())
        englishCapture.name = "setup-en-live-controls-visible"
        englishCapture.lifetime = .keepAlways
        add(englishCapture)

        app.terminate()
        let korean = XCUIApplication()
        korean.launchArguments = ["--app-language", "ko", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        korean.launch()
        XCTAssertTrue(korean.tabBars.buttons["설정"].waitForExistence(timeout: 10))
        korean.tabBars.buttons["설정"].tap()
        let koreanExport = korean.buttons["export-adapter-profile"]
        XCTAssertTrue(reveal(koreanExport, in: korean), "Korean profile actions must be reachable above the tab bar")
        let koreanActions = XCTAttachment(screenshot: korean.screenshot())
        koreanActions.name = "setup-ko-max-profile-actions-visible"
        koreanActions.lifetime = .keepAlways
        add(koreanActions)
        let koreanStart = korean.buttons["start-live-adapter"]
        XCTAssertTrue(reveal(koreanStart, in: korean), "Korean live controls must be reachable above the tab bar")
        XCTAssertFalse(koreanStart.isEnabled)
        XCTAssertTrue(reveal(korean.buttons["stop-live-adapter"], in: korean), "Korean Stop must fit within the screen")
        let koreanLive = XCTAttachment(screenshot: korean.screenshot())
        koreanLive.name = "setup-ko-max-live-controls-visible"
        koreanLive.lifetime = .keepAlways
        add(koreanLive)
    }

    func testAdapterProfileFilesExportAndImportRoundTrip() {
        func reveal(_ element: XCUIElement, in app: XCUIApplication) {
            for _ in 0..<18 where !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.isHittable, app.debugDescription)
        }
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]
        app.launch()
        app.tabBars.buttons["Setup"].tap()
        let export = app.buttons["export-adapter-profile"]
        reveal(export, in: app)
        XCTAssertTrue(app.staticTexts["Profile loaded: SYNTHETIC Files profile"].waitForExistence(timeout: 5),
                      "This test requires only the owned Simulator's loopback profile")
        export.tap()
        let save = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(save.isEnabled)
        let exportSheet = XCTAttachment(screenshot: app.screenshot())
        exportSheet.name = "synthetic-profile-native-files-export"
        exportSheet.lifetime = .keepAlways
        add(exportSheet)
        save.tap()
        XCTAssertTrue(app.staticTexts["Adapter profile JSON saved"].waitForExistence(timeout: 15), app.debugDescription)

        let importProfile = app.buttons["import-adapter-profile"]
        reveal(importProfile, in: app)
        importProfile.tap()
        let browse = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Browse", "둘러보기"])
        ).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 10), app.debugDescription)
        browse.tap()
        let localFiles = app.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["On My iPhone", "나의 iPhone"])
        ).firstMatch
        if localFiles.exists { localFiles.tap() }
        let file = app.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "telemetry-adapter-profile.json")
        ).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15), app.debugDescription)
        file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let pickerDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: file
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pickerDismissed], timeout: 15), .completed,
                       "Selecting the saved JSON must dismiss the native Files picker: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Profile loaded: SYNTHETIC Files profile"].waitForExistence(timeout: 15),
                      app.debugDescription)
        let imported = XCTAttachment(screenshot: app.screenshot())
        imported.name = "synthetic-profile-files-reimported"
        imported.lifetime = .keepAlways
        add(imported)
    }

    func testBLEObservationCaptureControlIsVisible() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Setup"].tap()
        app.buttons["Developer / diagnostics"].tap()
        app.buttons["BLE discovery (read-only)"].tap()
        XCTAssertTrue(app.buttons["save-ble-observation"].waitForExistence(timeout: 5))
    }

    func testBLEScanControlExposesStableAutomationIdentifier() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Setup"].tap()
        app.buttons["Developer / diagnostics"].tap()
        app.buttons["BLE discovery (read-only)"].tap()
        XCTAssertTrue(app.buttons["scan-ble-adapters"].waitForExistence(timeout: 5))
    }

    func testPhysicalBLEObservationCapture() {
        let app = XCUIApplication()
        let bluetoothPermission = addUIInterruptionMonitor(withDescription: "Bluetooth permission") { alert in
            for label in ["Allow", "OK"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        defer { _ = bluetoothPermission }

        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Setup"].tap()
        app.buttons["Developer / diagnostics"].tap()
        app.buttons["BLE discovery (read-only)"].tap()
        let scan = app.buttons["scan-ble-adapters"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()
        sleep(15)
        let copy = app.buttons["copy-ble-observation"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Physical BLE discovery observation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMeasurementExportControlIsVisible() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Sessions"].tap()
        let export = app.buttons["sessions-export-json"]
        for _ in 0..<8 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.isHittable)
        XCTAssertTrue(app.otherElements["sessions-export-card"].waitForExistence(timeout: 5))
    }

    func testMeasurementCSVExportControlIsVisible() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Sessions"].tap()
        let export = app.buttons["sessions-export-csv"]
        for _ in 0..<8 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.isHittable)
    }

    func testDashboardEditorExposesPageAndLayoutControls() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.buttons["edit-dashboard"].tap()
        XCTAssertTrue(app.buttons["add-dashboard-page"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dashboard-editor-canvas-main"].waitForExistence(timeout: 5))
    }

    func testDashboardEditorExposesWidgetCreationMenu() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.buttons["edit-dashboard"].tap()
        XCTAssertTrue(app.buttons["add-dashboard-widget"].waitForExistence(timeout: 5))
    }

    func testDashboardEditorExposesWidgetConfigurationInspector() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.buttons["edit-dashboard"].tap()
        XCTAssertTrue(app.otherElements["editor-widget-ws-fl"].waitForExistence(timeout: 5))
        app.otherElements["editor-widget-ws-fl"].tap()
        XCTAssertTrue(app.buttons["apply-widget-configuration"].waitForExistence(timeout: 5))
    }

    func testDashboardEditorConditionFieldsAreAvailable() {
        let app = XCUIApplication()
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.buttons["edit-dashboard"].tap()
        app.otherElements["editor-widget-ws-fl"].tap()
        XCTAssertTrue(app.switches["Condition enabled"].waitForExistence(timeout: 5))
    }
}
