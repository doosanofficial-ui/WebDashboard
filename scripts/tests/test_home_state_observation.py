"""Exercise the UITest-only trace using the real Swift/Foundation implementation."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Requires the installed Mac Swift compiler')
class HomeStateObservationTests(unittest.TestCase):
    def test_trace_preserves_delayed_state_reads_and_bounds_retention(self):
        # Removing timing/return-value capture or rereading state breaks this test.
        source = Path(__file__).resolve().parents[2] / 'mobile-ios/UITests/HomeStateObservation.swift'
        self.assertTrue(source.is_file(), 'UITest Home state-query observations are missing')
        with tempfile.TemporaryDirectory(prefix='home-state-observation-') as directory:
            root = Path(directory)
            main = root / 'main.swift'
            main.write_text('''import Foundation
enum State: UInt { case background = 3, suspended = 2, foreground = 4 }
var now = 10.0
var calls = 0
var pending = ""
let observation = HomeStateObservation(now: { now })
observation.mark(.homeRequested)
now = 10.5
observation.mark(.homeReturned)
observation.mark(.waitRequested)
let first = observation.readState("background") { () -> State in
    calls += 1; pending = observation.json(); now = 13.0; return .foreground
}
let second = observation.readState("suspended") { () -> State in
    calls += 1; now = 13.25; return .suspended
}
observation.mark(.waitReturned)
let initial = observation.json()
for _ in 0..<70 {
    _ = observation.readState("overflow") { () -> State in calls += 1; return .foreground }
}
let final = observation.json()
var shortCircuitCalls = [Int]()
var shortCircuitResults = [Bool]()
for sequence: [State] in [[.background], [.foreground, .suspended], [.foreground, .foreground]] {
    let trace = HomeStateObservation(now: { now })
    var count = 0
    func read(_ label: String) -> State {
        trace.readState(label) { let value = sequence[count]; count += 1; return value }
    }
    shortCircuitResults.append(read("left") == .background || read("right") == .suspended)
    shortCircuitCalls.append(count)
}
let result: [String: Any] = ["initial": initial, "final": final, "pending": pending,
    "shortCircuitCalls": shortCircuitCalls, "shortCircuitResults": shortCircuitResults,
    "first": first.rawValue, "second": second.rawValue, "calls": calls]
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
''', encoding='utf-8')
            build = subprocess.run(['swiftc', '-module-cache-path', str(root / 'cache'),
                                    str(source), str(main), '-o', str(root / 'observe')],
                                   capture_output=True, text=True, timeout=45)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(root / 'observe')], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stderr)
            result = json.loads(run.stdout)
        self.assertEqual((result['first'], result['second'], result['calls']), (4, 2, 72))
        self.assertEqual(result['shortCircuitCalls'], [1, 2, 2])
        self.assertEqual(result['shortCircuitResults'], [True, True, False])
        pending = json.loads(result['pending'])
        self.assertEqual(pending['stateQueries'], [
            {'label': 'background', 'requestedUptime': 10.5, 'returnedUptime': None, 'rawValue': None}])
        initial, final = json.loads(result['initial']), json.loads(result['final'])
        self.assertEqual(initial['schemaVersion'], 1)
        self.assertEqual(initial['boundaries'], {'homeRequested': 10, 'homeReturned': 10.5,
                                               'waitRequested': 10.5, 'waitReturned': 13.25})
        self.assertEqual(initial['stateQueries'], [
            {'label': 'background', 'requestedUptime': 10.5, 'returnedUptime': 13, 'rawValue': '4'},
            {'label': 'suspended', 'requestedUptime': 13, 'returnedUptime': 13.25, 'rawValue': '2'}])
        self.assertEqual(len(final['stateQueries']), 64)
        self.assertEqual(final['omittedStateQueries'], 8)
        self.assertTrue(all(row['rawValue'] == '4' for row in final['stateQueries']))
        self.assertEqual(final['boundaries'], initial['boundaries'])


if __name__ == '__main__':
    unittest.main()
