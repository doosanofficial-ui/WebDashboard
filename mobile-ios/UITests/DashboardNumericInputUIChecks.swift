import XCTest

/// Operates only on the verification runner's synthetic profile and owned Simulator.
enum DashboardNumericInputUIChecks {
    static func verifyRecovery(_ app: XCUIApplication, owner: XCTestCase,
                               name: String, korean: Bool = false, landscape: Bool = false) throws {
        do {
            try restartAndSelect(app, landscape: landscape)
            let minimum = app.textFields["dashboard-widget-minimum"]
            try require(reveal(minimum, in: app), "Minimum input must be fully reachable")
            let original = text(in: minimum)
            try require(Double(original)?.isFinite == true, "The saved fixture must start with a finite, nonempty minimum")
            try replace(minimum, with: "1..2", app: app, keepKeyboard: true)
            let keyboard = app.keyboards.firstMatch
            try require(keyboard.waitForExistence(timeout: 5), "Numeric keyboard must remain visible before Apply")
            let keyboardApply = app.buttons["dashboard-widget-keyboard-apply"]
            try require(keyboardApply.waitForExistence(timeout: 5) && keyboardApply.isHittable,
                        "Apply must be reachable while the keyboard is visible")
            capture(app, owner: owner, name: name + "-keyboard-visible")
            keyboardApply.tap()
            let error = app.staticTexts["dashboard-widget-numeric-error"]
            try require(error.waitForExistence(timeout: 5), "Malformed numeric input needs visible feedback")
            try require(reveal(error, in: app), "The entire correction message must be reachable")
            try require(error.label == (korean
                ? "최소에는 유한한 숫자를 입력하거나 비워 두세요."
                : "Min must be a finite number or empty."), "Feedback must identify the bad field in the selected language")
            try require(text(in: minimum) == "1..2", "Keep the malformed draft available for correction")
            capture(app, owner: owner, name: name + "-invalid-feedback")

            try restartAndSelect(app, landscape: landscape)
            let reloaded = app.textFields["dashboard-widget-minimum"]
            try require(reveal(reloaded, in: app), "Saved minimum must be reachable after restart")
            try require(text(in: reloaded) == original, "Rejected input must preserve the saved minimum across app restart")
            try replace(reloaded, with: "12.5", app: app)
            try apply(app)
            try require(UIConditionWait.until(timeout: 5) { !app.staticTexts["dashboard-widget-numeric-error"].exists },
                        "Correct input must clear only the input error")
            capture(app, owner: owner, name: name + "-corrected")

            try restartAndSelect(app, landscape: landscape)
            let persisted = app.textFields["dashboard-widget-minimum"]
            try require(reveal(persisted, in: app), "Corrected minimum must remain reachable")
            try require(text(in: persisted) == "12.5", "Correct input must persist across app restart")
            capture(app, owner: owner, name: name + "-persisted")
            if app.launchArguments.contains("UICTContentSizeCategoryAccessibilityXXXL") {
                try verifyReadableRanges(app, owner: owner, name: name, korean: korean)
            }
            // Restore only the owned synthetic profile's original minimum.
            try require(reveal(persisted, in: app), "Minimum must remain reachable after inspecting the range rows")
            try replace(persisted, with: original, app: app)
            try apply(app)
            try require(!app.staticTexts["dashboard-widget-numeric-error"].exists, "Restoration must be valid")
            try restartAndSelect(app, landscape: landscape)
            let restored = app.textFields["dashboard-widget-minimum"]
            try require(reveal(restored, in: app), "Restored minimum must remain reachable")
            try require(text(in: restored) == original, "Restore the owned fixture durably across app restart")
            capture(app, owner: owner, name: name + "-restored")
        } catch {
            capture(app, owner: owner, name: name + "-failure")
            throw error
        }
    }

