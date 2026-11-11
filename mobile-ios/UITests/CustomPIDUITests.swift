import XCTest

/// Runs on a disposable simulator only. No radio, connection or permission action.
final class CustomPIDUITests: XCTestCase {
    func testDraftValidationAndCancelKeepProfileUnchanged() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic Simulator scope only")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-language", "en"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Signals"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Signals"].tap()
        let create = app.buttons["signals-new-custom-pid"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        let originalEditEnabled = app.buttons["signals-edit-catalog"].isEnabled
        create.tap()
        XCTAssertTrue(app.textFields["custom-pid-id"].waitForExistence(timeout: 5))
        capture(app, "SYNTHETIC-custom-pid-empty")
        XCTAssertFalse(app.buttons["custom-pid-save"].isEnabled)
        app.buttons["custom-pid-validate"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.staticTexts["Check Signal ID."].exists)
        app.alerts.buttons["OK"].tap()
        let id = app.textFields["custom-pid-id"]
        id.tap(); id.typeText("synthetic.cancelled")
        app.buttons["custom-pid-cancel"].tap()
        create.tap()
        XCTAssertEqual(app.textFields["custom-pid-id"].value as? String, "Signal ID")
        capture(app, "SYNTHETIC-custom-pid-cancel-reset")
        app.buttons["custom-pid-cancel"].tap()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["signals-edit-catalog"].isEnabled, originalEditEnabled)
    }

    func testOfflinePreviewAndSavePersistSyntheticPID() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic Simulator scope only")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-language", "en"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Signals"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Signals"].tap()
        guard app.buttons["signals-edit-catalog"].isEnabled else {
            throw XCTSkip("Requires a disposable Simulator seeded with SYNTHETIC diagnostic profile")
        }
        app.buttons["signals-new-custom-pid"].tap()
        XCTAssertTrue(app.staticTexts["SYNTHETIC diagnostic profile"].waitForExistence(timeout: 5))
        enter(app, "id", "synthetic.ui.coolant")
        enter(app, "name", "SYNTHETIC UI coolant")
        enter(app, "unit", "C")
        enter(app, "command", "05")
        enter(app, "request", "7E0")
        enter(app, "response", "7E8")
        enter(app, "offset", "-40", replace: true)
        enter(app, "sample", "7E8 03 41 05 64")
        let decode = app.buttons["custom-pid-preview"]
        reveal(app, decode); decode.tap()
        let value = app.staticTexts["custom-pid-preview-value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.label, "SAMPLE · 60 C")
        XCTAssertTrue(UIConditionWait.until(timeout: 5) { !app.keyboards.firstMatch.exists }, "Preview must dismiss the keyboard")
        XCTAssertTrue(value.isHittable && app.windows.firstMatch.frame.contains(value.frame), "Preview value must be fully visible before capture")
        capture(app, "SYNTHETIC-custom-pid-preview-60C")
        XCTAssertTrue(app.buttons["custom-pid-save"].isEnabled)
        app.buttons["custom-pid-save"].tap()
        XCTAssertTrue(app.buttons["signals-new-custom-pid"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        app.tabBars.buttons["Signals"].tap()
        let filter = app.textFields["Filter signal, CAN ID, source"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.tap(); filter.typeText("synthetic.ui.coolant\n")
        let saved = app.staticTexts["SYNTHETIC UI coolant"]
        reveal(app, saved)
        XCTAssertTrue(saved.exists, app.debugDescription)
        capture(app, "SYNTHETIC-custom-pid-persisted-no-live-value")
    }

    func testWrongECUSampleDoesNotDisplayAValue() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic Simulator scope only")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-language", "en"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Signals"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Signals"].tap()
        app.buttons["signals-new-custom-pid"].tap()
        enter(app, "id", "synthetic.wrong.ecu")
        enter(app, "name", "SYNTHETIC wrong ECU")
        enter(app, "command", "05")
        enter(app, "request", "7E0")
        enter(app, "response", "7E8")
        enter(app, "sample", "7E9 03 41 05 64")
        XCTAssertEqual(app.textFields["custom-pid-sample"].value as? String, "7E9 03 41 05 64")
        let decode = app.buttons["custom-pid-preview"]
        reveal(app, decode); decode.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse(app.staticTexts["custom-pid-preview-value"].exists)
        capture(app, "SYNTHETIC-custom-pid-invalid-ECU-no-value")
        app.buttons["custom-pid-cancel"].tap()
    }

    func testKoreanLargestTextKeepsIdentityFieldsReachable() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic Simulator scope only")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-language", "ko", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let signals = app.tabBars.buttons["신호"]
        XCTAssertTrue(signals.waitForExistence(timeout: 15))
        signals.tap(); app.buttons["signals-new-custom-pid"].tap()
        XCTAssertTrue(app.buttons["custom-pid-cancel"].waitForExistence(timeout: 5))
        capture(app, "SYNTHETIC-custom-pid-ko-largest-top")
        let field = app.textFields["custom-pid-id"]
        reveal(app, field)
        XCTAssertEqual(field.placeholderValue, "신호 ID")
        XCTAssertTrue(field.frame.width > app.frame.width * 0.7)
        capture(app, "SYNTHETIC-custom-pid-ko-largest-identity")
        app.buttons["custom-pid-cancel"].tap()
    }

    private func enter(_ app: XCUIApplication, _ id: String, _ text: String, replace: Bool = false) {
        let field = app.textFields["custom-pid-" + id]
        reveal(app, field); field.tap()
        if replace {
            // A center tap may place the cursor at the beginning. Select the
            // entire field explicitly rather than deleting before that cursor.
            field.press(forDuration: 1.2)
            let selectAll = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Select All", "전체 선택"])).firstMatch
            if selectAll.waitForExistence(timeout: 2) { selectAll.tap() }
            else {
                let alternative = app.buttons.matching(NSPredicate(format: "label IN %@", ["Select All", "전체 선택"])).firstMatch
                XCTAssertTrue(alternative.waitForExistence(timeout: 2), app.debugDescription)
                alternative.tap()
            }
        }
        field.typeText(text)
    }

    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<18 {
            if element.exists && element.isHittable { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.43))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.23))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Missing reachable element: \(element)")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
