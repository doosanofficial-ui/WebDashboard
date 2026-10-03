import XCTest

/// Uses only the verification runner's disposable Simulator and synthetic profile.
final class DashboardEditingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }
    private func openEditor(_ app: XCUIApplication) {
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let edit = app.buttons["profile-edit-dashboard"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.tap()
        XCTAssertTrue(app.buttons["undo-dashboard-layout"].waitForExistence(timeout: 5))
    }
    private func widget(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "editor-widget-" + id).firstMatch
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let ax = XCTAttachment(string: app.debugDescription); ax.name = name + "-AX"; ax.lifetime = .keepAlways; add(ax)
    }
    func testSelectedCardKeepsConfigurationAvailableOnDemand() {
        let app = XCUIApplication(); app.launch(); capture(app, "SYNTHETIC-concept-live-idle"); openEditor(app)
        let active = widget("fixture-0", app); XCTAssertTrue(active.waitForExistence(timeout: 5)); active.tap()
        let configuration = app.buttons["widget-configuration-disclosure"]
        XCTAssertTrue(configuration.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["apply-widget-configuration"].isHittable)
        configuration.tap()
        XCTAssertTrue(app.buttons["apply-widget-configuration"].waitForExistence(timeout: 5))
        configuration.tap()
        XCTAssertFalse(app.buttons["apply-widget-configuration"].isHittable)
        XCTAssertFalse(app.buttons["undo-dashboard-layout"].isEnabled)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "SYNTHETIC-concept-editor-compact"
        image.lifetime = .keepAlways; add(image)
    }

    func testMoveReleaseUndoRedoAndReentryPreserveNeighbor() {
        let app = XCUIApplication(); openEditor(app)
        let active = widget("fixture-0", app); let neighbor = widget("fixture-1", app)
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        let before = active.value as? String; let neighborBefore = neighbor.value as? String
        XCTAssertNotNil(before)
        let start = active.coordinate(withNormalizedOffset: .init(dx: 0.4, dy: 0.3))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(.init(dx: active.frame.width / 2 + 4, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        let undo = app.buttons["undo-dashboard-layout"]
        XCTAssertTrue(undo.isEnabled)
        let moved = active.value as? String; XCTAssertNotEqual(moved, before)
        XCTAssertEqual(neighbor.value as? String, neighborBefore)
        capture(app, "magnetic-move-release")
        undo.tap(); XCTAssertEqual(active.value as? String, before)
        app.buttons["redo-dashboard-layout"].tap(); XCTAssertEqual(active.value as? String, moved)
        app.buttons["Done"].tap(); app.buttons["profile-edit-dashboard"].tap()
        XCTAssertEqual(widget("fixture-0", app).value as? String, moved)
        app.buttons["undo-dashboard-layout"].tap()
        XCTAssertEqual(widget("fixture-0", app).value as? String, before)
    }
    func testResizeReleaseUndoPreserveNeighbor() {
        let app = XCUIApplication(); openEditor(app)
        let active = widget("fixture-0", app); let neighbor = widget("fixture-1", app)
        XCTAssertTrue(active.waitForExistence(timeout: 5)); active.tap()
        let before = active.value as? String; let neighborBefore = neighbor.value as? String
        let handle = app.buttons["resize-dashboard-widget-fixture-0"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let start = handle.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(.init(dx: active.frame.width / 2 + 4, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertNotEqual(active.value as? String, before)
        XCTAssertEqual(neighbor.value as? String, neighborBefore)
        capture(app, "magnetic-resize-release")
        app.buttons["undo-dashboard-layout"].tap(); XCTAssertEqual(active.value as? String, before)
    }
    func testOverlappingResizeKeepsSelectedHandleUsableForNextResize() {
        let app = XCUIApplication(); openEditor(app)
        let active = widget("fixture-0", app); let neighbor = widget("fixture-1", app)
        XCTAssertTrue(active.waitForExistence(timeout: 5)); active.tap()
        let before = active.value as? String; let neighborBefore = neighbor.value as? String
        let handle = app.buttons["resize-dashboard-widget-fixture-0"]
        let column = (active.frame.width + 8) / 2
        var start = handle.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(.init(dx: column, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        let expanded = active.value as? String; XCTAssertNotEqual(expanded, before)
        XCTAssertEqual(neighbor.value as? String, neighborBefore)
        capture(app, "overlapping-resize-before-second-drag")
        XCTAssertTrue(handle.isHittable, "Selected card's resize handle must remain reachable above a neighbor")
        start = handle.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(.init(dx: -column, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertEqual(active.value as? String, before)
        XCTAssertEqual(neighbor.value as? String, neighborBefore)
        app.buttons["undo-dashboard-layout"].tap(); XCTAssertEqual(active.value as? String, expanded)
        app.buttons["undo-dashboard-layout"].tap(); XCTAssertEqual(active.value as? String, before)
    }

    func testLandscapeMoveUsesCurrentMeasuredGeometry() {
        let app = XCUIApplication(); openEditor(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        let active = widget("fixture-0", app); XCTAssertTrue(active.waitForExistence(timeout: 5))
        let before = active.value as? String
        let start = active.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.2))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(.init(dx: active.frame.width / 2 + 4, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.buttons["undo-dashboard-layout"].isEnabled)
        XCTAssertNotEqual(active.value as? String, before)
        capture(app, "magnetic-landscape-release")
        app.buttons["undo-dashboard-layout"].tap(); XCTAssertEqual(active.value as? String, before)
    }
}
