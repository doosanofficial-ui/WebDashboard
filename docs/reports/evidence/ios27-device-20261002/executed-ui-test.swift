import XCTest

final class PhysicalDeploymentTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testInstalledMainScreensAndIdleAppReturn() {
        let app = XCUIApplication(bundleIdentifier: "local.webdashboard.Telemetry")
        app.activate()
        XCTAssertTrue(app.tabBars.buttons["Live"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Live"].tap()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["live-status-strip"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toggle-recording"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.66)).press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.66)))
        sleep(1)
        capture(app, "physical-latest-main-live")

        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.navigationBars["Signals"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "signals-health-card").firstMatch.waitForExistence(timeout: 5))
        capture(app, "physical-latest-main-signals")

        app.tabBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sessions-hero").firstMatch.waitForExistence(timeout: 5))
        capture(app, "physical-latest-main-sessions")

        app.tabBars.buttons["Setup"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "setup-server-card").firstMatch.waitForExistence(timeout: 5))
        capture(app, "physical-latest-main-setup-private")

        app.tabBars.buttons["Live"].tap()
        XCUIDevice.shared.press(.home)
        sleep(5)
        app.activate()
        XCTAssertTrue(app.navigationBars["Telemetry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["live-status-strip"].waitForExistence(timeout: 5))
        capture(app, "physical-latest-main-idle-return")
    }
}
