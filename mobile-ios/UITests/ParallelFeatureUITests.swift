import XCTest

/// Local synthetic-feature checks, separate from the existing 31-test CI partition.
/// Requires the separate 53-row SYNTHETIC archive and scoped diagnostic sidecars.
/// No acquisition, recording, adapter-connect, import, permission or export action.
final class ParallelFeatureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This suite requires the root-owned disposable synthetic Simulator.")
        #endif
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--app-language", "en",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Sessions"].waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        if let app, app.state == .runningForeground { capture("SYNTHETIC-final-state") }
    }

    func testAuditUsesOnlyAcceptedPrefixAndShowsCaptureLoss() throws {
        openReplay("SYNTHETIC-audit-prefix")
        seek("2.0", duration: "10.0")
        openAudit()
        XCTAssertEqual(stageRows("Queued").count, 1)
        XCTAssertEqual(stageRows("Started").count, 1)
        XCTAssertEqual(stageRows("Transport write started").count, 0)
        XCTAssertEqual(stageRows("Query failed").count, 0)
        XCTAssertFalse(exactText("Diagnostic audit details unavailable").exists)
        XCTAssertTrue(reveal(stageRows("Started").element(boundBy: 0)))
        capture("SYNTHETIC-A-prefix-2s-no-future-write-or-failure")

        app.navigationBars.buttons["Sessions"].tap()
        seek("6.0", duration: "10.0")
        openAudit()
        XCTAssertEqual(stageRows("Transport write returned").count, 1)
        XCTAssertEqual(stageRows("Response received").count, 0)
        XCTAssertEqual(stageRows("Query failed").count, 1)
        let failure = stageRows("Query failed").element(boundBy: 0)
        XCTAssertTrue(fragments(failure.label).contains("Reason code: timeout"), failure.label)
        XCTAssertTrue(fragments(failure.label).contains("SYNTHETIC timeout; no vehicle query"), failure.label)
        let returned = stageRows("Transport write returned").element(boundBy: 0)
        XCTAssertTrue(returned.label.contains("The transport write returned; ECU receipt is not confirmed."))
        XCTAssertTrue(reveal(failure))
        capture("SYNTHETIC-A-prefix-6s-exact-failed-outcome")

        app.navigationBars.buttons["Sessions"].tap()
        seek("8.0", duration: "10.0")
        openAudit()
        XCTAssertTrue(exactText("Diagnostic audit details unavailable").waitForExistence(timeout: 5))
        XCTAssertTrue(exactText("The selected audit rows do not contain a complete attempt history.").exists)
        XCTAssertEqual(stageRows("Query failed").count, 1, "Known attempts remain visible beside the capture-loss warning")
        XCTAssertTrue(reveal(exactText("Diagnostic audit details unavailable"), missingAbove: true))
        capture("SYNTHETIC-A-prefix-8s-capture-loss-warning")
    }

    func testTwoSignalComparisonAndEnergyUseTheSameAcceptedCursor() throws {
        openReplay("SYNTHETIC-energy-valid")
        choose("replay-analysis-signal", option: "hv_voltage")
        choose("replay-analysis-comparison-signal", option: "hv_current")
        XCTAssertTrue(identified("replay-analysis-comparison-history-hv_voltage").exists &&
                      identified("replay-analysis-comparison-history-hv_current").exists)
        assertHistory("hv_voltage", count: 11, window: "0.0–10.0 recorded seconds · V")
        assertHistory("hv_current", count: 11, window: "0.0–10.0 recorded seconds · A")
        XCTAssertTrue(exactText("Two signals · separate Y scales").exists)
        XCTAssertTrue(exactText("Recorded observations only. Gaps are not filled or interpolated.").exists)
        capture("SYNTHETIC-B-two-units-at-10s")
        openEnergy()
        selectEnergyInputs()
        assertEnergy(consumed: "0.0100", regenerated: "0.0000", net: "0.0100", duration: "10.0")
        capture("SYNTHETIC-E-qualified-10s-00100kWh")

        seek("5.0", duration: "10.0")
        let accepted = exactText("5.0 / 10.0 recorded seconds")
        XCTAssertTrue(reveal(accepted, missingAbove: true))
        assertHistory("hv_voltage", count: 6, window: "0.0–5.0 recorded seconds · V")
        assertHistory("hv_current", count: 6, window: "0.0–5.0 recorded seconds · A")
        assertEnergy(consumed: "0.0050", regenerated: "0.0000", net: "0.0050", duration: "5.0")
        capture("SYNTHETIC-BE-shared-accepted-5s")

        openReplay("SYNTHETIC-energy-legacy")
        let comparisonPicker = app.buttons["replay-analysis-comparison-signal"]
        let comparisonVisible = reveal(comparisonPicker, missingAbove: true)
        XCTAssertFalse(!comparisonVisible || !comparisonPicker.staticTexts["No comparison"].exists ||
                       identified("replay-analysis-comparison-history-hv_voltage").exists ||
                       identified("replay-analysis-comparison-history-hv_current").exists,
                       "Switching sessions must clear the optional comparison")
        openEnergy()
        let needsSelection = identified("replay-energy-unavailable")
        XCTAssertTrue(reveal(needsSelection))
        XCTAssertEqual(needsSelection.label,
                       "Select distinct voltage and current signals and an explicit current sign convention.")
        selectEnergyInputs()
        let unknown = exactText("Energy is unavailable until a qualified voltage/current interval exists.")
        XCTAssertTrue(reveal(unknown))
        XCTAssertTrue(exactText("Recorded quality is unknown · Voltage").exists)
        XCTAssertTrue(exactText("Recorded quality is unknown · Current").exists)
        XCTAssertFalse(exactText("Consumed, 0.0000 kWh").exists,
                       "Legacy missing quality must not produce a numeric zero energy")
        XCTAssertTrue(exactText("Valid duration: 0.0 s").exists)
        capture("SYNTHETIC-E-legacy-quality-remains-unknown")
    }

    func testLocalContextEvidenceAndExplicitSelectionSurviveReentryAndFiltering() throws {
        openWorkspace()
        XCTAssertTrue(identified("diagnostic-context-picker").exists)
        choose("diagnostic-context-picker", option: "SYNTHETIC-A")
        tapVisible("diagnostic-capability-open")
        XCTAssertTrue(identified("vehicle-capability-catalogue").waitForExistence(timeout: 5))
        let rpm = "capability-query-obd-mode01-rpm"
        XCTAssertTrue(identified(rpm).waitForExistence(timeout: 5))
        assertCombinedValue(in: rpm, label: "Query support evidence", expected: "Definition only · candidate")
        assertCombinedValue(in: rpm, label: "Current availability", expected: "Unknown")
        assertCombinedValue(in: rpm, label: "Signal freshness", expected: "Unknown")
        XCTAssertTrue(reveal(capabilityText(rpm, "No current observation")))
        XCTAssertTrue(reveal(capabilityText(rpm, "Synthetic fixture evidence"), missingAbove: true))
        assertCombinedValue(in: rpm, label: "Historical query evidence", expected: "Synthetic fixture · Supported", missingAbove: true)
        capture("SYNTHETIC-C-candidate-and-history-with-no-current-observation")

        app.navigationBars.buttons["Diagnostic workspace"].tap()
        choose("diagnostic-context-picker", option: "SYNTHETIC-B")
        tapVisible("diagnostic-capability-open")
        let otherRPM = "capability-query-obd-mode01-rpm"
        XCTAssertTrue(identified(otherRPM).waitForExistence(timeout: 5))
        XCTAssertFalse(capabilityText(otherRPM, "Synthetic fixture evidence").exists,
                       "Context A's synthetic history cannot leak into B")
        assertCombinedValue(in: otherRPM, label: "Current availability", expected: "Unknown")
        capture("SYNTHETIC-C-context-B-has-no-A-evidence")

        app.navigationBars.buttons["Diagnostic workspace"].tap()
        choose("diagnostic-context-picker", option: "SYNTHETIC-A")
        tapVisible("diagnostic-query-selection")
        XCTAssertTrue(identified("acquisition-apply").waitForExistence(timeout: 5))
        XCTAssertTrue(exactText("Profile defaults · all configured queries").exists)
        tapVisible("acquisition-select-none")
        let rpmToggle = app.switches["acquisition-query-obd-mode01-rpm"]
        let rpmVisible = reveal(rpmToggle, insetGesture: true)
        let currentRPM = app.switches["acquisition-query-obd-mode01-rpm"]
        let rpmControls = currentRPM.switches
        let rpmControl = rpmControls.firstMatch
        XCTAssertTrue(rpmVisible && (currentRPM.value as? String) == "0" && rpmControls.count == 1 &&
                      rpmControl.isEnabled && rpmControl.isHittable, app.debugDescription)
        rpmControl.tap()
        XCTAssertEqual(rpmToggle.value as? String, "1")
        XCTAssertEqual(app.switches["acquisition-query-santafe-mx5-hev-hv-soc"].value as? String, "0")
        XCTAssertTrue(exactText("Explicit selection").exists)
        XCTAssertTrue(identified("acquisition-apply").isEnabled)
        identified("acquisition-apply").tap()
        app.terminate(); app.launch()
        openWorkspace()
        assertSavedOneOfTwoSelection()
        capture("SYNTHETIC-D-explicit-selection-after-relaunch")
        identified("acquisition-cancel").tap()
        app.navigationBars.buttons["Signals"].tap()
        let filter = app.textFields["Filter signal, CAN ID, source"]
        XCTAssertTrue(reveal(filter, missingAbove: true)); filter.tap(); filter.typeText("SYNTHETIC-no-match\n")
        tapVisible("signals-stale-filter")
        openWorkspace()
        assertSavedOneOfTwoSelection()
        capture("SYNTHETIC-D-filter-did-not-change-saved-selection")
    }

    private func identified(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func exactText(_ value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", value)).firstMatch
    }
    private func fragments(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    private func stageRows(_ stage: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
            stage + ",", stage + "\n"))
    }
    private func tapVisible(_ id: String) {
        let element = identified(id)
        XCTAssertTrue(reveal(element), app.debugDescription)
        XCTAssertTrue(element.isHittable); element.tap()
    }
    private func choose(_ id: String, option: String) {
        tapVisible(id)
        let action = app.buttons[option]
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(action.isHittable); action.tap()
    }
    private func openReplay(_ session: String) {
        app.tabBars.buttons["Sessions"].tap()
        if app.buttons["stop-replay-header"].exists { app.buttons["stop-replay-header"].tap() }
        tapVisible("saved-session-picker")
        let row = app.buttons["saved-session-" + session]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        tapVisible("replay-saved-session")
        XCTAssertTrue(app.buttons["stop-replay-header"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["session-replay-position"].value as? String, "10.0 of 10.0 seconds")
    }
    private func seek(_ seconds: String, duration: String) {
        let input = app.textFields["replay-seek-seconds"]
        XCTAssertTrue(reveal(input, missingAbove: true)); input.tap()
        if let current = input.value as? String, Double(current) != nil {
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        input.typeText(seconds)
        XCTAssertEqual(input.value as? String, seconds)
        let go = identified("replay-seek-go")
        XCTAssertTrue(go.isHittable); XCTAssertTrue(go.isEnabled); go.tap()
        let cursor = app.staticTexts["replay-position"]
        let accepted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cursor.exists && cursor.label == seconds + " / " + duration + " seconds"
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [accepted], timeout: 5), .completed)
    }
    private func openAudit() {
        tapVisible("session-diagnostic-history")
        XCTAssertTrue(identified("diagnostic-audit-history").waitForExistence(timeout: 5))
    }
    private func openEnergy() {
        let voltage = identified("replay-energy-voltage-signal")
        if !voltage.exists { tapVisible("session-replay-energy") }
        XCTAssertTrue(voltage.waitForExistence(timeout: 5))
    }
    private func selectEnergyInputs() {
        choose("replay-energy-voltage-signal", option: "hv_voltage")
        choose("replay-energy-current-signal", option: "hv_current")
        choose("replay-energy-sign-convention", option: "Positive current means consumption")
    }
    private func assertHistory(_ signal: String, count: Int, window: String) {
        let card = identified("replay-analysis-comparison-history-" + signal)
        let sampleCount = card.staticTexts["Recorded samples: \(count)"]
        let recordedWindow = card.staticTexts[window]
        let freshness = card.staticTexts["Historical freshness unknown"]
        XCTAssertTrue(reveal(sampleCount, missingAbove: true))
        XCTAssertTrue(sampleCount.exists)
        XCTAssertTrue(reveal(recordedWindow, missingAbove: true))
        XCTAssertTrue(recordedWindow.exists)
        XCTAssertTrue(reveal(freshness, missingAbove: true))
        XCTAssertTrue(freshness.exists)
    }
    private func assertEnergy(consumed: String, regenerated: String, net: String, duration: String) {
        let consumption = exactText("Consumed, \(consumed) kWh")
        XCTAssertTrue(reveal(consumption))
        XCTAssertTrue(exactText("Regenerated, \(regenerated) kWh").exists)
        XCTAssertTrue(exactText("Net, \(net) kWh").exists)
        XCTAssertTrue(exactText("Valid duration: \(duration) s").exists)
        XCTAssertTrue(exactText("Selected recorded window: 0.0–\(duration) s").exists)
    }
    private func openWorkspace() {
        app.tabBars.buttons["Signals"].tap()
        tapVisible("signals-diagnostic-workspace")
        XCTAssertTrue(app.navigationBars["Diagnostic workspace"].waitForExistence(timeout: 5))
    }
    private func assertSavedOneOfTwoSelection() {
        tapVisible("diagnostic-query-selection")
        XCTAssertTrue(exactText("Explicit selection").waitForExistence(timeout: 5))
        let count = identified("acquisition-selected-count")
        XCTAssertTrue(reveal(count))
        XCTAssertEqual(count.label, "Selected queries, 1 / 2")
        let rpm = app.switches["acquisition-query-obd-mode01-rpm"]
        XCTAssertEqual(reveal(rpm, insetGesture: true) ? rpm.value as? String : nil, "1")
        let soc = app.switches["acquisition-query-santafe-mx5-hev-hv-soc"]
        XCTAssertEqual(reveal(soc, insetGesture: true) ? soc.value as? String : nil, "0")
    }
    private func capabilityText(_ queryID: String, _ value: String) -> XCUIElement {
        app.staticTexts.matching(identifier: queryID)
            .matching(NSPredicate(format: "label == %@", value)).firstMatch
    }
    private func assertCombinedValue(in queryID: String, label: String, expected: String, missingAbove: Bool = false) {
        let row = app.staticTexts.matching(identifier: queryID)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", label + ",", label + "\n")).firstMatch
        XCTAssertTrue(reveal(row, missingAbove: missingAbove), app.debugDescription)
        let suffix = String(row.label.dropFirst(label.count))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        XCTAssertEqual(suffix, expected, row.label)
    }
    private func capture(_ name: String) {
        XCTAssertEqual(app.state, .runningForeground)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-AX"; tree.lifetime = .keepAlways; add(tree)
    }

    // Same bounded drag budget as the existing private OfflineReplayUITests
    // helper, with a window-based viewport for modal sheets. Original tests stay untouched.
    private func reveal(_ element: XCUIElement, missingAbove: Bool = false, insetGesture: Bool = false) -> Bool {
        for attempt in 0...24 {
            let appBounds = app.frame
            guard !appBounds.isEmpty, !appBounds.isNull else { return false }
            let candidateWindow = app.windows.firstMatch
            let windowRect = candidateWindow.exists ? candidateWindow.frame : .zero
            let bounds = !windowRect.isEmpty && !windowRect.isNull && windowRect.intersects(appBounds)
                ? windowRect.intersection(appBounds) : appBounds
            var top = bounds.minY + 8
            var bottom = bounds.maxY - 8
            // A NavigationStack sheet may have no tab bar. Do not read the
            // absent bar's zero frame or admit obscured underlying chrome.
            func visibleChrome(_ chrome: XCUIElement) -> CGRect? {
                guard chrome.exists else { return nil }
                let rect = chrome.frame
                guard !rect.isEmpty, !rect.isNull, rect.intersects(bounds),
                      chrome.isHittable || chrome.buttons.allElementsBoundByIndex.contains(where: { $0.isHittable }) ||
                      chrome.keys.allElementsBoundByIndex.contains(where: { $0.isHittable }) else {
                    return nil
                }
                return rect.intersection(bounds)
            }
            for bar in app.navigationBars.allElementsBoundByIndex {
                if let rect = visibleChrome(bar), rect.minY < bounds.midY { top = max(top, rect.maxY + 8) }
            }
            let bottomChrome = app.tabBars.allElementsBoundByIndex + [
                app.otherElements["replay-cockpit-controls"], app.buttons["cockpit-replay-stop"]]
            for chrome in bottomChrome {
                if let rect = visibleChrome(chrome), rect.maxY > bounds.midY, rect.minY > top {
                    bottom = min(bottom, rect.minY - 8)
                }
            }
            for keyboard in app.keyboards.allElementsBoundByIndex {
                if let rect = visibleChrome(keyboard), rect.minY > top { bottom = min(bottom, rect.minY - 8) }
            }
            guard bottom - top > 32 else { return false }
            let exists = element.exists
            let rect = exists ? element.frame : .zero
            if exists && !rect.isEmpty && rect.intersects(bounds) && rect.minY >= top && rect.maxY <= bottom { return true }
            if attempt == 24 { return false }
            let desired = min(max((top + bottom) / 2, top + rect.height / 2 + 4), bottom - rect.height / 2 - 4)
            let delta = exists ? rect.midY - desired : (bottom - top) / 3 * (missingAbove ? -1 : 1)
            let distance = min(max(abs(delta), 12), max(24, (bottom - top) * 0.7))
            let startY = insetGesture
                ? top + (bottom - top) * (delta >= 0 ? 0.75 : 0.25)
                : (delta >= 0 ? bottom - 8 : top + 8)
            let endY = startY - (delta >= 0 ? distance : -distance)
            let x = ((insetGesture ? bounds.midX : bounds.maxX - 8) - appBounds.minX) / appBounds.width
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: (startY - appBounds.minY) / appBounds.height))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: (endY - appBounds.minY) / appBounds.height))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        return false
    }
}
