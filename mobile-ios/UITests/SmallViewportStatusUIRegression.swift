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
        _ = try captureStatusEvidence(app, name: "before-done")
        closeStatus.tap()
        let dismissalDeadline = ProcessInfo.processInfo.systemUptime + 5
        XCTAssertTrue(closeStatus.waitForNonExistence(timeout: remaining(until: dismissalDeadline)))
        XCTAssertTrue(app.scrollViews["session-status-details-scroll"].waitForNonExistence(
            timeout: remaining(until: dismissalDeadline)))
        _ = try captureStatusEvidence(app, name: "after-done-before-hit-query")
        XCTAssertGreaterThan(remaining(until: dismissalDeadline), 0, "Dismissal capture exceeded the original 5-second deadline")
        let edit = app.buttons["edit-dashboard"]
        // Edit may already be ready; query before scheduling the first polling callback.
        let initiallyHittable = edit.isHittable
        XCTAssertGreaterThan(remaining(until: dismissalDeadline), 0,
            "Initial hittability query returned after the original 5-second deadline")
        if !initiallyHittable {
            let editReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                edit.isHittable
            }, object: edit)
            XCTAssertEqual(XCTWaiter.wait(for: [editReady], timeout: remaining(until: dismissalDeadline)), .completed, app.debugDescription)
        }
        XCTAssertGreaterThan(remaining(until: dismissalDeadline), 0, "Hittability returned after the original 5-second deadline")
        edit.tap()
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
        let expansionDeadline = ProcessInfo.processInfo.systemUptime + 5
        let explanationLabel = "Use card actions to move or resize. Undo restores the last edit."
        XCTAssertTrue(app.staticTexts[explanationLabel].waitForExistence(
            timeout: remaining(until: expansionDeadline)))
        let evidence = try captureStableStatusEvidence(app, name: "help-expanded", until: expansionDeadline)
        let explanations = matchingNodes(in: evidence.snapshot) {
            $0.elementType == .staticText && $0.label == explanationLabel
        }
        let cards = matchingNodes(in: evidence.snapshot) { $0.identifier == "editor-widget-fixture-0" }
        XCTAssertEqual(explanations.count, 1, "Capture must contain one real explanation")
        XCTAssertEqual(cards.count, 1, "Capture must contain one editor card")
        let explanation = try XCTUnwrap(explanations.first)
        let firstCard = try XCTUnwrap(cards.first)
        for frame in [explanation.frame, firstCard.frame] {
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite })
        }
        // Both frames come from the screenshot-bracketed immutable AX snapshot.
        // A stable but overlapping capture fails immediately; it is never retried.
        XCTAssertGreaterThanOrEqual(firstCard.frame.minY, explanation.frame.maxY,
            "Expanded help must not be covered by the first card in the captured state")
        XCTAssertFalse(app.buttons["undo-dashboard-layout"].isEnabled, "Opening help and status must not edit the stored layout")
        #endif
    }

    // Public XCTest snapshots are immutable. Screenshots bracket that one snapshot;
    // this is an observation interval, not an atomic screenshot/AX API.
    @discardableResult
    private func captureStatusEvidence(_ app: XCUIApplication, name: String) throws -> (snapshot: XCUIElementSnapshot, stable: Bool) {
        let start = ProcessInfo.processInfo.systemUptime
        let before = app.windows.firstMatch.screenshot()
        let beforeEnd = ProcessInfo.processInfo.systemUptime
        let snapshot = try app.snapshot()
        let snapshotEnd = ProcessInfo.processInfo.systemUptime
        let after = app.windows.firstMatch.screenshot()
        let end = ProcessInfo.processInfo.systemUptime
        let beforePNG = before.pngRepresentation
        let afterPNG = after.pngRepresentation
        var elements: [[String: Any]] = []
        func visit(_ node: XCUIElementSnapshot) {
            if ["edit-dashboard", "session-status-details-done", "dashboard-edit-help", "editor-widget-fixture-0"].contains(node.identifier)
                || node.label == "Use card actions to move or resize. Undo restores the last edit." {
                elements.append(["identifier": node.identifier, "label": node.label,
                    "type": node.elementType.rawValue, "enabled": node.isEnabled,
                    "frame": [node.frame.minX, node.frame.minY, node.frame.width, node.frame.height]])
            }
            node.children.forEach(visit)
        }
        visit(snapshot)
        let receipt: [String: Any] = ["name": name, "systemUptimeStart": start,
            "screenshotBeforeEnd": beforeEnd, "AXSnapshotEnd": snapshotEnd,
            "screenshotAfterEnd": end, "intervalSeconds": end - start,
            "bracketingPNGBytesEqual": beforePNG == afterPNG,
            "screenshotBeforeBytes": beforePNG.count, "screenshotAfterBytes": afterPNG.count,
            "elementsFromOneImmutableSnapshot": elements]
        let json = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        for (suffix, screenshot) in [("before", before), ("after", after)] {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "SYNTHETIC-coherent-\(name)-\(suffix)"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "SYNTHETIC-coherent-\(name)-AX-interval"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertFalse(beforePNG.isEmpty || afterPNG.isEmpty, "Evidence must include two real screenshots")
        return (snapshot, beforePNG == afterPNG)
    }

    private func remaining(until deadline: TimeInterval) -> TimeInterval {
        max(0, deadline - ProcessInfo.processInfo.systemUptime)
    }

    private func matchingNodes(in snapshot: XCUIElementSnapshot,
                               where matches: (XCUIElementSnapshot) -> Bool) -> [XCUIElementSnapshot] {
        var found: [XCUIElementSnapshot] = []
        func visit(_ node: XCUIElementSnapshot) {
            if matches(node) { found.append(node) }
            node.children.forEach(visit)
        }
        visit(snapshot)
        return found
    }

    private func captureStableStatusEvidence(_ app: XCUIApplication, name: String,
                                            until deadline: TimeInterval) throws -> (snapshot: XCUIElementSnapshot, stable: Bool) {
        let entered = ProcessInfo.processInfo.systemUptime
        var attempt = 0
        var changedBrackets = 0
        var lateReturnObservations = 0
        while remaining(until: deadline) > 0 {
            attempt += 1
            let evidence = try captureStatusEvidence(app, name: "\(name)-attempt-\(attempt)")
            // snapshot() has no timeout argument. Reject late returned evidence.
            if evidence.stable && remaining(until: deadline) > 0 { return evidence }
            if !evidence.stable { changedBrackets += 1 }
            if ProcessInfo.processInfo.systemUptime >= deadline { lateReturnObservations += 1 }
        }
        // A late AX precondition can consume the budget before any image comparison.
        // PNG changes and late returns are separate facts and can both occur.
        let stage = attempt == 0 ? "deadline-before-first-bracket" : "bracket-deadline"
        let receipt: [String: Any] = ["name": name, "stage": stage,
            "captureEntrySystemUptime": entered, "sharedDeadlineSystemUptime": deadline,
            "failureObservedSystemUptime": ProcessInfo.processInfo.systemUptime,
            "bracketAttempts": attempt, "changedBrackets": changedBrackets,
            "lateReturnObservations": lateReturnObservations,
            "scope": "Observed test calls; original shared 5-second deadline and failure are unchanged"]
        if let json = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
            let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
            attachment.name = "SYNTHETIC-coherent-\(name)-deadline-failure"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTFail("Status evidence failed at \(stage), with \(attempt) bracket attempts inside the original 5-second deadline")
        throw NSError(domain: "StatusEvidence", code: 1)
    }
}
