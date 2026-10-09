"""Device-free separation of completion notification and main observation delays."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as runner
import verify_replay_seed as seed


@unittest.skipUnless(os.name == 'posix', 'New owned POSIX child only')
class OwnedCompletionBoundaryTests(unittest.TestCase):
    def exercise(self, delay=None, timely=False, boundary_clock_fails=False, artificial_waits=0,
                 completion_before_progress=False):
        real_event = threading.Event
        real_thread = threading.Thread
        real_popen = subprocess.Popen
        real_write = Path.write_text
        real_clock = time.monotonic
        created_events = []
        observer_started = real_event()
        waiters = []
        fixture_errors = []
        children = []
        write_calls = progress_calls = 0
        observer_delay = .45 if timely else .15

        class CompletionEvent:
            def __init__(self):
                self.event = real_event()
                self.waits = 0
            def set(self):
                if delay == 'notification':
                    time.sleep(observer_delay)
                self.event.set()
            def wait(self, timeout=None):
                self.waits += 1
                if self.waits <= artificial_waits:
                    return False
                return self.event.wait(timeout)

        def new_event():
            if not created_events:
                event = CompletionEvent()
                created_events.append(event)
                return event
            return real_event()

        def launch_waiter(*args, **kwargs):
            target = kwargs['target']
            def ordered_completion():
                # Overlap tests require main to enter the selected observer first.
                # A real waiter may otherwise notify before main is scheduled again.
                if delay in ('progress', 'save') and not completion_before_progress:
                    if not observer_started.wait(3):
                        fixture_errors.append('Main did not enter the selected observer')
                target()
            waiter = real_thread(*args, **dict(kwargs, target=ordered_completion))
            waiters.append(waiter)
            return waiter

        def launch(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            children.append(child)
            return child

        def progress(*args):
            nonlocal progress_calls
            progress_calls += 1
            if delay == 'progress' and progress_calls == 1:
                observer_started.set()
                self.assertTrue(created_events[0].event.wait(3), 'Waiter must notify independently of main progress')
                time.sleep(observer_delay)
            return {}

        def write(path, *args, **kwargs):
            nonlocal write_calls
            if path.name == 'phase.json':
                write_calls += 1
                if write_calls == 2 and completion_before_progress:
                    waiters[0].join(timeout=3)
                    self.assertFalse(waiters[0].is_alive(), 'Completion must precede main progress')
                if delay == 'save' and write_calls == 2:
                    observer_started.set()
                    self.assertTrue(created_events[0].event.wait(3), 'Waiter must notify independently of main receipt write')
                    time.sleep(observer_delay)
            return real_write(path, *args, **kwargs)

        def clock():
            if boundary_clock_fails and sys._getframe(1).f_code.co_name == 'observe_boundary':
                raise OSError('PRIVATE_BOUNDARY_ERROR')
            return real_clock()

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            budget = .4 if timely else .1
            command = [sys.executable, '-B', '-c', 'import time;time.sleep(' + ('.02' if timely else '5') + ')']
            caught = None
            try:
                with patch.object(runner.threading, 'Event', side_effect=new_event), \
                        patch.object(runner.threading, 'Thread', side_effect=launch_waiter), \
                        patch.object(runner.subprocess, 'Popen', side_effect=launch), \
                        patch.object(seed, 'owned_progress', side_effect=progress), \
                        patch.object(Path, 'write_text', new=write), \
                        patch.object(runner.time, 'monotonic', new=clock):
                    try:
                        runner.run_owned_phase(command, root/'child.log', root/'phase.json', budget,
                                               ensure_group_cleanup=True)
                    except subprocess.TimeoutExpired as error:
                        caught = error
            finally:
                for child in children:
                    if child.returncode is None:
                        try:
                            os.killpg(child.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    child.wait(timeout=3)
            receipt = json.loads((root/'phase.json').read_text())
        self.assertEqual(fixture_errors, [])
        self.assertTrue(receipt['completionWaiterStopped'])
        self.assertFalse(receipt['groupExistsAfterCleanup'])
        if timely:
            self.assertIsNone(caught)
            self.assertFalse(receipt['timedOut'])
            self.assertEqual(receipt['exitCode'], 0)
        else:
            self.assertIsInstance(caught, subprocess.TimeoutExpired)
            self.assertEqual(caught.timeout, budget)
            self.assertTrue(receipt['timedOut'])
            self.assertEqual(receipt['firstFailure']['errorType'], 'TimeoutExpired')
            self.assertIsNone(receipt['firstFailure']['resources'])
            self.assertEqual(receipt['exitCode'], -signal.SIGTERM)
        return receipt

    def assert_observed(self, receipt):
        b = receipt['completionBoundaries']
        self.assertEqual(b['schemaVersion'], 1)
        self.assertLessEqual(b['eventSetStartedMonotonic'], b['eventSetReturnedMonotonic'])
        self.assertLessEqual(b['eventSetStartedMonotonic'], b['eventObservedByMainMonotonic'])
        return b

    def test_progress_delay_overlaps_notified_timeout_and_is_frozen_before_cleanup_progress(self):
        receipt = self.exercise('progress')
        b = self.assert_observed(receipt)
        self.assertLessEqual(b['progressAtCompletionStartedMonotonic'], b['eventSetStartedMonotonic'])
        self.assertLessEqual(b['eventSetStartedMonotonic'], b['progressAtCompletionReturnedMonotonic'])
        self.assertLessEqual(b['progressAtCompletionReturnedMonotonic'], b['eventObservedByMainMonotonic'])
        self.assertGreater(b['progressLatestStartedMonotonic'], b['progressAtCompletionReturnedMonotonic'])
        self.assertLessEqual(receipt['firstFailure']['observedMonotonic'], b['eventSetStartedMonotonic'])

    def test_save_delay_is_separate_from_progress_at_completion(self):
        receipt = self.exercise('save')
        b = self.assert_observed(receipt)
        self.assertLessEqual(b['saveAtCompletionStartedMonotonic'], b['eventSetStartedMonotonic'])
        self.assertLessEqual(b['eventSetStartedMonotonic'], b['saveAtCompletionReturnedMonotonic'])
        self.assertLessEqual(b['saveAtCompletionReturnedMonotonic'], b['progressAtCompletionStartedMonotonic'])

    def test_completion_before_main_progress_preserves_timeout_and_records_actual_order(self):
        receipt = self.exercise(completion_before_progress=True)
        b = self.assert_observed(receipt)
        self.assertLessEqual(b['eventSetReturnedMonotonic'], b['progressAtCompletionStartedMonotonic'])
        self.assertLessEqual(b['progressAtCompletionReturnedMonotonic'], b['eventObservedByMainMonotonic'])

    def test_notification_delay_is_measured_without_moving_original_timeout(self):
        receipt = self.exercise('notification')
        b = self.assert_observed(receipt)
        self.assertGreaterEqual(b['eventSetReturnedMonotonic']-b['eventSetStartedMonotonic'], .14)
        self.assertLessEqual(receipt['firstFailure']['observedMonotonic'], b['eventSetStartedMonotonic'])

    def test_timely_exit_remains_success_during_slow_main_progress(self):
        receipt = self.exercise('progress', timely=True)
        self.assert_observed(receipt)
        self.assertLessEqual(receipt['processCompletionObservedElapsedSeconds'], receipt['timeoutSeconds'])
        self.assertGreater(receipt['elapsedSeconds'], receipt['timeoutSeconds'])

    def test_optional_boundary_clock_failure_preserves_error_cleanup_and_unknown_values(self):
        receipt = self.exercise(boundary_clock_fails=True)
        b = receipt['completionBoundaries']
        self.assertIsNone(b['eventSetStartedMonotonic'])
        self.assertIsNone(b['eventSetReturnedMonotonic'])
        self.assertIsNone(b['eventObservedByMainMonotonic'])
        self.assertNotIn('PRIVATE_BOUNDARY_ERROR', json.dumps(b))

    def test_fixed_numeric_summary_does_not_grow_with_observation_count(self):
        first = self.exercise(timely=True)['completionBoundaries']
        repeated = self.exercise(timely=True, artificial_waits=40)['completionBoundaries']
        self.assertEqual(set(first), set(repeated))
        self.assertGreater(repeated['progressCalls'], first['progressCalls'])
        self.assertLessEqual(len(json.dumps(repeated).encode()), 2048)
        for key, value in repeated.items():
            if key not in ('schemaVersion','clockScope'):
                self.assertTrue(value is None or type(value) in (int,float), key)
        self.assertNotIn('command', repeated)
        self.assertNotIn('resources', repeated)


if __name__ == '__main__':
    unittest.main()
