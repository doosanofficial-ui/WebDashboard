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


@unittest.skipUnless(os.name == 'posix', 'Owned phase uses POSIX process groups')
class OwnedDeadlineObservationTests(unittest.TestCase):
    def run_observed_phase(self, child_delay, exit_code=0, delay_wait_return=False):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        original_popen = subprocess.Popen
        children = []
        observations = []
        budget = 0.6
        began = time.monotonic()

        def launch(*args, **kwargs):
            child = original_popen(*args, **kwargs)
            children.append(child)
            if delay_wait_return:
                original_wait = child.wait
                delayed = False
                def wait(*args, **kwargs):
                    nonlocal delayed
                    result = original_wait(*args, **kwargs)
                    if not delayed:
                        delayed = True
                        time.sleep(0.8)
                    return result
                child.wait = wait
            return child

        def slow_observation(*args):
            if not observations and not delay_wait_return:
                observation_began = time.monotonic()
                while children[0].poll() is None:
                    if time.monotonic() - observation_began > 5:
                        raise OSError('The owned test child did not finish')
                    time.sleep(0.001)
                observations.append(time.monotonic() - began)
                time.sleep(max(0, observation_began + 0.9 - time.monotonic()))
            return {'ownedProcessGroup': children[0].pid,
                    'elapsedSeconds': time.monotonic() - began}

        command = [sys.executable, '-c',
                   'import sys,time; time.sleep(float(sys.argv[1])); sys.exit(int(sys.argv[2]))',
                   str(child_delay), str(exit_code)]
        try:
            with patch.object(seed, 'resource_snapshot', return_value={}), \
                    patch.object(seed, 'owned_progress', side_effect=slow_observation), \
                    patch.object(runner.subprocess, 'Popen', side_effect=launch):
                runner.run_owned_phase(command, root / 'phase.log', root / 'receipt.json', budget)
        finally:
            self.receipt = json.loads((root / 'receipt.json').read_text())
            self.observations = observations
            self.budget = budget

    def test_timely_zero_exit_survives_slow_optional_observation(self):
        self.run_observed_phase(0.03)
        self.assertLess(self.observations[0], self.budget)
        self.assertFalse(self.receipt['timedOut'])
        self.assertEqual(self.receipt['exitCode'], 0)
        self.assertLessEqual(self.receipt['processCompletionObservedElapsedSeconds'], self.budget)
        self.assertGreater(self.receipt['elapsedSeconds'], self.budget)

    def test_late_zero_exit_remains_timeout_even_after_observer_finds_exit(self):
        with self.assertRaises(subprocess.TimeoutExpired) as caught:
            self.run_observed_phase(0.75)
        self.assertEqual(caught.exception.timeout, self.budget)
        self.assertGreater(self.observations[0], self.budget)
        self.assertTrue(self.receipt['timedOut'])
        self.assertEqual(self.receipt['exitCode'], 0)

    def test_timely_nonzero_exit_preserves_error_during_slow_observation(self):
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.run_observed_phase(0.03, exit_code=7)
        self.assertEqual(caught.exception.returncode, 7)
        self.assertLess(self.observations[0], self.budget)
        self.assertFalse(self.receipt['timedOut'])
        self.assertEqual(self.receipt['exitCode'], 7)

    def test_zero_exit_observed_only_after_deadline_cannot_pass(self):
        with self.assertRaises(subprocess.TimeoutExpired) as caught:
            self.run_observed_phase(0.03, delay_wait_return=True)
        self.assertEqual(caught.exception.timeout, self.budget)
        self.assertTrue(self.receipt['timedOut'])
        self.assertEqual(self.receipt['exitCode'], 0)
        self.assertEqual(self.receipt['firstFailure']['childExitCodeBeforeStop'], 0)
        self.assertIsNone(self.receipt['firstFailure']['resources'])


if __name__ == '__main__':
    unittest.main()
