import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as runner
import verify_replay_seed as seed


@unittest.skipUnless(os.name == 'posix', 'Owned phases use POSIX process groups')
class OwnedPhaseStartupTests(unittest.TestCase):
    def phase_with_slow_memory_probe(self, child_delay=0.02, exit_code=0):
        # A slow optional host-memory command must not consume the real child's budget.
        # Only the external memory dependency is faked; the owned Python child is real.
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        budget = 2.0
        original_output = subprocess.check_output

        def slow_memory(command, **kwargs):
            if command != ['sysctl', '-n', 'hw.memsize']:
                return original_output(command, **kwargs)
            time.sleep(budget + 0.4)
            return '7516192768\n'

        command = [sys.executable, '-c',
                   'import sys,time; time.sleep(float(sys.argv[1])); print("owned child ran", flush=True); sys.exit(int(sys.argv[2]))',
                   str(child_delay), str(exit_code)]
        caught = None
        with patch.object(seed.platform, 'system', return_value='Darwin'), \
                patch.object(seed.subprocess, 'check_output', side_effect=slow_memory):
            try:
                runner.run_owned_phase(command, root / 'phase.log', root / 'receipt.json', budget)
            except subprocess.SubprocessError as error:
                caught = error
        self.receipt = json.loads((root / 'receipt.json').read_text())
        self.log = (root / 'phase.log').read_text()
        return caught, budget

    def test_slow_optional_memory_probe_cannot_prevent_timely_child_success(self):
        error, budget = self.phase_with_slow_memory_probe()
        self.assertIsNone(error, 'Optional memory observation consumed the real command deadline')
        self.assertFalse(self.receipt['timedOut'])
        self.assertEqual(self.receipt['exitCode'], 0)
        self.assertIn('owned child ran', self.log)
        self.assertLessEqual(self.receipt['processCompletionObservedElapsedSeconds'], budget)
        timing = [self.receipt[k] for k in ['resourceSnapshotElapsedSeconds',
                  'launchRequestedElapsedSeconds', 'launchReturnedElapsedSeconds',
                  'childWaitStartedElapsedSeconds', 'processCompletionObservedElapsedSeconds']]
        self.assertEqual(timing, sorted(timing), 'Startup stages need chronological evidence')
        self.assertFalse(self.receipt['resources']['physicalMemorySampled'])

    def test_late_child_still_times_out_with_the_original_budget(self):
        error, budget = self.phase_with_slow_memory_probe(child_delay=2.4)
        self.assertIsInstance(error, subprocess.TimeoutExpired)
        self.assertEqual(error.timeout, budget)
        self.assertTrue(self.receipt['timedOut'])
        self.assertGreaterEqual(self.receipt['groupStopRequestedElapsedSeconds'], budget)

    def test_timely_child_error_is_not_replaced_by_optional_metadata_timeout(self):
        error, _ = self.phase_with_slow_memory_probe(exit_code=7)
        self.assertIsInstance(error, subprocess.CalledProcessError)
        self.assertEqual(error.returncode, 7)
        self.assertFalse(self.receipt['timedOut'])

    def test_timed_phase_succeeds_without_any_external_metadata_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(seed.platform, 'platform', side_effect=AssertionError('External platform probe')), \
                    patch.object(seed.subprocess, 'check_output', side_effect=AssertionError('External metadata command')):
                runner.run_owned_phase([sys.executable, '-c', 'print("owned child ran", flush=True)'],
                                       root / 'phase.log', root / 'receipt.json', 2.0)
            self.assertIn('owned child ran', (root / 'phase.log').read_text())
            receipt = json.loads((root / 'receipt.json').read_text())
            self.assertEqual(receipt['exitCode'], 0)
            self.assertFalse(receipt['resources']['physicalMemorySampled'])


if __name__ == '__main__':
    unittest.main()
