"""Exercise real worker/supervisor control flow with deterministic OS boundaries.

No native inspection or OS signals run here. Retrying a probe after losing its
child, dropping the final reap, or accepting an unknown group breaks these tests.
"""
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import failure_observation as observation
import verify_offline_replay as replay


class ProbeChild:
    pid = 41001

    def __init__(self, waits):
        self.stdout = io.BytesIO()
        self.returncode = None
        self.waits = list(waits)
        self.wait_budgets = []
        self.kills = 0

    def kill(self):
        self.kills += 1

    def wait(self, timeout=None):
        self.wait_budgets.append(timeout)
        outcome = self.waits.pop(0) if self.waits else subprocess.TimeoutExpired('owned-probe', timeout)
        if isinstance(outcome, Exception):
            raise outcome
        self.returncode = outcome
        return outcome


class ExpiringSelector:
    def __init__(self, clock):
        self.clock = clock

    def __enter__(self): return self
    def __exit__(self, *args): pass
    def register(self, *args): pass
    def get_map(self): return {1: True}
    def select(self, timeout):
        self.clock[0] += 1  # The real read loop reaches its unchanged probe deadline.
        return []


class DiagnosticWorkerCleanupTests(unittest.TestCase):
    def test_real_delayed_child_is_reaped_before_worker_returns_after_a_denied_stop(self):
        launched, waits = [], []
        native_popen = subprocess.Popen

        class OwnedChild:
            def __init__(self, child): self.child = child
            @property
            def pid(self): return self.child.pid
            @property
            def stdout(self): return self.child.stdout
            @property
            def returncode(self): return self.child.returncode
            def kill(self): raise PermissionError(1, 'controlled denied probe stop')
            def wait(self, timeout=None):
                waits.append(timeout)
                return self.child.wait(timeout=timeout)

        def launch(command, **kwargs):
            # Every launched OS child is ours, even on the expected RED path.
            source = 'import time; time.sleep(.3); raise SystemExit(7)' if not launched else 'pass'
            child = native_popen([sys.executable, '-B', '-c', source], start_new_session=True, **kwargs)
            launched.append(child)
            return OwnedChild(child)

        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            try:
                with patch.object(observation, 'resources', return_value={}), \
                        patch.object(observation, 'simctl_identity', return_value={}), \
                        patch.object(observation, 'PROBE_BUDGET_SECONDS', .05), \
                        patch.object(observation.subprocess, 'Popen', side_effect=launch), \
                        patch.object(observation.os, 'killpg', side_effect=AssertionError('No external group access')):
                    code = observation.worker(folder, None, observation.time.monotonic() + 20)
                self.assertEqual(len(launched), 1, 'Delayed owned exit must stop all subsequent probes')
                self.assertEqual(launched[0].returncode, 7, 'Real waitpid must finish before the worker returns')
                self.assertEqual(code, 1)
                self.assertEqual(waits, [2])
                journal = json.loads((folder / 'failure-diagnostic-probes.json').read_text())
                self.assertTrue(journal['probeCleanup']['childReaped'])
                self.assertEqual(journal['probes'][0]['errorType'], 'TimeoutExpired')
            finally:
                for child in launched:
                    if child.poll() is None:
                        child.kill()  # Only the actual child created by this fixture.
                    child.wait(timeout=2)

    def trial(self, waits):
        child = ProbeChild(waits)
        launched = []
        clock = [0.0]

        def launch(*args, **kwargs):
            launched.append(args[0])
            return child

        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with patch.object(observation, 'resources', return_value={}), \
                    patch.object(observation, 'simctl_identity', return_value={}), \
                    patch.object(observation.time, 'monotonic', side_effect=lambda: clock[0]), \
                    patch.object(observation.selectors, 'DefaultSelector', side_effect=lambda: ExpiringSelector(clock)), \
                    patch.object(observation.subprocess, 'Popen', side_effect=launch), \
                    patch.object(observation.os, 'killpg', side_effect=AssertionError('No group is owned by the probe')):
                code = observation.worker(folder, None, 20)
            journal = json.loads((folder / 'failure-diagnostic-probes.json').read_text())
        self.assertEqual(len(launched), 1, 'An unreaped probe must stop every subsequent launch')
        self.assertEqual(child.kills, 1, 'Final reap must never signal the child again')
        self.assertTrue(child.stdout.closed)
        self.assertEqual(code, 1, 'An incomplete diagnostic must remain unsuccessful')
        self.assertEqual(journal.get('stoppedReason'), 'unreaped-probe-child')
        self.assertEqual(journal['probes'][0]['errorType'], 'TimeoutExpired')
        self.assertTrue(journal['probes'][0]['unreapedChildObserved'])
        self.assertEqual(child.wait_budgets, [1, 2])
        cleanup = journal['probeCleanup']
        self.assertEqual(cleanup['timeoutSeconds'], 2)
        self.assertTrue(cleanup['isAdditionalToObservationBudget'])
        return child, journal, cleanup

    def test_delayed_exit_is_finally_reaped_after_following_probes_stop(self):
        child, journal, cleanup = self.trial([subprocess.TimeoutExpired('owned-probe', 1), -signal.SIGKILL])
        self.assertTrue(cleanup['childReaped'])
        self.assertTrue(journal['probes'][0]['childReaped'])
        self.assertEqual(child.returncode, -signal.SIGKILL)

    def test_persistent_child_is_retained_until_bounded_final_reap_remains_unresolved(self):
        child, journal, cleanup = self.trial([subprocess.TimeoutExpired('owned-probe', 1),
                                             subprocess.TimeoutExpired('owned-probe', 2)])
        self.assertFalse(cleanup['childReaped'])
        self.assertFalse(journal['probes'][0]['childReaped'])
        self.assertEqual(cleanup['errorType'], 'TimeoutExpired')
        self.assertIsNone(child.returncode)

    def test_reap_errors_preserve_probe_failure_and_unknown_cleanup(self):
        _, journal, cleanup = self.trial([OSError('first wait error'), PermissionError('final wait error')])
        self.assertEqual(journal['probes'][0]['cleanupErrorType'], 'OSError')
        self.assertEqual(cleanup['errorType'], 'PermissionError')
        self.assertFalse(cleanup['childReaped'])


