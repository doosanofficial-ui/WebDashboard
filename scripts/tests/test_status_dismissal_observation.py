"""Execute the actual status-dismissal test control flow with synthetic AX costs.

No XCTest app or Simulator is launched. The extracted caller is unchanged;
only XCTest/AX boundaries and the monotonic clock are deterministic doubles.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Requires the installed Mac Swift compiler')
class StatusDismissalObservationTests(unittest.TestCase):
    def test_readiness_uses_original_deadline_before_diagnostic_capture(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / 'mobile-ios/UITests/SmallViewportStatusUIRegression.swift').read_text()
        block = source.split('        let dismissalDeadline = ', 1)[1].split('        edit.tap()', 1)[0]
        caller = '        let dismissalDeadline = ' + block
        self.assertEqual(caller.count('let dismissalDeadline = '), 1)
        fixture = r'''import Foundation
var clock = 0.0
var failures: [String] = []
var events: [String] = []
var goneCost = 2.8
var hitCost = 0.4
var ready = true
var gone = true
struct ProcessInfo {
    static let processInfo = ProcessInfo()
    var systemUptime: Double { clock }
}
func remaining(until deadline: TimeInterval) -> TimeInterval { max(0, deadline - clock) }
func XCTAssertTrue(_ value: Bool, _ message: String = "false condition") {
    if !value { failures.append(message) }
}
func XCTAssertGreaterThan(_ value: Double, _ limit: Double, _ message: String = "late") {
    if !(value > limit) { failures.append(message) }
}
enum WaitResult { case completed, timedOut }
func XCTAssertEqual(_ value: WaitResult, _ other: WaitResult, _ message: String = "wait failed") {
    if value != other { failures.append(message) }
}
final class Element {
    func waitForNonExistence(timeout: Double) -> Bool {
        events.append("absence"); clock += goneCost / 2; return gone
    }
    var isHittable: Bool {
        events.append("hittable"); clock += hitCost; return ready
    }
}
struct Elements { subscript(_ id: String) -> Element { Element() } }
final class Application {
    let buttons = Elements()
    let scrollViews = Elements()
    let debugDescription = "synthetic AX boundary"
}
final class XCTNSPredicateExpectation {
    let predicate: NSPredicate
    let object: Any?
    init(predicate: NSPredicate, object: Any?) { self.predicate = predicate; self.object = object }
}
enum XCTWaiter {
    static func wait(for expectations: [XCTNSPredicateExpectation], timeout: Double) -> WaitResult {
        let deadline = clock + timeout
        while clock < deadline {
            if expectations.allSatisfy({ $0.predicate.evaluate(with: $0.object) }) { return .completed }
            clock += min(0.1, max(0, deadline - clock))
        }
        return .timedOut
    }
}
func captureStatusEvidence(_ app: Application, name: String) throws -> Int {
    events.append("capture"); clock += 2.042410; return 0
}
func observe(_ app: Application, closeStatus: Element) throws {
''' + caller + r'''
}
func trial(_ absence: Double, _ hit: Double, _ isReady: Bool, _ isGone: Bool) throws -> [String: Any] {
    clock = 0; failures = []; events = []; goneCost = absence; hitCost = hit; ready = isReady; gone = isGone
    try observe(Application(), closeStatus: Element())
    return ["failures": failures, "events": events, "elapsed": clock]
}
let result = ["timely": try trial(2.8, 0.4, true, true),
              "lateAbsence": try trial(5.1, 0.1, true, true),
              "lateHittability": try trial(2.8, 2.3, true, true),
              "notReady": try trial(2.8, 0.4, false, true),
              "stillPresented": try trial(0.2, 0.2, true, false)]
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
'''
        with tempfile.TemporaryDirectory(prefix='status-dismissal-observation-') as directory:
            path = Path(directory)
            (path / 'main.swift').write_text(fixture)
            build = subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', str(path/'cache'),
                                    str(path/'main.swift'), '-o', str(path/'probe')],
                                   capture_output=True, text=True, timeout=300)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(path/'probe')], capture_output=True, text=True, timeout=300)
            self.assertEqual(run.returncode, 0, run.stderr)
            result = json.loads(run.stdout.splitlines()[-1])
        timely = result['timely']
        self.assertEqual(timely['failures'], [], 'Evidence collection must not delay the first readiness query')
        self.assertLess(timely['events'].index('hittable'), timely['events'].index('capture'))
        self.assertGreater(timely['elapsed'], 5, 'Late diagnostic collection is not a new UI success deadline')
        for case in ('lateAbsence', 'lateHittability', 'notReady', 'stillPresented'):
            with self.subTest(case=case):
                self.assertTrue(result[case]['failures'], 'Late/failed UI observations must never become success')


if __name__ == '__main__':
    unittest.main()
