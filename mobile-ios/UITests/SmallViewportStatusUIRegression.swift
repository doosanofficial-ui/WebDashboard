import XCTest

final class SmallViewportStatusUIRegression: XCTestCase {
    func testStatusAndEditingHelpRemainAccessibleAtMaximumText() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Disposable Simulator fixture only")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--audit-ui-layout"]
        app.launch()
        XCTAssertEqual(app.buttons["toggle-recording"].value as? String, "Recording off")
        XCTAssertEqual(app.buttons["toggle-gps"].value as? String, "GPS off")
        let status = app.buttons["session-status-details"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "Recording off · GPS off")
        status.tap()
        XCTAssertGreaterThan(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Recording off")).count, 0)
        XCTAssertGreaterThan(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "GPS off")).count, 0)
        let statusImage = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        statusImage.name = "SYNTHETIC-SE-AX5-status-details-after"
        statusImage.lifetime = .keepAlways; add(statusImage)
        // The AX5 popup covers most of the screen; tap beyond its right edge.
        app.windows.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.99, dy: 0.10)).tap()
        let editReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["edit-dashboard"].isHittable
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [editReady], timeout: 5), .completed, app.debugDescription)
        app.buttons["edit-dashboard"].tap()
        XCTAssertTrue(app.buttons["undo-dashboard-layout"].waitForExistence(timeout: 5))
        let help = app.buttons["dashboard-edit-help"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        for _ in 0..<8 where !help.isHittable { app.scrollViews["dashboard-editor-scroll"].swipeUp() }
        XCTAssertTrue(help.isHittable)
        help.tap()
        let helpImage = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        helpImage.name = "SYNTHETIC-SE-AX5-editing-help-expanded-after"
        helpImage.lifetime = .keepAlways; add(helpImage)
        let helpTree = XCTAttachment(string: app.debugDescription)
        helpTree.name = "SYNTHETIC-SE-AX5-editing-help-expanded-after-AX"
        helpTree.lifetime = .keepAlways; add(helpTree)
        // DisclosureGroup's identifier propagates to its content on this OS.
        // Verify the real explanation instead of relying on a child identifier.
        let explanation = app.staticTexts["Use card actions to move or resize. Undo restores the last edit."]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5), app.debugDescription)
        let firstCard = app.descendants(matching: .any).matching(identifier: "editor-widget-fixture-0").firstMatch
        XCTAssertGreaterThanOrEqual(firstCard.frame.minY, explanation.frame.maxY,
            "Expanded help must not be covered by the first card")
        XCTAssertFalse(app.buttons["undo-dashboard-layout"].isEnabled, "Opening help and status must not edit the stored layout")
        #endif
    }
}