    static func verifyReadableRanges(_ app: XCUIApplication, owner: XCTestCase,
                                     name: String, korean: Bool) throws {
        for (field, title) in [("minimum", korean ? "최소" : "Min"),
                               ("maximum", korean ? "최대" : "Max"),
                               ("warning", korean ? "주의" : "Warn"),
                               ("critical", korean ? "위험" : "Critical")] {
            let input = app.textFields["dashboard-widget-" + field]
            let label = app.staticTexts["dashboard-widget-" + field + "-label"]
            try require(label.exists && label.label == title,
                        "A nonempty numeric range needs a persistent localized label")
            try require(reveal(input, in: app, including: label),
                        "Each numeric input and its identifying label must be fully visible together")
            capture(app, owner: owner, name: name + "-readable-" + field)
            let viewport = configurationScroll(in: app).frame.intersection(app.windows.firstMatch.frame)
            try require(input.frame.width >= viewport.width * 0.8,
                        "Maximum-text numeric input must use a full row, not an ellipsized four-column cell")
            try require(viewport.contains(label.frame) && label.isHittable,
                        "A range label cannot be clipped or merely retained in the accessibility tree")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "DashboardNumericInputUI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func text(in field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
    }

    private static func replace(_ field: XCUIElement, with value: String, app: XCUIApplication, keepKeyboard: Bool = false) throws {
        let previous = text(in: field)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count + 1))
        if !value.isEmpty { field.typeText(value) }
        try require(text(in: field) == value, "Input fixture must type the exact requested draft")
        if !keepKeyboard {
            let done = app.buttons["dashboard-numeric-keyboard-done"]
            try require(done.waitForExistence(timeout: 5) && done.isHittable, "Numeric keyboard must offer a reachable Done action")
            done.tap()
        }
    }

    private static func apply(_ app: XCUIApplication) throws {
        let apply = app.buttons["apply-widget-configuration"]
        try require(reveal(apply, in: app), "Apply must be fully reachable")
        apply.tap()
    }

    static func restartAndSelect(_ app: XCUIApplication, landscape: Bool) throws {
        if app.state != .notRunning { app.terminate() }
        app.launch()
        let edit = app.buttons["edit-dashboard"]
        try require(edit.waitForExistence(timeout: 5) && edit.isHittable, "Existing Live toolbar must reopen the editor")
        edit.tap()
        try selectConfiguration(app, landscape: landscape)
    }

    private static func selectConfiguration(_ app: XCUIApplication, landscape: Bool) throws {
        try require(app.alerts.count == 0, "Stop on an alert; never approve or dismiss it")
        let window = app.windows.firstMatch
        if window.frame.width > window.frame.height {
            XCUIDevice.shared.orientation = .portrait
        }
        try require(UIConditionWait.until(timeout: 5) {
            let frame = window.frame; return frame.height > frame.width
        }, "Portrait selection must complete within five seconds")
        let scroll = app.scrollViews["dashboard-editor-scroll"]
        let card = app.descendants(matching: .any).matching(identifier: "editor-widget-fixture-0").firstMatch
        var selected = false
        for _ in 0..<16 {
            let windowFrame = window.frame
            if card.exists {
                let top = max(windowFrame.minY, editorNavigationBar(in: app).frame.maxY + 4)
                let content = CGRect(x: windowFrame.minX, y: top, width: windowFrame.width,
                                     height: max(0, windowFrame.maxY - top - 8))
                let visible = card.frame.intersection(scroll.frame).intersection(content)
                if visible.width >= 44 && visible.height >= 44 {
                    window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                        dx: visible.midX - windowFrame.minX, dy: visible.midY - windowFrame.minY)).tap()
                    selected = true; break
                }
            }
            scroll.swipeDown()
        }
        try require(selected, "A visible part of the real first card must be selectable")
        if landscape {
            XCUIDevice.shared.orientation = .landscapeLeft
            try require(UIConditionWait.until(timeout: 5) {
                let frame = window.frame; return frame.width > frame.height
            }, "Landscape selection must complete within five seconds")
        }
        let disclosure = app.buttons["widget-configuration-disclosure"]
        try require(disclosure.waitForExistence(timeout: 5) && disclosure.isHittable,
                    "Selected card must expose a reachable configuration action")
        // A fresh editor and selection start collapsed; do not infer expansion
        // from offscreen AX descendants retained by DisclosureGroup.
        disclosure.tap()
        try require(configurationScroll(in: app).waitForExistence(timeout: 5),
                    "Configuration must open on demand")
    }

    private static func configurationScroll(in app: XCUIApplication) -> XCUIElement {
        // iOS 27 can propagate the DisclosureGroup identifier to this scroll view.
        app.scrollViews.matching(NSPredicate(format: "identifier IN %@",
            ["dashboard-widget-configuration-scroll", "widget-configuration-disclosure"]))
            .containing(.textField, identifier: "dashboard-widget-minimum").firstMatch
    }

    private static func editorNavigationBar(in app: XCUIApplication) -> XCUIElement {
        app.navigationBars.matching(NSPredicate(format: "identifier IN %@",
            ["Edit", "편집"])).firstMatch
    }

    private static func reveal(_ element: XCUIElement, in app: XCUIApplication,
                               including label: XCUIElement? = nil) -> Bool {
        let scroll = configurationScroll(in: app)
        for _ in 0..<16 {
            let windowElement = app.windows.firstMatch
            let window = windowElement.frame
            let navigation = editorNavigationBar(in: app)
            guard navigation.exists else { return false }
            let top = max(window.minY, navigation.frame.maxY + 4)
            let content = CGRect(x: window.minX, y: top, width: window.width,
                                 height: max(0, window.maxY - top - 8))
            let viewport = scroll.frame.intersection(content).insetBy(dx: 0, dy: 1)
            guard viewport.width > 0 && viewport.height >= 44 else { return false }
            var gap = viewport.height / 3
            var upwards = true
            var dragX = viewport.minX + 6
            if element.exists {
                let frame = label.map { element.frame.union($0.frame) } ?? element.frame
                if viewport.contains(frame) && element.isHittable && (label?.isHittable ?? true) { return true }
                guard frame.height <= viewport.height else { return false }
                upwards = frame.maxY > viewport.maxY
                gap = upwards ? frame.maxY - viewport.maxY : viewport.minY - frame.minY
                dragX = max(viewport.minX + 6, min(viewport.maxX - 6, frame.minX - 6))
            }
            // Full-page swipes can oscillate past a range row in short landscape viewports.
            let distance = min(max(gap, 24), viewport.height * 0.4)
            let startY = viewport.minY + viewport.height * (upwards ? 0.75 : 0.25)
            let endY = startY + (upwards ? -distance : distance)
            let origin = windowElement.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: dragX - window.minX, dy: startY - window.minY))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(
                    CGVector(dx: dragX - window.minX, dy: endY - window.minY)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        return false
    }

    private static func capture(_ app: XCUIApplication, owner: XCTestCase, name: String) {
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        image.name = "SYNTHETIC-widget-numeric-" + name
        image.lifetime = .keepAlways; owner.add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "SYNTHETIC-widget-numeric-" + name + "-AX"
        tree.lifetime = .keepAlways; owner.add(tree)
    }
}
