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
}
