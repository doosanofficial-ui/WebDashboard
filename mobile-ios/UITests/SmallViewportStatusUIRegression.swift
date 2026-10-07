import XCTest
import UIKit

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
        app.launchArguments += ["--app-language", "en"]; app.launch()
        XCTAssertEqual(app.buttons["toggle-recording"].value as? String, "Recording off")
        XCTAssertEqual(app.buttons["toggle-gps"].value as? String, "GPS off")
        let status = app.buttons["session-status-details"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "Recording off · GPS off")
        status.tap()
        for label in ["Recording off", "GPS off", "No mark"] {
            let information = app.staticTexts[label]
            XCTAssertTrue(information.waitForExistence(timeout: 5))
            XCTAssertTrue(information.isEnabled, "Status information must not be rendered as a disabled action")
        }
        let statusImage = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        statusImage.name = "SYNTHETIC-SE-AX5-status-details-after"
        statusImage.lifetime = .keepAlways; add(statusImage)
        let closeStatus = app.buttons["session-status-details-done"]
        XCTAssertTrue(closeStatus.waitForExistence(timeout: 5))
        closeStatus.tap()
        let editReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["edit-dashboard"].isHittable
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [editReady], timeout: 5), .completed, app.debugDescription)
        app.buttons["edit-dashboard"].tap()
        XCTAssertTrue(app.buttons["undo-dashboard-layout"].waitForExistence(timeout: 5))
        let picker = app.buttons["dashboard-page-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let bodyFont = UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        let title = "Fixture · Portrait" as NSString
        let textHeight = title.boundingRect(with: CGSize(width: picker.frame.width - 40, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: bodyFont], context: nil).height
        // UIFont's integral estimate can exceed native fractional geometry by less than a point.
        XCTAssertGreaterThanOrEqual(picker.frame.height + 1, ceil(textHeight),
            "Selected page label must have room for unscaled maximum-size body text")
        let pickerImage = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        pickerImage.name = "SYNTHETIC-SE-AX5-page-picker-label-after"
        pickerImage.lifetime = .keepAlways; add(pickerImage)
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
