"""Actual child: optional Timeout context must not gate owned termination."""
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
import failure_observation as observation
import verify_offline_replay as runner
import verify_replay_seed as seed


@unittest.skipUnless(os.name == 'posix', 'Owned POSIX child groups')
class TimeoutCleanupPriorityTests(unittest.TestCase):
    def exercise(self, operation):
        entered, terminated = threading.Event(), threading.Event()
        original_signal = os.killpg
        original_popen = subprocess.Popen
        children = []

        def launch(*args, **kwargs):
            child = original_popen(*args, **kwargs)
            children.append(child)
            return child

        def signal_owned(pid, number):
            self.assertEqual(pid, children[0].pid)
            result = original_signal(pid, number)
            if number == signal.SIGTERM:
                terminated.set()
            return result

        def blocked(*args):
            entered.set()
            terminated.wait(.7)
            return {}

        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            try:
                with patch.object(seed, 'owned_progress', return_value={}), \
                        patch.object(observation, 'simctl_device', return_value='11111111-1111-4111-8111-111111111111'), \
                        patch.object(observation, operation, side_effect=blocked), \
                        patch.object(runner.subprocess, 'Popen', side_effect=launch), \
                        patch.object(runner.os, 'killpg', side_effect=signal_owned):
                    with self.assertRaises(subprocess.TimeoutExpired) as caught:
                        runner.run_owned_phase([sys.executable, '-B', '-c', 'import time;time.sleep(5)'],
                            folder / 'child.log', folder / 'phase.json', .2, ensure_group_cleanup=True)
            finally:
                for child in children:
                    if child.returncode is None:
                        try:
                            original_signal(child.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    child.wait(timeout=3)
            receipt = json.loads((folder / 'phase.json').read_text())
            self.assertFalse(entered.is_set(), 'Optional sampler must not run before Timeout owned cleanup')
            self.assertTrue(terminated.is_set())
            self.assertEqual(caught.exception.timeout, .2)
            self.assertTrue(receipt['timedOut'])
            self.assertEqual(receipt['exitCode'], -signal.SIGTERM)
            self.assertFalse(receipt['groupExistsAfterCleanup'])
            self.assertTrue(receipt['completionWaiterStopped'])
            first = receipt['firstFailure']
            self.assertEqual(first['source'], 'completion-waiter')
            self.assertEqual(first['errorType'], 'TimeoutExpired')
            self.assertIsNone(first['kernelExitTimestamp'])
            self.assertIsNone(first['childExitCodeBeforeStop'])
            self.assertIsNone(first['resources'])
            self.assertIsNone(first['resourcesSampleMonotonic'])
            self.assertEqual(first['contextDeferredReason'], 'Owned cleanup takes priority after Timeout')
            self.assertLessEqual(first['observedMonotonic'], receipt['phaseStartedMonotonic'] + receipt['groupStopRequestedElapsedSeconds'])
            self.assertIn('skipped', first['ownedBoundary'])
            self.assertNotIn('executable', first['ownedBoundary'])

    def test_blocked_resource_context_is_deferred_until_after_owned_timeout_cleanup(self):
        self.exercise('resources')

    def test_blocked_native_sampler_is_not_entered_before_owned_timeout_cleanup(self):
        self.exercise('optional_boundary')


if __name__ == '__main__':
    unittest.main()
