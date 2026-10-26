"""Run the actual landscape test body with host doubles; this is not UIKit evidence."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


HOST_DOUBLES = r'''import Foundation
import CoreGraphics
let scenario = CommandLine.arguments[1]
let fixtureFrame = CGRect(x: 64, y: 96, width: 180, height: 120)
var position = "column:0,row:0"
var phase = "before"
var events = [String]()
var frameReads = 0
var gesture = [String: Any]()
var attachments = [[String: Any]]()
func finish(_ code: Int32, _ failed: String = "") -> Never {
    let result: [String: Any] = ["events": events, "frameReads": frameReads,
        "gesture": gesture, "attachments": attachments, "failedAssertion": failed]
    print("HOST_LANDSCAPE_RESULT " + String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    exit(code)
}
func XCTAssertTrue(_ value: Bool, _ message: String = "") {
    events.append("assert-true")
    if !value { finish(65, "XCTAssertTrue") }
}
func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T, _ message: String = "") {
    if left != right { finish(65, "XCTAssertEqual") }
}
func XCTAssertNotEqual<T: Equatable>(_ left: T, _ right: T, _ message: String = "") {
    if left == right { finish(65, "XCTAssertNotEqual") }
}
enum Orientation { case portrait, landscapeLeft }
final class XCUIDevice {
    static let shared = XCUIDevice()
    var orientation = Orientation.portrait
}
struct XCTNSPredicateExpectation {
    let predicate: NSPredicate
    let object: Any?
}
enum XCTWaiter {
    enum Result { case completed, timedOut }
    static func wait(for expectations: [XCTNSPredicateExpectation], timeout: Double) -> Result {
        expectations.allSatisfy { $0.predicate.evaluate(with: $0.object) } ? .completed : .timedOut
    }
}
enum Velocity: String { case slow }
struct Coordinate {
    let point: CGPoint
    func withOffset(_ delta: CGVector) -> Coordinate {
        Coordinate(point: CGPoint(x: point.x + delta.dx, y: point.y + delta.dy))
    }
    func press(forDuration duration: Double, thenDragTo end: Coordinate,
               withVelocity velocity: Velocity, thenHoldForDuration hold: Double) {
        events.append("gesture")
        gesture = ["start": ["x": point.x, "y": point.y], "end": ["x": end.point.x, "y": end.point.y],
                   "duration": duration, "hold": hold, "velocity": velocity.rawValue]
        phase = "after"
        if scenario != "unchanged-position" { position = "column:2,row:0" }
    }
}
final class Element {
    var frame: CGRect { frameReads += 1; events.append("frame"); return fixtureFrame }
    var value: Any? { events.append("value:" + phase); return position }
    var isEnabled: Bool { events.append("undo"); return scenario != "undo-disabled" }
    func waitForExistence(timeout: Double) -> Bool { true }
    func coordinate(withNormalizedOffset offset: CGVector) -> Coordinate {
        events.append("coordinate")
        return Coordinate(point: CGPoint(x: fixtureFrame.minX + offset.dx * fixtureFrame.width,
                                         y: fixtureFrame.minY + offset.dy * fixtureFrame.height))
    }
    func tap() { phase = "undone"; position = "column:0,row:0" }
}
let activeElement = Element()
struct Buttons {
    subscript(_ identifier: String) -> Element { activeElement }
}
final class XCUIApplication {
    var frame: CGRect { CGRect(x: 0, y: 0, width: 844, height: 390) }
    var buttons: Buttons { Buttons() }
}
final class XCTAttachment {
    enum Lifetime: String { case deleteOnSuccess, keepAlways }
    let data: Data
    var name = ""
    var lifetime = Lifetime.deleteOnSuccess
    init(data: Data, uniformTypeIdentifier: String) { self.data = data }
}
func add(_ attachment: XCTAttachment) {
    events.append("attachment")
    attachments.append(["name": attachment.name, "lifetime": attachment.lifetime.rawValue,
                        "json": try! JSONSerialization.jsonObject(with: attachment.data)])
}
func openEditor(_ app: XCUIApplication) {}
func widget(_ id: String, _ app: XCUIApplication) -> Element { activeElement }
func capture(_ app: XCUIApplication, _ name: String) { events.append("capture") }
'''


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "Requires the installed Mac Swift compiler")
class LandscapeLayoutObservationTests(unittest.TestCase):
    def test_real_gesture_body_logs_snapshots_before_preserved_failure_verdicts(self):
        # Removing the trace, rereading geometry, changing gesture input, or
        # accepting disabled Undo/unchanged position must break this contract.
        path = Path(__file__).resolve().parents[2] / "mobile-ios/UITests/DashboardEditingUITests.swift"
        source = path.read_text()
        marker = "    func testLandscapeMoveUsesCurrentMeasuredGeometry() {"
        start = source.index(marker) + len(marker)
        end = source.index("\n    }", start)
        body = source[start:end]
        with tempfile.TemporaryDirectory(prefix="landscape-layout-contract-") as directory:
            root = Path(directory)
            program = root / "main.swift"
            program.write_text(HOST_DOUBLES + "\nfunc exercise() {" + body + "\n}\nexercise()\nfinish(0)\n")
            build = subprocess.run(["swiftc", "-swift-version", "5", "-module-cache-path", str(root / "cache"),
                                    str(program), "-o", str(root / "exercise")], capture_output=True, text=True, timeout=45)
            self.assertEqual(build.returncode, 0, build.stderr)
            for scenario, status, failure in [("moved", 0, ""), ("undo-disabled", 65, "XCTAssertTrue"),
                                               ("unchanged-position", 65, "XCTAssertNotEqual")]:
                with self.subTest(scenario=scenario):
                    run = subprocess.run([str(root / "exercise"), scenario], capture_output=True, text=True, timeout=5)
                    self.assertEqual(run.returncode, status, run.stdout + run.stderr)
                    result = json.loads(next(line.removeprefix("HOST_LANDSCAPE_RESULT ")
                        for line in run.stdout.splitlines() if line.startswith("HOST_LANDSCAPE_RESULT ")))
                    self.assertEqual(result["failedAssertion"], failure)
                    self.assertEqual(result["frameReads"], 1, "Observation must reuse the original frame read")
                    self.assertEqual(result["gesture"], {"start": {"x": 118, "y": 120}, "end": {"x": 212, "y": 120},
                                                      "duration": 0.2, "hold": 0.2, "velocity": "slow"})
                    diagnostics = [json.loads(line.removeprefix("LANDSCAPE_LAYOUT_OBSERVATION "))
                        for line in run.stdout.splitlines() if line.startswith("LANDSCAPE_LAYOUT_OBSERVATION ")]
                    self.assertEqual(len(diagnostics), 1, "The actual test body must publish its pre-assert snapshots")
                    trace = diagnostics[0]
                    self.assertEqual(trace["frame"], {"x": 64, "y": 96, "width": 180, "height": 120})
                    self.assertEqual(trace["startNormalized"], {"dx": 0.3, "dy": 0.2})
                    self.assertEqual(trace["dragOffset"], {"dx": 94, "dy": 0})
                    self.assertEqual(trace["derivedStart"], {"x": 118, "y": 120})
                    self.assertEqual(trace["derivedEnd"], {"x": 212, "y": 120})
                    self.assertEqual(trace["valueBefore"], "column:0,row:0")
                    self.assertEqual(trace["undoEnabled"], scenario != "undo-disabled")
                    self.assertEqual(trace["valueAfter"], "column:0,row:0" if scenario == "unchanged-position" else "column:2,row:0")
                    self.assertEqual(len(result["attachments"]), 1)
                    attachment = result["attachments"][0]
                    self.assertEqual(attachment["json"], trace)
                    self.assertEqual(attachment["lifetime"], "keepAlways")
                    after = result["events"][result["events"].index("gesture") + 1:]
                    self.assertEqual(after[:4], ["undo", "value:after", "attachment", "assert-true"])


if __name__ == "__main__":
    unittest.main()
