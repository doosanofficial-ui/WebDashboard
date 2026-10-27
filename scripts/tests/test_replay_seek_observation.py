"""Execute the real XCTest body/helper against a fake lazy AX viewport, not UIKit."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


HOST_DOUBLES = r'''import Foundation
import CoreGraphics
let mode = CommandLine.arguments[1]
let scenario = CommandLine.arguments[2]
var events = [String]()
var gestures = [[String: Double]]()
var offset = 0.0
var goCount = 0
var acceptedSeconds = 5.0
var inputText = scenario == "existing-input" ? "5.0" : ""
func finish(_ code: Int32, _ failure: String = "") -> Never {
    let result: [String: Any] = ["events": events, "gestures": gestures,
        "goCount": goCount, "input": inputText, "cursor": acceptedSeconds, "failure": failure]
    print("HOST_REPLAY_SEEK_RESULT " + String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    exit(code)
}
func XCTAssertTrue(_ value: Bool, _ message: String = "") {
    if !value { finish(65, "XCTAssertTrue:" + message) }
}
func XCTAssertFalse(_ value: Bool, _ message: String = "") { XCTAssertTrue(!value, message) }
func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T, _ message: String = "") {
    if left != right { finish(65, "XCTAssertEqual:" + message) }
}
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ left: T, _ right: T, _ message: String = "") { XCTAssertTrue(left >= right, message) }
func XCTAssertLessThanOrEqual<T: Comparable>(_ left: T, _ right: T, _ message: String = "") { XCTAssertTrue(left <= right, message) }
struct XCTNSPredicateExpectation { let predicate: NSPredicate; let object: Any? }
enum XCTWaiter {
    enum Result { case completed, timedOut }
    static func wait(for expectations: [XCTNSPredicateExpectation], timeout: Double) -> Result {
        events.append("wait:\(timeout)")
        return expectations.allSatisfy { $0.predicate.evaluate(with: $0.object) } ? .completed : .timedOut
    }
}
enum XCUIKeyboardKey: String { case delete = "\u{8}" }
enum Velocity { case slow }
struct Coordinate {
    let y: Double
    func press(forDuration: Double, thenDragTo end: Coordinate, withVelocity: Velocity, thenHoldForDuration: Double) {
        let delta = y - end.y
        gestures.append(["start": y, "end": end.y, "delta": delta])
        events.append("scroll:\(delta)")
        offset = min(1400, max(0, offset + delta))
    }
}
final class XCUIElement {
    let id: String
    init(_ id: String) { self.id = id }
    var exists: Bool {
        events.append("exists:" + id)
        if id == "always-missing" || id == "replay-cockpit-controls" || id == "cockpit-replay-stop" { return false }
        // The lower input card remains mounted while upper lazy analysis is absent.
        if id.hasPrefix("replay-analysis-") {
            if goCount > 0 && scenario == "permanent-analysis" { return false }
            return offset < 400
        }
        if id == "Recorded samples: 1" { return scenario != "wrong-samples" }
        if id == "Recorded fixes: 0" { return scenario != "wrong-fixes" }
        return true
    }
    var frame: CGRect {
        if id == "navigation" { return CGRect(x: 0, y: 60, width: 402, height: 56) }
        if id == "tabs" { return CGRect(x: 0, y: 802, width: 402, height: 60) }
        let y: Double
        let height: Double
        switch id {
        case "replay-seek-seconds", "replay-seek-go": y = 1117; height = 34
        case "replay-position": y = 1040; height = 30
        case "replay-analysis-time": y = 500; height = 30
        case "replay-analysis-signal": y = 260; height = 44
        case "replay-analysis-history": y = 350; height = 160
        case "replay-analysis-route": y = 700; height = 160
        case "session-replay-position": y = 190; height = 30
        default: y = 140; height = 44
        }
        return CGRect(x: 32, y: y - offset, width: 268, height: height)
    }
    var isHittable: Bool { exists && frame.minY >= 124 && frame.maxY <= 794 }
    var isEnabled: Bool {
        events.append("enabled:" + id)
        if id == "session-replay-play" { return goCount > 0 && scenario != "disabled-quick-play" }
        if id == "stop-replay-header" { return scenario != "disabled-stop" }
        return true
    }
    var value: Any? {
        if id == "replay-seek-seconds" {
            let value = inputText.isEmpty ? "Seconds" : inputText
            events.append("input-value:" + value)
            return value
        }
        let seconds = goCount > 0 && scenario == "wrong-quick-time" ? 3.0 : acceptedSeconds
        let value = String(format: "%.1f of 5.0 seconds", seconds)
        events.append("quick-value:" + value)
        return value
    }
    var label: String {
        let seconds = id == "replay-analysis-time" && scenario == "wrong-analysis" ? 3.0 : acceptedSeconds
        let text = String(format: "%.1f / 5.0 seconds", seconds)
        events.append("label:" + id + ":" + text)
        return text
    }
    func waitForExistence(timeout: Double) -> Bool { exists }
    func tap() {
        events.append("tap:" + id)
        if id == "replay-seek-go" {
            goCount += 1
            acceptedSeconds = scenario == "wrong-cursor" ? 3.0 : (Double(inputText) ?? 5.0)
        }
    }
    func typeText(_ text: String) {
        events.append("type:" + text)
        if scenario == "input-not-delivered" { return }
        for character in text {
            if character == "\u{8}" { if !inputText.isEmpty { inputText.removeLast() } }
            else { inputText.append(character) }
        }
    }
}
struct Elements {
    let kind: String
    subscript(_ id: String) -> XCUIElement { XCUIElement(id) }
    var firstMatch: XCUIElement { XCUIElement(kind) }
}
final class XCUIApplication {
    var buttons: Elements { Elements(kind: "buttons") }
    var otherElements: Elements { Elements(kind: "other") }
    var staticTexts: Elements { Elements(kind: "texts") }
    var textFields: Elements { Elements(kind: "fields") }
    var navigationBars: Elements { Elements(kind: "navigation") }
    var tabBars: Elements { Elements(kind: "tabs") }
    var frame: CGRect { CGRect(x: 0, y: 0, width: 402, height: 874) }
    var debugDescription: String { "fake-lazy-AX-viewport" }
    func coordinate(withNormalizedOffset value: CGVector) -> Coordinate { Coordinate(y: value.dy * 874) }
    func screenshot() -> Int { 0 }
}
var continueAfterFailure = true
func openFixtureSession(_ app: XCUIApplication, startedAt: Double) {}
final class XCTAttachment {
    enum Lifetime { case keepAlways }
    var name = ""
    var lifetime = Lifetime.keepAlways
    init(screenshot: Int) {}
}
func add(_ attachment: XCTAttachment) { events.append("attachment:" + attachment.name) }
'''


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "Requires the installed Mac Swift compiler")
class ReplaySeekObservationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="replay-seek-contract-")
        cls.addClassCleanup(cls.directory.cleanup)
        root = Path(cls.directory.name)
        source = (Path(__file__).resolve().parents[2] / "mobile-ios/UITests/OfflineReplayUITests.swift").read_text()
        body = declaration(source, "func testSessionReplayShowsAnalysisAndSynchronizedRecordedTime()")
        helper = declaration(source, "private func revealHistoryElement(")
        direction = declaration(source, "private enum HistoryRevealDirection") if "private enum HistoryRevealDirection" in source else ""
        main = r'''
if mode == "case" {
    try testSessionReplayShowsAnalysisAndSynchronizedRecordedTime()
    finish(0)
} else {
    let result = revealHistoryElement(XCUIElement("always-missing"), in: XCUIApplication())
    finish(result ? 65 : 0, result ? "missing element accepted" : "")
}
'''
        program = root / "main.swift"
        program.write_text(HOST_DOUBLES + "\n" + direction + "\n" + body + "\n" + helper + main)
        cls.executable = root / "exercise"
        build = subprocess.run(["swiftc", "-swift-version", "5", "-module-cache-path", str(root / "cache"),
                                str(program), "-o", str(cls.executable)], capture_output=True, text=True, timeout=45)
        if build.returncode:
            raise AssertionError(build.stderr)

    def run_case(self, scenario, mode="case"):
        run = subprocess.run([str(self.executable), mode, scenario], capture_output=True, text=True, timeout=5)
        result = json.loads(next(line.removeprefix("HOST_REPLAY_SEEK_RESULT ")
            for line in run.stdout.splitlines() if line.startswith("HOST_REPLAY_SEEK_RESULT ")))
        return run.returncode, result

    def test_exact_input_and_nearby_cursor_precede_upward_lazy_analysis_reveal(self):
        for scenario in ("accepted", "existing-input"):
            with self.subTest(scenario=scenario):
                status, result = self.run_case(scenario)
                self.assertEqual(status, 0, result)
                self.assertEqual(result["goCount"], 1)
                self.assertEqual(result["input"], "2")
                events = result["events"]
                go = events.index("tap:replay-seek-go")
                self.assertIn("input-value:2", events[:go], "Type request alone cannot prove accepted input")
                cursor = events.index("label:replay-position:2.0 / 5.0 seconds")
                analysis = events.index("label:replay-analysis-time:2.0 / 5.0 seconds")
                self.assertLess(go, cursor)
                self.assertLess(cursor, analysis)
                self.assertTrue(any(event.startswith("scroll:-") for event in events[cursor:analysis]))
                self.assertIn("exists:Recorded samples: 1", events)
                self.assertIn("quick-value:2.0 of 5.0 seconds", events)
                self.assertIn("exists:Recorded fixes: 0", events)
                self.assertEqual([event for event in events if event.startswith("wait:")], ["wait:5.0", "wait:5.0"])

    def test_wrong_input_cursor_analysis_and_original_postconditions_still_fail(self):
        for scenario in ("input-not-delivered", "wrong-cursor", "wrong-analysis", "permanent-analysis",
                         "wrong-samples", "wrong-fixes", "wrong-quick-time", "disabled-quick-play", "disabled-stop"):
            with self.subTest(scenario=scenario):
                status, result = self.run_case(scenario)
                self.assertEqual(status, 65, result)
                self.assertEqual(result["goCount"], 0 if scenario == "input-not-delivered" else 1)
                events = result["events"]
                if scenario in ("input-not-delivered", "wrong-cursor"):
                    self.assertFalse(any(event == "exists:replay-analysis-time" for event in events))
                if scenario == "permanent-analysis":
                    after_go = events[events.index("tap:replay-seek-go") + 1:]
                    self.assertEqual(sum(event.startswith("scroll:") for event in after_go), 24)
                    self.assertTrue(all(event.startswith("scroll:-") for event in after_go if event.startswith("scroll:")))

    def test_default_missing_direction_and_existing_gesture_budget_are_preserved(self):
        status, result = self.run_case("accepted", mode="missing-default")
        self.assertEqual(status, 0, result)
        self.assertEqual(len(result["gestures"]), 24)
        self.assertEqual(result["events"].count("exists:always-missing"), 25)
        for gesture in result["gestures"]:
            self.assertGreater(gesture["delta"], 0, "Existing callers must still search below when missing")
            self.assertGreaterEqual(gesture["start"], 124)
            self.assertLessEqual(gesture["start"], 794)
            self.assertGreaterEqual(gesture["end"], 124)
            self.assertLessEqual(gesture["end"], 794)
            self.assertLessEqual(gesture["delta"], (794 - 124) * 0.7)


if __name__ == "__main__":
    unittest.main()
