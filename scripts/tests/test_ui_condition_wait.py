"""Exercise the UITest deadline using the real Swift implementation and a virtual monotonic clock."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Requires the installed Mac Swift compiler')
class UIConditionWaitTests(unittest.TestCase):
    def test_immediate_observation_keeps_query_cost_inside_the_original_deadline(self):
        source = Path(__file__).resolve().parents[2] / 'mobile-ios/UITests/UIConditionWait.swift'
        self.assertTrue(source.is_file(), 'Immediate bounded UI observation is missing')
        with tempfile.TemporaryDirectory(prefix='ui-condition-wait-') as directory:
            root = Path(directory)
            main = root / 'main.swift'
            main.write_text('''import Foundation
var clock = 0.0
var firstRead = -1.0
var reads = 0
let closed = UIConditionWait.until(timeout: 5, now: { clock }, pause: { clock += $0 }) {
    if firstRead < 0 { firstRead = clock }
    reads += 1
    clock += 3.7477698333332228 + 0.43223070833346355
    return true
}
let immediate: [String: Any] = ["closed": closed, "firstRead": firstRead, "reads": reads, "elapsed": clock]
clock = 0
let late = UIConditionWait.until(timeout: 5, now: { clock }, pause: { clock += $0 }) {
    clock += 5.01; return true
}
clock = 0
var stuckReads = 0
let stuck = UIConditionWait.until(timeout: 5, now: { clock }, pause: { clock += $0 }) {
    stuckReads += 1; clock += 0.5; return false
}
let stuckElapsed = clock
clock = 0
var delayedReads = 0
let delayed = UIConditionWait.until(timeout: 5, now: { clock }, pause: { clock += $0 }) {
    delayedReads += 1; clock += 0.3; return delayedReads == 3
}
clock = 0
let deadline = UIConditionWait.until(timeout: 5, now: { clock }, pause: { clock += $0 }) {
    clock = 5; return true
}
clock = 0
var fastReads = 0
_ = UIConditionWait.until(timeout: 5, now: { clock }, pause: { clock += $0 }) {
    fastReads += 1; return false
}
var defaultReads = 0
var defaultResult = true
let threadDone = DispatchGroup()
threadDone.enter()
Thread {
    defaultResult = UIConditionWait.until(timeout: 0.12) { defaultReads += 1; return false }
    threadDone.leave()
}.start()
threadDone.wait()
var invalidReads = 0
let invalid = UIConditionWait.until(timeout: .nan, now: { clock }, pause: { clock += $0 }) {
    invalidReads += 1; return true
}
print(String(data: try JSONSerialization.data(withJSONObject: ["immediate": immediate, "late": late,
    "stuck": stuck, "stuckReads": stuckReads, "stuckElapsed": stuckElapsed,
    "delayed": delayed, "delayedReads": delayedReads, "deadline": deadline,
    "invalid": invalid, "invalidReads": invalidReads, "fastReads": fastReads, "defaultReads": defaultReads, "defaultResult": defaultResult]), encoding: .utf8)!)
''')
            build = subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', str(root/'cache'),
                str(source), str(main), '-o', str(root/'wait')], capture_output=True, text=True, timeout=45)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(root/'wait')], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stderr)
            result = json.loads(run.stdout)
        self.assertEqual(result['immediate']['firstRead'], 0)
        self.assertEqual(result['immediate']['reads'], 1)
        self.assertTrue(result['immediate']['closed'])
        self.assertAlmostEqual(result['immediate']['elapsed'], 4.180000541666686)
        self.assertFalse(result['late'], 'A true result after five seconds must remain a failure')
        self.assertFalse(result['stuck'])
        self.assertLessEqual(result['stuckElapsed'], 5.5)
        self.assertTrue(result['delayed'])
        self.assertEqual(result['delayedReads'], 3)
        self.assertTrue(result['deadline'])
        self.assertLessEqual(result['fastReads'], 11, 'Three export iterations must fit the256-boundary trace')
        self.assertFalse(result['defaultResult'])
        self.assertLessEqual(result['defaultReads'], 2, 'The real default pause must not spin on an empty run loop')
        self.assertFalse(result['invalid'])
        self.assertEqual(result['invalidReads'], 0)


    def test_orientation_uses_one_coherent_window_frame_inside_the_deadline(self):
        root = Path(__file__).resolve().parents[2]
        source = (root/'mobile-ios/UITests/SmallViewportUIRegression.swift').read_text()
        observation = source.split('let rotated = ', 1)[1]
        if observation.startswith('XCTNSPredicateExpectation'):
            body = 'return ' + observation.split('{ _, _ in\n', 1)[1].split('\n        }, object: window)', 1)[0].strip()
        else:
            body = observation.split('UIConditionWait.until(timeout: 5) {\n', 1)[1].split('\n        }', 1)[0]
        with tempfile.TemporaryDirectory(prefix='orientation-observation-') as directory:
            temporary = Path(directory)
            main = temporary/'main.swift'
            main.write_text('''import Foundation
import CoreGraphics
var clock = 0.0
var frameReads = 0
final class ObservedWindow {
    var frame: CGRect {
        frameReads += 1
        clock += 2.74 // Cost of the first AX frame lookup in the preserved failure log.
        return CGRect(x: 0, y: 0, width: 874, height: 402)
    }
}
let window = ObservedWindow()
let rotated = UIConditionWait.until(timeout: 5, now: { clock }, pause: { clock += $0 }) {
''' + body + '''
}
print(String(data: try JSONSerialization.data(withJSONObject:
    ["rotated": rotated, "frameReads": frameReads, "elapsed": clock]), encoding: .utf8)!)
''')
            build = subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', str(temporary/'cache'),
                str(root/'mobile-ios/UITests/UIConditionWait.swift'), str(main), '-o', str(temporary/'observe')],
                capture_output=True, text=True, timeout=45)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(temporary/'observe')], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stderr)
            result = json.loads(run.stdout)
        self.assertTrue(result['rotated'], 'An already-landscape frame must fit the unchanged5-second budget')
        self.assertEqual(result['frameReads'], 1, 'Width and height must come from the same AX snapshot')
        self.assertAlmostEqual(result['elapsed'], 2.74)


    def test_foreground_audit_avoids_reactivating_an_already_foreground_app(self):
        root = Path(__file__).resolve().parents[2]
        source = (root/'mobile-ios/UITests/UIClarityUITests.swift').read_text()
        case = source.split('func testRecordedTimeAccessibilityAtLargeTextAndLandscape()', 1)[1]
        activation = case.split('over the app.\n', 1)[1].split('let foreground = ', 1)[0]
        with tempfile.TemporaryDirectory(prefix='foreground-observation-') as directory:
            temporary = Path(directory)
            main = temporary/'main.swift'
            main.write_text('''import Foundation
// This host harness executes the actual activation caller; it is not UI runtime evidence.
enum ApplicationState: Int { case runningBackground = 3, runningForeground = 4 }
final class ObservedApplication {
    var state: ApplicationState
    var activations = 0
    init(_ state: ApplicationState) { self.state = state }
    func activate() { activations += 1; state = .runningForeground }
}
func observe(_ state: ApplicationState) -> [String: Int] {
    let app = ObservedApplication(state)
''' + activation + '''
    return ["activations": app.activations, "state": app.state.rawValue]
}
let results = ["foreground": observe(.runningForeground), "background": observe(.runningBackground)]
print(String(data: try JSONSerialization.data(withJSONObject: results), encoding: .utf8)!)
''')
            build = subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', str(temporary/'cache'),
                str(main), '-o', str(temporary/'observe')], capture_output=True, text=True, timeout=45)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(temporary/'observe')], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stderr)
            result = json.loads(run.stdout.splitlines()[-1])
        self.assertEqual(result['foreground']['activations'], 0, 'An already foreground app needs no activation round trip')
        self.assertEqual(result['background']['activations'], 1, 'A background app must still be activated')
        self.assertEqual(result['foreground']['state'], 4)
        self.assertEqual(result['background']['state'], 4)


if __name__ == '__main__':
    unittest.main()
