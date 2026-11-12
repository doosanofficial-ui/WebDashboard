"""Run the actual held-slider wait caller with synthetic XCTest diagnostic costs.

The clock/AX/XCTest doubles model the preserved native activity trace. This is
not a Simulator reproduction or evidence of real XCTest scheduling latency.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Requires the installed Mac Swift compiler')
class HeldSliderObservationTests(unittest.TestCase):
    def test_false_predicate_diagnostics_do_not_observe_the_element_again(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / 'mobile-ios/UITests/OfflineReplayUITests.swift').read_text()
        method = source.split('func testPlayingLongSliderDragPreservesCapturedUserTarget()', 1)[1]
        caller = '        let delayedTouch = ' + method.split('        let delayedTouch = ', 1)[1].split('        thumb.press(', 1)[0]
        fixture = r'''import Foundation
var clock = 0.0
var reads = 0
var diagnostics = 0
var scenario = "advancing"
var failures: [String] = []
var attachments: [[String: Any]] = []
struct ProcessInfo {
    static let processInfo = ProcessInfo()
    var systemUptime: Double { clock }
}
final class Position: NSObject {
    var label: String {
        reads += 1
        clock += 1.406406
        switch scenario {
        case "stalled": return "2.9 / 600.0 seconds"
        case "belowThreshold": return "5.3 / 600.0 seconds"
        case "malformed": return "unavailable"
        case "exactThreshold": return "5.4 / 600.0 seconds"
        default: return String(format: "%.1f / 600.0 seconds", 3.7 + clock * 0.5)
        }
    }
    override var debugDescription: String {
        diagnostics += 1
        clock += 8.074 // Native failed-run activity, not a new timeout allowance.
        return "synthetic element hierarchy"
    }
}
struct XCTNSPredicateExpectation { let predicate: NSPredicate; let object: Any? }
enum XCTWaiter {
    enum Result: Int { case completed = 1, timedOut = 2 }
    static func wait(for expectations: [XCTNSPredicateExpectation], timeout: Double) -> Result {
        let deadline = clock + timeout
        clock += 1.037421
        while clock < deadline {
            let satisfied = expectations.allSatisfy { $0.predicate.evaluate(with: $0.object) }
            guard clock <= deadline else { return .timedOut }
            if satisfied { return .completed }
            for expectation in expectations {
                if let element = expectation.object as? Position { _ = element.debugDescription }
            }
            clock += min(1, max(0, deadline - clock))
        }
        return .timedOut
    }
}
final class XCTAttachment {
    enum Lifetime { case keepAlways }
    let data: Data
    var name = ""
    var lifetime = Lifetime.keepAlways
    init(data: Data, uniformTypeIdentifier: String) { self.data = data }
}
func add(_ attachment: XCTAttachment) {
    attachments.append(try! JSONSerialization.jsonObject(with: attachment.data) as! [String: Any])
}
func XCTAssertEqual(_ left: XCTWaiter.Result, _ right: XCTWaiter.Result, _ message: String) {
    if left != right { failures.append(message) }
}
func trial(_ name: String) throws -> [String: Any] {
    clock = 0; reads = 0; diagnostics = 0; scenario = name; failures = []; attachments = []
    let position = Position()
    let observation = HomeStateObservation()
    let seconds = 2.9
    let duration = 600.0
''' + caller + r'''
    return ["failures": failures, "reads": reads, "diagnostics": diagnostics,
            "elapsed": clock, "envelope": attachments[0]]
}
var result: [String: Any] = [:]
for name in ["advancing", "stalled", "belowThreshold", "malformed", "exactThreshold"] {
    result[name] = try trial(name)
}
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
'''
        with tempfile.TemporaryDirectory(prefix='held-slider-observation-') as directory:
            path = Path(directory)
            (path / 'main.swift').write_text(fixture)
            build = subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', str(path/'cache'),
                                    str(root/'mobile-ios/UITests/HomeStateObservation.swift'),
                                    str(path/'main.swift'), '-o', str(path/'probe')],
                                   capture_output=True, text=True, timeout=300)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(path/'probe')], capture_output=True, text=True, timeout=300)
            self.assertEqual(run.returncode, 0, run.stderr)
            result = json.loads(run.stdout)
        advancing = result['advancing']
        self.assertEqual(advancing['failures'], [], 'Element diagnostics must not starve subsequent playback observations')
        self.assertGreater(advancing['reads'], 1)
        self.assertLessEqual(advancing['elapsed'], 10)
        self.assertEqual(result['exactThreshold']['failures'], [])
        for name, trial in result.items():
            with self.subTest(scenario=name):
                self.assertEqual(trial['diagnostics'], 0, 'The captured position is already read by the predicate')
                envelope = trial['envelope']
                self.assertEqual(envelope['requiredAdvanceSeconds'], 2.5)
                self.assertEqual(envelope['waitBudgetSeconds'], 10)
                self.assertEqual(envelope['baselineSeconds'], 2.9)
                self.assertEqual(envelope['durationSeconds'], 600)
                self.assertEqual(envelope['callObservation']['omittedStateQueries'], 0)
                self.assertEqual(len(envelope['callObservation']['stateQueries']), trial['reads'])
                if name in ('stalled', 'belowThreshold', 'malformed'):
                    self.assertTrue(trial['failures'], 'A missing advancement must remain a failure')
                    self.assertEqual(envelope['waiterResult'], 2)
                else:
                    self.assertEqual(envelope['waiterResult'], 1)


if __name__ == '__main__':
    unittest.main()
