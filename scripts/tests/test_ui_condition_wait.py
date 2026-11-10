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


if __name__ == '__main__':
    unittest.main()
