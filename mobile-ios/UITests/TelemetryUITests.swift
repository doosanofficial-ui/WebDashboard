import XCTest

final class TelemetryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testDashboardMarkAndConnectionValidation() {
        let app = XCUIApplication()
        app.launch()
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
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.otherElements["sessions-hero"].waitForExistence(timeout: 5))
    }

    func testRecordingToggleIsVisibleInLiveCockpit() {
        let app = XCUIApplication()
        app.launch()
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

        app.launch()
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

        app.launch()
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
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["live-status-strip"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["primary-metric"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["session-mark"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["location-card"].waitForExistence(timeout: 5))
    }

    func testDashboardRendersProfileDefinedWidgetLabel() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Speed"].waitForExistence(timeout: 5))
    }

    func testDemoAdapterControlIsExplicitlyAvailable() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Signals"].tap()
        app.buttons["Developer / Adapter"].tap()
        XCTAssertTrue(app.buttons["start-adapter-demo"].waitForExistence(timeout: 5))
    }

    func testAdapterProfileImportAndLiveControlsAreVisible() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Setup"].tap()
        app.buttons["Developer / diagnostics"].tap()
        XCTAssertTrue(app.buttons["import-adapter-profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["start-live-adapter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["edit-signal-catalog"].waitForExistence(timeout: 5))
    }

    func testBLEObservationCaptureControlIsVisible() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Setup"].tap()
        app.buttons["Developer / diagnostics"].tap()
        app.buttons["BLE discovery (read-only)"].tap()
        XCTAssertTrue(app.buttons["save-ble-observation"].waitForExistence(timeout: 5))
    }

    func testMeasurementExportControlIsVisible() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.buttons["export-measurement-json"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["sessions-export-card"].waitForExistence(timeout: 5))
    }

    func testMeasurementCSVExportControlIsVisible() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.buttons["export-measurement-csv"].waitForExistence(timeout: 5))
    }

    func testDashboardEditorExposesPageAndLayoutControls() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.buttons["edit-dashboard"].tap()
        XCTAssertTrue(app.buttons["add-dashboard-page"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dashboard-editor-canvas-main"].waitForExistence(timeout: 5))
    }

    func testDashboardEditorExposesWidgetCreationMenu() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.buttons["edit-dashboard"].tap()
        XCTAssertTrue(app.buttons["add-dashboard-widget"].waitForExistence(timeout: 5))
    }

    func testDashboardEditorExposesWidgetConfigurationInspector() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.buttons["edit-dashboard"].tap()
        XCTAssertTrue(app.otherElements["editor-widget-ws-fl"].waitForExistence(timeout: 5))
        app.otherElements["editor-widget-ws-fl"].tap()
        XCTAssertTrue(app.buttons["apply-widget-configuration"].waitForExistence(timeout: 5))
    }

    func testDashboardEditorConditionFieldsAreAvailable() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.buttons["edit-dashboard"].tap()
        app.otherElements["editor-widget-ws-fl"].tap()
        XCTAssertTrue(app.switches["Condition enabled"].waitForExistence(timeout: 5))
    }
}
