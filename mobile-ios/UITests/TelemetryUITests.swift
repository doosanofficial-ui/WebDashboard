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
        XCTAssertTrue(app.staticTexts["last-mark"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Connection"].tap()
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
        XCTAssertTrue(app.staticTexts["local-recording-status"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["start-adapter-demo"].waitForExistence(timeout: 5))
    }

    func testAdapterProfileImportAndLiveControlsAreVisible() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Connection"].tap()
        XCTAssertTrue(app.buttons["import-adapter-profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["start-live-adapter"].waitForExistence(timeout: 5))
    }

    func testMeasurementExportControlIsVisible() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Connection"].tap()
        XCTAssertTrue(app.buttons["export-measurement-json"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["measurement-export-status"].waitForExistence(timeout: 5))
    }

    func testDashboardEditorExposesPageAndLayoutControls() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        app.buttons["edit-dashboard"].tap()
        XCTAssertTrue(app.buttons["add-dashboard-page"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dashboard-editor-canvas-main"].waitForExistence(timeout: 5))
    }
}
