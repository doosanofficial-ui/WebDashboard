import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as runner
import verify_replay_seed as seed


@unittest.skipUnless(os.name == 'posix', 'Owned phase uses POSIX process groups')
class OwnedProgressCompletionTests(unittest.TestCase):
    def exercise_with_blocked_native_probe(self, times_out):
        """A held optional probe must not gate phase return or owned cleanup."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            probe_release = threading.Event()
            finished = threading.Event()
            children = []
            outcome = {}
            original_popen = subprocess.Popen
            budget = 0.5 if times_out else 5
            command = [sys.executable, '-B', '-c',
                       'import time; time.sleep(30)' if times_out else
                       'print("owned completion", flush=True)']

            def launch(*args, **kwargs):
                child = original_popen(*args, **kwargs)
                children.append(child)
                return child

            def held_probe(command, **kwargs):
                if command[0] not in ('pgrep', 'ps'):
                    raise AssertionError('Unexpected native progress command')
                if not probe_release.wait(timeout=10):
                    raise AssertionError('The test did not release its native probe')
                return subprocess.CompletedProcess(command, 0, stdout='', stderr='')

            def run():
                try:
                    runner.run_owned_phase(command, root / 'phase.log', root / 'receipt.json',
                                           budget, ensure_group_cleanup=True)
                except BaseException as error:
                    outcome['error'] = error
                finally:
                    finished.set()

            with patch.object(runner, 'phase_resource_snapshot', return_value={}), \
                    patch.object(seed.subprocess, 'run', side_effect=held_probe) as native_probes, \
                    patch.object(runner.subprocess, 'Popen', side_effect=launch):
                caller = threading.Thread(target=run, daemon=True)
                caller.start()
                try:
                    returned_before_probe_release = finished.wait(timeout=3)
                finally:
                    probe_release.set()
                    caller.join(timeout=5)
                    if caller.is_alive():
                        for child in children:
                            if child.poll() is None:
                                try:
                                    os.killpg(child.pid, signal.SIGKILL)
                                except ProcessLookupError:
                                    pass
                        caller.join(timeout=2)

            self.assertFalse(caller.is_alive(), 'The test must stop its owned caller')
            self.assertEqual(len(children), 1)
            child = children[0]
            self.assertIsNotNone(child.returncode, 'The owned child must be reaped')
            with self.assertRaises(ProcessLookupError):
                os.killpg(child.pid, 0)
            receipt = json.loads((root / 'receipt.json').read_text())
            self.assertTrue(receipt['completionWaiterStopped'])
            self.assertFalse(receipt['groupExistsAfterCleanup'])
            if times_out:
                self.assertIsInstance(outcome.get('error'), subprocess.TimeoutExpired)
                self.assertEqual(outcome['error'].timeout, budget)
                self.assertTrue(receipt['timedOut'])
                self.assertTrue(receipt['groupTermSent'])
            else:
                self.assertNotIn('error', outcome)
                self.assertFalse(receipt['timedOut'])
                self.assertEqual(receipt['exitCode'], 0)
                self.assertLessEqual(receipt['processCompletionObservedElapsedSeconds'], budget)
            self.assertTrue(returned_before_probe_release,
                            'Optional native progress blocked completion and owned cleanup')
            native_probes.assert_not_called()
            for sample in receipt['progress']:
                self.assertIsNone(sample['ownedProcesses'], 'Uncollected rows must remain unknown')
                self.assertEqual(sample['processObservationStatus'], 'not-sampled')
                self.assertEqual(sample['ownedProcessGroup'], child.pid)
            self.assertEqual(receipt['progress'][-1]['logBytes'], (root / 'phase.log').stat().st_size)

    def test_optional_native_progress_does_not_delay_timely_completion(self):
        self.exercise_with_blocked_native_probe(times_out=False)

    def test_optional_native_progress_does_not_delay_timeout_cleanup(self):
        self.exercise_with_blocked_native_probe(times_out=True)


if __name__ == '__main__':
    unittest.main()
