import XCTest

final class SmallViewportUIRegression: XCTestCase {
    private func revealInSessions(_ element: XCUIElement, app: XCUIApplication) -> Bool {
        for _ in 0..<24 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return false
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "SYNTHETIC-SE-AX5-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "SYNTHETIC-SE-AX5-\(name)-AX"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication, editor: Bool) -> Bool {
        var observations: [String] = []
        defer {
            let diagnostic = XCTAttachment(string: observations.joined(separator: "\n"))
            diagnostic.name = "viewport-reveal-\(element.identifier)"
            diagnostic.lifetime = .keepAlways; add(diagnostic)
        }
        for attempt in 0..<24 {
            let window = app.windows.firstMatch
            var top = app.navigationBars.firstMatch.frame.maxY + 8
            let footer = app.otherElements["session-mark"]
            // A home-button SE has no bottom overlay in this editor sheet.
            // Complete exposure uses the actual viewport, not invented padding.
            var bottom = editor ? window.frame.maxY : footer.frame.minY - 8
            if editor {
                let canvasScroll = app.scrollViews.containing(.other, identifier: "dashboard-editor-canvas-fixture").firstMatch
                if canvasScroll.exists {
                    top = max(top, canvasScroll.frame.minY + 8)
                    bottom = min(bottom, canvasScroll.frame.maxY)
                }
            }
            guard bottom - top >= 44 else { return false }
            let rect: CGRect
            if !editor {
                rect = app.staticTexts.matching(identifier: "profile-widget-fixture-0").allElementsBoundByIndex
                    .reduce(CGRect.null) { $0.union($1.frame) }
                if !rect.isNull && rect.height > bottom - top { return false }
            } else { rect = element.exists ? element.frame : .zero }
            observations.append("attempt=\(attempt); exists=\(element.exists); rect=\(rect); viewport=\(top)...\(bottom); hittable=\(element.isHittable)")
            if element.exists && rect.minY >= top && rect.maxY <= bottom && element.isHittable { return true }
            let delta = element.exists ? rect.midY - (top + bottom) / 2 : (bottom - top) / 2
            let direction: CGFloat = delta < 0 ? -1 : 1
            let distance = min(max(abs(delta), 24), (bottom - top) / 2)
            let startY = top + (bottom - top) * (direction > 0 ? 0.75 : 0.25)
            let endY = min(bottom - 4, max(top + 4, startY - direction * distance))
            // Wider AX menus capture drags started near the card's right edge.
            // Use the measured canvas's left gutter, including landscape safe
            // area offsets, rather than a screen edge or an actionable Menu.
            var dragX = window.frame.maxX - 24
            if editor {
                let canvas = app.otherElements["dashboard-editor-canvas-fixture"]
                guard canvas.exists else { return false }
                dragX = max(window.frame.minX + 8, canvas.frame.minX - 8)
            }
            observations.append("drag=(\(dragX),\(startY))->(\(dragX),\(endY))")
            let origin = window.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: dragX, dy: startY)).press(forDuration: 0.1,
                thenDragTo: origin.withOffset(CGVector(dx: dragX, dy: endY)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        return false
    }

    func testSmallViewportLiveAndEditorReachability() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Disposable Simulator fixture only")
        #else
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--audit-ui-layout"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launchArguments += ["--app-language", "en"]; app.launch()
        capture(app, "live-initial")
        let first = app.staticTexts.matching(identifier: "profile-widget-fixture-0").firstMatch
        let liveVisible = reveal(first, app: app, editor: false)
        capture(app, "live-first-widget")
        XCTAssertTrue(liveVisible, "First Live card must be fully exposed by scrolling.\n" + app.debugDescription)
        XCTAssertTrue(app.buttons["toggle-recording"].isHittable)
        XCTAssertTrue(app.buttons["toggle-gps"].isHittable)
        app.tabBars.buttons["Sessions"].tap()
        let sessionPicker = app.buttons["saved-session-picker"]
        XCTAssertTrue(revealInSessions(sessionPicker, app: app), app.debugDescription)
        sessionPicker.tap()
        let fixture = app.buttons["saved-session-offline-seek-fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 5), app.debugDescription)
        fixture.tap()
        let openReplay = app.buttons["replay-saved-session"]
        XCTAssertTrue(revealInSessions(openReplay, app: app), app.debugDescription)
        openReplay.tap()
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 8))
        let play = app.buttons["session-replay-play"]
        XCTAssertTrue(revealInSessions(play, app: app), app.debugDescription)
        let speed = app.segmentedControls["replay-speed"]
        XCTAssertTrue(revealInSessions(speed, app: app), app.debugDescription)
        XCTAssertEqual(speed.label, "Replay speed", "SE AX5 rate options need an accessible label")
        XCTAssertGreaterThanOrEqual(speed.frame.height, 44, "SE AX5 rate options need a tappable height")
        capture(app, "replay-controls-portrait")
        XCTAssertTrue(revealInSessions(app.sliders["replay-time-slider"], app: app), app.debugDescription)
        capture(app, "replay-slider-portrait")
        let management = app.descendants(matching: .any).matching(identifier: "replay-session-management").firstMatch
        XCTAssertTrue(revealInSessions(management, app: app), app.debugDescription)
        management.tap()
        XCTAssertTrue(revealInSessions(app.buttons["saved-session-picker"], app: app), app.debugDescription)
        XCTAssertTrue(revealInSessions(app.buttons["sessions-export-json"], app: app), app.debugDescription)
        capture(app, "replay-export-portrait")
        app.buttons["stop-replay-header"].tap()
        app.tabBars.buttons["Live"].tap()
        app.buttons["edit-dashboard"].tap()
        XCTAssertTrue(app.buttons["undo-dashboard-layout"].waitForExistence(timeout: 5))
        capture(app, "editor-portrait-initial")
        let firstAction = app.buttons["dashboard-widget-actions-fixture-0"]
        XCTAssertTrue(reveal(firstAction, app: app, editor: true), "First card actions must be reachable")
        capture(app, "editor-portrait-first-actions")
        let last = app.buttons["dashboard-widget-actions-fixture-route"]
        XCTAssertTrue(reveal(last, app: app, editor: true), "Last canvas card actions must be fully exposed")
        capture(app, "editor-portrait-canvas-end")
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let rotated = UIConditionWait.until(timeout: 5) {
            // One AX snapshot keeps both dimensions coherent and avoids a second round trip.
            let frame = window.frame
            return frame.width > frame.height
        }
        XCTAssertTrue(rotated)
        let landscape = window.screenshot()
        XCTAssertGreaterThan(landscape.image.size.width, landscape.image.size.height)
        capture(app, "editor-landscape-initial")
        XCTAssertTrue(reveal(last, app: app, editor: true), "Landscape last canvas actions must be fully exposed")
        capture(app, "editor-landscape-canvas-end")
        try DashboardNumericInputUIChecks.verifyRecovery(app, owner: self, name: "SE-EN-AX5-portrait")
        #endif
    }
}