@unittest.skipUnless(os.name == 'posix', 'Owned POSIX group contract')
class DiagnosticSupervisorCleanupTests(unittest.TestCase):
    def trial(self, group_state):
        child = ProbeChild([0, 0, 0])
        signals, probes, calls = [], [], []

        def group(pid, number):
            self.assertEqual(pid, child.pid, 'No other process group may be signalled or queried')
            if number:
                signals.append(number)
                return
            probes.append(number)
            if group_state == 'error':
                raise PermissionError(1, 'fixture group query denied')
            if group_state == 'delayed' and len(probes) >= 4:
                raise ProcessLookupError(3, 'owned group is gone')

        def phase(command, log, receipt, timeout, **kwargs):
            calls.append((command, timeout, kwargs))
            return replay.run_owned_phase(command, log, receipt, timeout, **kwargs)

        original = subprocess.TimeoutExpired(['original-build'], 600, output=b'original progress')
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}), \
                    patch.object(observation, 'DIAGNOSTIC_GROUP_CONFIRMATION_SECONDS', .05, create=True), \
                    patch('verify_replay_seed.owned_progress', return_value={}), \
                    patch.object(replay.subprocess, 'Popen', return_value=child), \
                    patch.object(replay.os, 'killpg', side_effect=group):
                observation.observe_first_failure(original, folder, None, 'app-build', run_phase=phase,
                                                  clock=lambda: 10.0)
            first = (folder / 'first-failure-observation.json').read_bytes()
            observation.observe_first_failure(OSError('later failure'), folder, None, 'cleanup')
            self.assertEqual((folder / 'first-failure-observation.json').read_bytes(), first)
            status = json.loads((folder / 'failure-diagnostic-status.json').read_text())
            receipt = json.loads((folder / 'failure-diagnostic-worker.json').read_text())
        self.assertEqual(original.timeout, 600)
        self.assertEqual(original.output, b'original progress')
        self.assertEqual(signals, [signal.SIGTERM, signal.SIGKILL], 'Only the existing single TERM/KILL sequence is allowed')
        self.assertEqual(len(calls), 1)
        command, timeout, kwargs = calls[0]
        self.assertEqual(float(command[-1]), 30.0, 'Observation deadline must remain20 seconds')
        self.assertEqual(timeout, 23, 'One1-second stop wait and one2-second final reap are separate cleanup')
        self.assertEqual(kwargs['group_cleanup_timeout'], .05)
        return status, receipt, len(probes)

    def test_delayed_group_disappearance_is_confirmed_within_explicit_budget(self):
        status, receipt, count = self.trial('delayed')
        self.assertGreaterEqual(count, 4)
        self.assertIs(receipt['groupExistsAfterCleanup'], False)
        self.assertTrue(status['ownedGroupCleanupResolved'])
        self.assertTrue(status['success'])

    def test_persistent_group_never_becomes_success_after_confirmation_budget(self):
        status, receipt, count = self.trial('persistent')
        self.assertGreater(count, 2)
        self.assertIs(receipt['groupExistsAfterCleanup'], True)
        self.assertFalse(status['ownedGroupCleanupResolved'])
        self.assertFalse(status['success'])

    def test_group_query_error_remains_unknown_and_preserves_primary_failure(self):
        status, receipt, _ = self.trial('error')
        self.assertIsNone(receipt['groupExistsAfterCleanup'])
        self.assertIsNone(status['ownedGroupCleanupResolved'])
        self.assertFalse(status['success'])
        self.assertTrue(receipt['groupCleanupErrors'])

    def test_launch_failure_never_signals_or_queries_any_group(self):
        attempts = []
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with patch('verify_replay_seed.owned_progress', return_value={}), \
                    patch.object(replay.subprocess, 'Popen', side_effect=FileNotFoundError('fixture command')), \
                    patch.object(replay.os, 'killpg', side_effect=lambda *args: attempts.append(args)):
                with self.assertRaises(FileNotFoundError):
                    replay.run_owned_phase(['fixture-not-launched'], folder / 'child.log', folder / 'child.json',
                                           1, ensure_group_cleanup=True, group_cleanup_timeout=.05)
        self.assertEqual(attempts, [], 'No successfully launched child means no owned group')


if __name__ == '__main__':
    unittest.main()
