import ast
import importlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import failure_observation
import verify_offline_replay as runner

spec = importlib.util.find_spec('bootstatus_observation')
observation = importlib.import_module('bootstatus_observation') if spec else None
DEVICE = '11111111-1111-4111-8111-111111111111'
COMMAND = ['xcrun', 'simctl', 'bootstatus', DEVICE, '-b']


class CheckpointTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(observation, 'The one-shot bootstatus checkpoint is missing')
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.event = threading.Event()
        self.child = types.SimpleNamespace(pid=12345, returncode=None)

    def checkpoint(self, began=100, deadline=280):
        return observation.BootstatusCheckpoint(self.child, DEVICE, self.root, began, deadline, self.event)

    def test_checkpoint_has_one_absolute_150_second_schedule_and_ten_second_budget(self):
        point = self.checkpoint()
        self.assertEqual(point.scheduled, 250)
        self.assertEqual(point.deadline, 260)
        with patch.object(observation.time, 'monotonic', return_value=249):
            self.assertEqual(point.wait_seconds(), 1)
            point.observe_once()
        self.assertFalse(point.attempted)
        with patch.object(observation.time, 'monotonic', return_value=250), \
                patch.object(observation, 'read_owned_state', return_value={'data': {'state': 'Booted'}}) as state:
            point.observe_once()
            point.observe_once()
        state.assert_called_once_with(DEVICE, 260, self.event)
        value = json.loads((self.root / 'bootstatus-inflight-observation.json').read_text())
        self.assertEqual(value['scheduledMonotonic'], 250)
        self.assertFalse(value['stack']['available'])
        self.assertIn('suspend', value['stack']['notRunReason'])

    def test_finished_primary_skips_all_observation_calls(self):
        self.event.set()
        with patch.object(observation.time, 'monotonic', return_value=250), \
                patch.object(observation, 'read_owned_state') as state:
            self.checkpoint().observe_once()
        state.assert_not_called()

    def test_late_checkpoint_does_not_move_the_absolute_deadline(self):
        with patch.object(observation.time, 'monotonic', return_value=260), \
                patch.object(observation, 'read_owned_state') as state:
            self.checkpoint().observe_once()
        state.assert_not_called()
        self.assertEqual(json.loads((self.root / 'bootstatus-inflight-observation.json').read_text())['notRunReason'], 'observation-deadline-reached')

    def test_image_is_explicitly_unavailable_without_touching_primary_reaper_or_native_backend(self):
        class Primary:
            pid, returncode = 12345, None
            @property
            def _waitpid_lock(self):
                self.fail_if_accessed = True
                raise AssertionError('Optional observation touched the primary reaper')
        self.child = Primary()
        with patch.object(observation.time, 'monotonic', return_value=250), \
                patch.object(observation.subprocess, 'Popen') as native, \
                patch.object(observation, 'read_owned_state', return_value={}) as state:
            point = self.checkpoint()
            point.observe_once()
        native.assert_not_called()
        state.assert_called_once_with(DEVICE, 260, self.event)
        self.assertFalse(point.evidence['image']['available'])
        self.assertIn('identity', point.evidence['image']['notRunReason'])
        self.assertFalse(hasattr(observation, 'read_owned_image'))
        self.assertFalse(hasattr(observation, 'image_worker'))

    def test_query_error_and_unwritable_journal_remain_optional(self):
        with patch.object(observation.time, 'monotonic', return_value=250), \
                patch.object(observation, 'read_owned_state', side_effect=OSError('PRIVATE_TOKEN')) as state, \
                patch.object(failure_observation, 'safe_write', return_value=False):
            point = self.checkpoint()
            point.observe_once()
            point.observe_once()
        state.assert_called_once()
        self.assertTrue(point.attempted)
        self.assertNotIn('PRIVATE_TOKEN', json.dumps(point.evidence))

    def test_factory_restricts_observation_to_exact_hosted_macos_bootstatus_180(self):
        cases = [(COMMAND, 180, 'false', 'darwin'), (COMMAND, 180, 'true', 'linux'),
                 (COMMAND, 181, 'true', 'darwin'), (COMMAND + ['extra'], 180, 'true', 'darwin'),
                 (['xcrun', 'simctl', 'boot', DEVICE], 180, 'true', 'darwin'),
                 (['xcrun', 'simctl', 'bootstatus', 'unowned', '-b'], 180, 'true', 'darwin')]
        for command, budget, ci, platform in cases:
            with self.subTest(command=command, budget=budget, ci=ci, platform=platform), \
                    patch.dict(os.environ, {'GITHUB_ACTIONS': ci}), patch.object(observation.sys, 'platform', platform), \
                    patch.object(observation.subprocess, 'Popen') as native:
                point = observation.checkpoint_for(command, self.child, self.root, 100, 100 + budget, self.event)
                self.assertIsNone(point)
                native.assert_not_called()
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}), patch.object(observation.sys, 'platform', 'darwin'):
            self.assertIsInstance(observation.checkpoint_for(COMMAND, self.child, self.root, 100, 280, self.event), observation.BootstatusCheckpoint)


@unittest.skipUnless(os.name == 'posix', 'Owned query process groups need POSIX')
class StateQueryTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(observation, 'The bounded state observation is missing')
        self.real_popen = subprocess.Popen
        self.launched = []
        self.event = threading.Event()

    def query(self, source, budget=.45):
        def launch(command, **kwargs):
            self.assertEqual(command, ['xcrun', 'simctl', 'list', 'devices', DEVICE, '--json'])
            self.assertTrue(kwargs['start_new_session'])
            self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
            self.assertEqual(kwargs['stderr'], subprocess.DEVNULL)
            process = self.real_popen([sys.executable, '-c', source], **kwargs)
            self.launched.append(process)
            return process
        began = time.monotonic()
        with patch.object(observation, 'REAP_RESERVE_SECONDS', .08), \
                patch.object(observation, 'PROBE_LIMIT_SECONDS', .2), \
                patch.object(observation.subprocess, 'Popen', side_effect=launch):
            value = observation.read_owned_state(DEVICE, began + budget, self.event)
        self.assertLess(time.monotonic() - began, .9, 'Optional query escaped its shared budget')
        for process in self.launched:
            self.assertIsNotNone(process.returncode, 'Owned query leader was not reaped')
        return value

    def test_query_publishes_only_same_uuid_state_and_boolean_availability(self):
        payload = {'devices': {'runtime': [
            {'udid': DEVICE, 'name': 'PRIVATE_NAME', 'state': 'Booted', 'isAvailable': True, 'dataPath': '/private/PRIVATE_TOKEN'},
            {'udid': '22222222-2222-4222-8222-222222222222', 'name': 'PRIVATE_FOREIGN', 'state': 'Booted'}]}}
        value = self.query('print(' + repr(json.dumps(payload)) + ', flush=True)')
        self.assertEqual(value['data'], {'simulator': DEVICE, 'found': True, 'state': 'Booted', 'isAvailable': True})
        self.assertNotIn('PRIVATE', json.dumps(value))
        self.assertTrue(value['childReaped'])

    def test_hung_query_is_killed_and_reaped_within_shared_budget(self):
        value = self.query('import time; time.sleep(20)', budget=.18)
        self.assertEqual(value['errorType'], 'TimeoutExpired')
        self.assertTrue(value['groupKillSent'])
        self.assertTrue(value['childReaped'])
        self.assertIsNone(value.get('data'))

    def test_primary_completion_cancels_query_without_waiting_for_its_full_budget(self):
        timer = threading.Timer(.04, self.event.set)
        timer.start()
        try:
            began = time.monotonic()
            value = self.query('import time; time.sleep(20)')
        finally:
            timer.join(timeout=.2)
        self.assertLess(time.monotonic() - began, .3)
        self.assertEqual(value['notRunReason'], 'primary-completed-during-query')
        self.assertTrue(value['childReaped'])

    def test_exhausted_budget_never_launches_a_query(self):
        with patch.object(observation.subprocess, 'Popen') as native:
            value = observation.read_owned_state(DEVICE, time.monotonic() - 1, self.event)
        native.assert_not_called()
        self.assertEqual(value['notRunReason'], 'observation-deadline-reached')

    def test_signal_attempt_is_not_reported_as_confirmed_group_cleanup(self):
        real_killpg = os.killpg
        def signal_or_probe(pid, sig):
            if sig == 0:
                raise PermissionError('PRIVATE_TOKEN')
            return real_killpg(pid, sig)
        with patch.object(observation.os, 'killpg', side_effect=signal_or_probe):
            value = self.query('import time; time.sleep(20)', budget=.18)
        self.assertTrue(value['groupKillSent'])
        self.assertTrue(value['childReaped'])
        self.assertFalse(value['cleanupResolved'])
        self.assertIsNone(value['groupExistsAfterCleanup'])
        self.assertNotIn('PRIVATE_TOKEN', json.dumps(value))

    def test_output_cap_and_private_parser_error_do_not_publish_raw_output(self):
        with patch.object(observation, 'MAX_STATE_OUTPUT_BYTES', 1024):
            value = self.query('import sys; sys.stdout.write("PRIVATE_TOKEN" * 1000); sys.stdout.flush()')
        self.assertEqual(value['errorType'], 'OutputLimitExceeded')
        self.assertNotIn('PRIVATE_TOKEN', json.dumps(value))
        malformed = self.query('print("PRIVATE_TOKEN malformed", flush=True)')
        self.assertEqual(malformed['errorType'], 'JSONDecodeError')
        self.assertNotIn('PRIVATE_TOKEN', json.dumps(malformed))

    def test_cleanup_kills_inherited_descendant_even_when_leader_stdout_is_open(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'leaked-heartbeat'
            child_source = 'import time; from pathlib import Path; time.sleep(.4); Path(' + repr(str(marker)) + ').write_text("leaked")'
            source = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child_source) + ']); time.sleep(20)'
            value = self.query(source, budget=.18)
            time.sleep(.5)
            self.assertFalse(marker.exists(), 'A diagnostic descendant continued executing after cleanup')
            self.assertTrue(value['groupKillSent'])
            self.assertTrue(value['childReaped'])

    def test_late_query_launch_reclaims_child_without_parsing_after_deadline(self):
        real_popen, real_killpg = subprocess.Popen, os.killpg
        children, signals, waits = [], [], []
        def launch(argv, **kwargs):
            self.assertEqual(argv, ['xcrun', 'simctl', 'list', 'devices', DEVICE, '--json'])
            time.sleep(.12)  # An uninterruptible Popen returns after the observation deadline.
            child = real_popen([sys.executable, '-B', '-c', 'import time; time.sleep(.4)'], **kwargs)
            original_wait = child.wait
            def wait(timeout=None):
                waits.append(timeout)
                if timeout is not None and timeout <= 0:
                    raise subprocess.TimeoutExpired('synthetic-delayed-reap', timeout)
                return original_wait(timeout=timeout)
            child.wait = wait
            children.append(child)
            return child
        def signal_or_probe(pid, number):
            self.assertIn(pid, [child.pid for child in children])
            if number:
                self.assertIsNone(children[0].returncode, 'A second signal followed the first reap')
                signals.append(number)
            return real_killpg(pid, number)
        try:
            with patch.object(observation.subprocess, 'Popen', side_effect=launch), \
                    patch.object(observation.os, 'killpg', side_effect=signal_or_probe), \
                    patch.object(observation, 'REAP_RESERVE_SECONDS', .08), \
                    patch.object(failure_observation, 'parse_probe') as parse:
                value = observation.read_owned_state(DEVICE, time.monotonic() + .1, self.event)
            parse.assert_not_called()
            self.assertTrue(value['childReaped'], 'Late launch lost the reserved child-reap budget')
            self.assertTrue(value['cleanupBeyondObservationDeadline'])
            self.assertEqual(value['cleanupReapBudgetSeconds'], .08)
            self.assertEqual(signals, [9])
            self.assertGreater(waits[0], 0)
        finally:
            for child in children:
                child.wait(timeout=1)



@unittest.skipUnless(os.name == 'posix', 'Owned phases need POSIX')
class PhaseIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(observation, 'The in-flight phase integration is missing')

    def trial(self, delay, code=0, budget=.3, hook_error=None, checkpoint_after=.04):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        real_popen = subprocess.Popen
        query_calls = []
        query_processes = []

        def factory(command, child, results, began, deadline, event):
            return observation.BootstatusCheckpoint(child, DEVICE, results, began, deadline, event)

        def launch(command, **kwargs):
            if command[:2] == ['xcrun', 'simctl']:
                process = real_popen([sys.executable, '-c', 'import time; time.sleep(20)'], **kwargs)
                query_processes.append(process)
                return process
            return real_popen(command, **kwargs)

        real_query = observation.read_owned_state
        def query(*args):
            query_calls.append(args[0])
            if hook_error:
                raise hook_error
            return real_query(*args)

        error = None
        with patch.object(observation, 'OBSERVE_AFTER_SECONDS', checkpoint_after), \
                patch.object(observation, 'OBSERVATION_BUDGET_SECONDS', .12), \
                patch.object(observation, 'REAP_RESERVE_SECONDS', .04), \
                patch.object(observation, 'PROBE_LIMIT_SECONDS', .05), \
                patch.object(observation, 'checkpoint_for', side_effect=factory), \
                patch.object(observation.subprocess, 'Popen', side_effect=launch), \
                patch.object(observation, 'read_owned_state', side_effect=query):
            try:
                runner.run_owned_phase([sys.executable, '-c', 'import time,sys; time.sleep(' + repr(delay) + '); sys.exit(' + repr(code) + ')'],
                                       root / 'phase.log', root / 'phase.json', budget)
            except subprocess.SubprocessError as caught:
                error = caught
        receipt = json.loads((root / 'phase.json').read_text())
        checkpoint = root / 'bootstatus-inflight-observation.json'
        self.checkpoint_evidence = json.loads(checkpoint.read_text()) if checkpoint.exists() else None
        for process in query_processes:
            self.assertIsNotNone(process.returncode, 'Diagnostic process escaped phase cleanup')
        return error, receipt, query_calls, query_processes

    def test_timely_primary_success_survives_query_cancellation(self):
        import verify_replay_seed as seed
        primary_waiting, finish_primary = threading.Event(), threading.Event()
        waiters, calls, queries, states, signals, order = [], [], [], [], [], []
        clock, notice, attempts = [0.0], [], []
        class Primary:
            pid, returncode = 12345, None
            def wait(inner, timeout=None):
                if threading.current_thread() not in waiters:
                    waiters.append(threading.current_thread())
                self.assertEqual(timeout, .3)
                order.append('primary-wait')
                primary_waiting.set()
                if not finish_primary.wait(3):
                    raise AssertionError('Invalid fixture: query did not release the primary')
                inner.returncode = 0
                order.append('primary-return')
                return 0
        class Query:
            pid, returncode, stdin = 12346, None, None
            def __init__(inner):
                inner.stdout = io.BytesIO()
            def wait(inner, timeout=None):
                self.assertEqual(signals, [9], 'The owned query must be killed before its first reap')
                self.assertGreater(timeout, 0)
                self.assertLessEqual(timeout, .04)
                inner.returncode = -9
                order.append('query-reap')
                return inner.returncode
        primary, query_child = Primary(), Query()
        class WaitingSelector:
            def __init__(inner):
                inner.selects = 0
            def __enter__(inner): return inner
            def __exit__(inner, *args): return False
            def register(inner, stream, events):
                self.assertIs(stream, query_child.stdout)
                self.assertEqual(events, observation.selectors.EVENT_READ)
            def get_map(inner): return {query_child.stdout: True}
            def select(inner, timeout=None):
                inner.selects += 1
                self.assertEqual(inner.selects, 1, 'The live query did not honor primary cancellation')
                self.assertFalse(notice[0].is_set())
                self.assertGreater(timeout, 0)
                self.assertLessEqual(timeout, .02)
                order.append('query-blocked')
                finish_primary.set()
                if not notice[0].wait(3):
                    raise AssertionError('Invalid fixture: the original waiter did not publish completion')
                return []  # No stdout/EOF: cancellation must end the real query loop.
        def factory(command, child, results, began, deadline, event):
            self.assertIs(child, primary)
            notice.append(event)
            if not primary_waiting.wait(3):
                raise AssertionError('Invalid fixture: the original waiter did not enter')
            point = observation.BootstatusCheckpoint(child, DEVICE, results, began, deadline, event)
            clock[0] = point.scheduled  # Reach the checkpoint without relying on wall-clock sleeps.
            return point
        def launch(command, **kwargs):
            self.assertTrue(kwargs['start_new_session'])
            if command == ['synthetic-primary']:
                return primary
            self.assertEqual(command, ['xcrun', 'simctl', 'list', 'devices', DEVICE, '--json'])
            self.assertFalse(notice[0].is_set(), 'The primary must still be pending when the query starts')
            self.assertIsNone(primary.returncode)
            self.assertEqual(kwargs['stdout'], subprocess.PIPE)
            self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
            self.assertEqual(kwargs['stderr'], subprocess.DEVNULL)
            queries.append(query_child)
            order.append('query-start')
            return query_child
        real_query = observation.read_owned_state
        def read_state(*args):
            calls.append(args[0])
            value = real_query(*args)
            states.append(value)
            return value
        def signal_or_probe(pid, number):
            attempts.append((pid, number))  # Record before cleanup can catch a failing assertion.
            self.assertEqual(pid, query_child.pid, 'Timely primary success must not stop the primary group')
            if number:
                self.assertIsNone(query_child.returncode, 'No signal may follow the query reap')
                signals.append(number)
                order.append('query-stop')
            else:
                self.assertEqual(query_child.returncode, -9)
                raise ProcessLookupError()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(observation, 'OBSERVE_AFTER_SECONDS', .04), \
                    patch.object(observation, 'OBSERVATION_BUDGET_SECONDS', .12), \
                    patch.object(observation, 'REAP_RESERVE_SECONDS', .04), \
                    patch.object(observation, 'PROBE_LIMIT_SECONDS', .05), \
                    patch.object(runner.time, 'monotonic', side_effect=lambda: clock[0]), \
                    patch.object(observation, 'checkpoint_for', side_effect=factory), \
                    patch.object(observation.subprocess, 'Popen', side_effect=launch), \
                    patch.object(observation.selectors, 'DefaultSelector', WaitingSelector), \
                    patch.object(observation, 'read_owned_state', side_effect=read_state), \
                    patch.object(observation.os, 'killpg', side_effect=signal_or_probe), \
                    patch.object(seed, 'owned_progress', return_value={}), \
                    patch.object(failure_observation, 'parse_probe') as parse:
                try:
                    runner.run_owned_phase(['synthetic-primary'], root / 'phase.log', root / 'phase.json', .3)
                finally:
                    finish_primary.set()
                    for waiter in waiters:
                        if waiter is not threading.current_thread():
                            waiter.join(timeout=3)
                            self.assertFalse(waiter.is_alive(), 'The fixture must stop its original waiter')
                receipt = json.loads((root / 'phase.json').read_text())
                checkpoint = json.loads((root / 'bootstatus-inflight-observation.json').read_text())
        self.assertEqual(receipt['exitCode'], 0)
        self.assertFalse(receipt['timedOut'])
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(queries), 1)
        self.assertLessEqual(receipt['processCompletionObservedElapsedSeconds'], .3)
        self.assertEqual(receipt['timeoutSeconds'], .3)
        self.assertTrue(receipt['completionWaiterStopped'])
        self.assertEqual(attempts, [(query_child.pid, 9), (query_child.pid, 0)],
                         'Only the owned query may be signaled or probed')
        self.assertNotIn('completionCleanupErrorType', receipt)
        self.assertNotIn('groupStopOwner', receipt)
        self.assertEqual(calls, [DEVICE])
        self.assertEqual(order, ['primary-wait', 'query-start', 'query-blocked', 'primary-return', 'query-stop', 'query-reap'])
        self.assertEqual(checkpoint['state'], states[0], 'Persisted observation must contain the completed cancellation evidence')
        self.assertEqual(states[0].get('notRunReason'), 'primary-completed-during-query')
        self.assertNotIn('errorType', states[0], 'A query timeout/error must not impersonate cancellation')
        self.assertTrue(states[0]['childReaped'])
        self.assertTrue(states[0]['cleanupResolved'])
        self.assertTrue(query_child.stdout.closed)
        self.assertEqual(query_child.returncode, -9)
        parse.assert_not_called()
        print('SE synchronized cancellation: ' + json.dumps({'order': order, 'primaryExitCode': receipt['exitCode'],
            'timedOut': receipt['timedOut'], 'timeoutSeconds': receipt['timeoutSeconds'],
            'queryNotRunReason': states[0].get('notRunReason'), 'queryCleanupResolved': states[0]['cleanupResolved'],
            'queryExitCode': query_child.returncode, 'signalAttempts': attempts, 'actualNativeOrOSChildLaunch': False}, sort_keys=True))

    def test_original_primary_timeout_and_budget_survive_query_timeout(self):
        error, receipt, query_calls, queries = self.trial(2, budget=.2)
        self.assertIsInstance(error, subprocess.TimeoutExpired)
        self.assertEqual(error.timeout, .2)
        self.assertEqual(receipt['timeoutSeconds'], .2)
        self.assertTrue(receipt['timedOut'])
        self.assertEqual(len(query_calls), 1)
        self.assertEqual(len(queries), 1)

    def test_original_primary_nonzero_exit_survives_observation_error(self):
        error, receipt, _, _ = self.trial(.09, code=7, hook_error=ValueError('PRIVATE_TOKEN'))
        self.assertIsInstance(error, subprocess.CalledProcessError)
        self.assertEqual(error.returncode, 7)
        self.assertFalse(receipt['timedOut'])

    def test_early_primary_completion_does_not_start_observation(self):
        # Keep the actual 150s checkpoint for this early-completion path; do not
        # mistake variable Python startup latency for an already finished child.
        error, receipt, query_calls, queries = self.trial(0, checkpoint_after=150)
        self.assertIsNone(error)
        self.assertFalse(receipt['timedOut'])
        self.assertEqual(query_calls, [])
        self.assertEqual(queries, [])

    def test_primary_notice_precedes_cleanup_and_metadata_and_cleanup_cannot_replace_verdict(self):
        import verify_replay_seed as seed
        for code, cleanup_error in [(None, False), (None, True), (7, False), (7, True)]:
            with self.subTest(code=code, cleanup_error=cleanup_error), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                factory_ready = threading.Event()
                real_event = threading.Event
                events, notices, signals, sampled_codes = [], [], [], []
                class Child:
                    pid, returncode, waited = 12345, None, False
                    def wait(inner, timeout=None):
                        if not inner.waited:
                            inner.waited = True
                            if not factory_ready.wait(1):
                                raise AssertionError('Invalid fixture: factory did not publish the notice event')
                            if code is None:
                                raise subprocess.TimeoutExpired('synthetic-original-wait', timeout)
                            inner.returncode = code
                        return inner.returncode
                child = Child()
                def event():
                    value = real_event()
                    events.append(value)
                    return value
                def factory(argv, original, results, began, deadline, notice):
                    notices.append(notice)
                    factory_ready.set()
                    return None
                def signal_or_probe(pid, number):
                    self.assertEqual(pid, child.pid)
                    if number == 15:
                        signals.append(number)
                        self.assertTrue(notices[0].is_set(), 'Cancellation was delayed until cleanup completed')
                        self.assertFalse(events[0].is_set(), 'Completion notification preceded owned cleanup')
                        if cleanup_error:
                            raise RuntimeError('PRIVATE_CLEANUP_FAILURE')
                        if child.returncode is None:
                            child.returncode = -15
                    else:
                        self.assertEqual(number, 0)
                        raise ProcessLookupError()
                def snapshot(error, cached_code, source, observed, **kwargs):
                    self.assertTrue(notices[0].is_set())
                    self.assertEqual(signals, [15], 'Optional metadata ran before primary termination')
                    sampled_codes.append(cached_code)
                    return {'childExitCodeBeforeStop': cached_code, 'errorType': type(error).__name__,
                            'source': source, 'observedMonotonic': observed}
                expected = subprocess.TimeoutExpired if code is None else subprocess.CalledProcessError
                with patch.object(runner.threading, 'Event', side_effect=event), \
                        patch.object(runner.subprocess, 'Popen', return_value=child), \
                        patch.object(runner.os, 'killpg', side_effect=signal_or_probe), \
                        patch.object(seed, 'owned_progress', return_value={}), \
                        patch.object(observation, 'checkpoint_for', side_effect=factory), \
                        patch.object(failure_observation, 'failure_snapshot', side_effect=snapshot):
                    with self.assertRaises(expected) as raised:
                        runner.run_owned_phase(['synthetic-phase'], root / 'phase.log', root / 'phase.json', .2)
                value = json.loads((root / 'phase.json').read_text())
                if code is None:
                    self.assertEqual(raised.exception.timeout, .2)
                else:
                    self.assertEqual(raised.exception.returncode, code)
                self.assertEqual(signals, [15], 'The main caller repeated a claimed stop after reaping')
                self.assertEqual(sampled_codes, [code])
                self.assertEqual(value['groupStopOwner'], 'completion-waiter')
                self.assertEqual(value['groupStopFinished'], not cleanup_error)
                self.assertEqual(value.get('completionCleanupErrorType'), 'RuntimeError' if cleanup_error else None)
                self.assertTrue(value['completionWaiterStopped'])
                self.assertNotIn('PRIVATE_CLEANUP_FAILURE', json.dumps(value))


    def test_concurrent_main_error_waits_for_claimed_cleanup_without_repeating_signals(self):
        import verify_replay_seed as seed
        factory_ready, cleanup_entered, release = [threading.Event() for _ in range(3)]
        waiters, signals = [], []
        timers = [threading.Timer(1.3, release.set)]
        original_error = OSError('synthetic required recorder failed')
        class Child:
            pid, returncode, initial_wait, running = 12345, None, True, True
            def wait(inner, timeout=None):
                if threading.current_thread() not in waiters:
                    waiters.append(threading.current_thread())
                if inner.initial_wait:
                    inner.initial_wait = False
                    if not factory_ready.wait(1):
                        raise AssertionError('Invalid fixture: original waiter did not start')
                    raise subprocess.TimeoutExpired('synthetic-original', timeout)
                cleanup_entered.set()
                if not release.is_set():
                    timers[0].start()
                if not release.wait(2):
                    raise AssertionError('Invalid fixture: cleanup was not released')
                inner.running, inner.returncode = False, -15
                return inner.returncode
        child = Child()
        def factory(*args):
            factory_ready.set()
            return None
        def progress(*args):
            if not cleanup_entered.wait(1):
                raise AssertionError('Invalid fixture: waiter did not claim cleanup')
            raise original_error
        def signal_or_probe(pid, number):
            self.assertEqual(pid, child.pid)
            if number:
                signals.append(number)
            else:
                raise ProcessLookupError()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            try:
                with patch.object(runner.subprocess, 'Popen', return_value=child), \
                        patch.object(runner.os, 'killpg', side_effect=signal_or_probe), \
                        patch.object(seed, 'owned_progress', side_effect=progress), \
                        patch.object(observation, 'checkpoint_for', side_effect=factory), \
                        patch.object(failure_observation, 'failure_snapshot', return_value={}):
                    with self.assertRaises(OSError) as caught:
                        runner.run_owned_phase(['synthetic-phase'], root / 'phase.log', root / 'phase.json', .2)
                    returned_running = child.running
                    value = json.loads((root / 'phase.json').read_text())
                    self.assertIs(caught.exception, original_error)
            finally:
                release.set()
                for timer in timers:
                    timer.cancel()
                    timer.join(timeout=2)
                for waiter in waiters:
                    waiter.join(timeout=2)
            self.assertFalse(returned_running, 'Caller returned while claimed bounded cleanup was still running')
            self.assertEqual(signals, [15], 'Concurrent fallback repeated a signal after the stop was claimed')
            self.assertEqual(value['groupStopOwner'], 'completion-waiter')
            self.assertTrue(value['groupStopFinished'])
            self.assertTrue(value['completionWaiterStopped'])



@unittest.skipUnless(os.name == 'posix', 'Synthetic process groups require POSIX')
class AstraBoundaryRegressionTests(unittest.TestCase):
    """Port the review's two reproductions without native calls or PID reuse."""
    def phase_trial(self, kind):
        real_popen = subprocess.Popen
        real_write = failure_observation.safe_write
        processes, calls = [], []
        with tempfile.TemporaryDirectory(prefix='bootstatus-term-boundary-') as directory:
            root = Path(directory)
            marker = root / 'primary-lived-after-deadline'
            source = 'import time; from pathlib import Path; time.sleep(1.05); Path(' + repr(str(marker)) + ').write_text("alive"); time.sleep(1.5)'
            def launch(argv, **kwargs):
                if '--image-worker' in argv:
                    calls.append('image-popen')
                    time.sleep(1)
                    argv = [sys.executable, '-B', '-c', 'import time; time.sleep(.08)']
                elif argv[:2] == ['xcrun', 'simctl']:
                    if kind == 'state-popen':
                        calls.append('state-popen')
                        time.sleep(1)
                    argv = [sys.executable, '-B', '-c', 'print("{}",flush=True)']
                child = real_popen(argv, **kwargs)
                processes.append(child)
                return child
            def image(*args):
                if kind == 'image-popen':
                    child = observation.subprocess.Popen(['--image-worker'], stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                    child.wait(timeout=.5)
                return {'synthetic': True}
            def factory(argv, child, results, began, deadline, event):
                return None if kind == 'control' else observation.BootstatusCheckpoint(child, DEVICE, results, began, deadline, event)
            def write(path, value):
                if Path(path).name == 'bootstatus-inflight-observation.json':
                    calls.append('receipt-write')
                    time.sleep(1)
                return real_write(path, value)
            try:
                from contextlib import ExitStack
                with ExitStack() as stack:
                    for name, value in [('OBSERVE_AFTER_SECONDS', .3), ('OBSERVATION_BUDGET_SECONDS', .1),
                                        ('REAP_RESERVE_SECONDS', .02), ('PROBE_LIMIT_SECONDS', .05)]:
                        stack.enter_context(patch.object(observation, name, value))
                    stack.enter_context(patch.object(observation, 'checkpoint_for', side_effect=factory))
                    stack.enter_context(patch.object(observation.subprocess, 'Popen', side_effect=launch))
                    stack.enter_context(patch.object(observation, 'read_owned_image', side_effect=image, create=True))
                    if kind == 'receipt-write':
                        stack.enter_context(patch.object(observation, 'read_owned_state', return_value={'synthetic': True}))
                        stack.enter_context(patch.object(failure_observation, 'safe_write', side_effect=write))
                    with self.assertRaises(subprocess.TimeoutExpired) as raised:
                        runner.run_owned_phase([sys.executable, '-B', '-c', source], root / 'phase.log', root / 'phase.json', .9)
                self.assertEqual(raised.exception.timeout, .9)
                receipt = json.loads((root / 'phase.json').read_text())
                for process in processes:
                    process.wait(timeout=3)  # Self-expiring surrogates; no second signal after reap.
                return {'kind': kind, 'termSeconds': receipt['groupStopRequestedElapsedSeconds'],
                        'primaryMarkerAfterDeadline': marker.exists(), 'diagnosticCalls': calls,
                        'originalTimeoutSeconds': receipt['timeoutSeconds'],
                        'cleanupOwner': receipt.get('groupStopOwner'),
                        'cleanupFinished': receipt.get('groupStopFinished', False),
                        'preStopCode': receipt.get('firstFailure', {}).get('childExitCodeBeforeStop'),
                        'allSyntheticChildrenReaped': all(x.returncode is not None for x in processes)}
            finally:
                for process in processes:
                    if process.returncode is None:
                        process.wait(timeout=3)

    def test_diagnostic_launch_and_receipt_delays_do_not_delay_original_term(self):
        control = self.phase_trial('control')
        results = [control]
        for kind in ['image-popen', 'state-popen', 'receipt-write']:
            with self.subTest(kind=kind):
                trial = self.phase_trial(kind)
                results.append(trial)
                self.assertFalse(trial['primaryMarkerAfterDeadline'], 'Diagnostic delay kept the original primary alive beyond deadline')
                self.assertLessEqual(trial['termSeconds'], control['termSeconds'] + .12)
                self.assertTrue(trial['allSyntheticChildrenReaped'])
                self.assertEqual(trial['cleanupOwner'], 'completion-waiter')
                self.assertTrue(trial['cleanupFinished'])
                self.assertIsNone(trial['preStopCode'])
        print('Astra termination regression: ' + json.dumps(results, sort_keys=True))

    def test_post_expiry_preemption_and_denied_kill_cannot_query_reaped_pid(self):
        real_popen, real_killpg = subprocess.Popen, os.killpg
        with tempfile.TemporaryDirectory(prefix='bootstatus-pid-boundary-') as directory:
            root = Path(directory)
            ready, release, marker, primary_release = [root / x for x in ('passed-check', 'resume', 'late-lookup', 'exit-primary')]
            primary_source = 'import time; from pathlib import Path; until=time.monotonic()+3\nwhile not Path(' + repr(str(primary_release)) + ').exists() and time.monotonic()<until: time.sleep(.005)'
            primary = real_popen([sys.executable, '-B', '-c', primary_source], stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            workers = []
            try:
                if hasattr(observation, 'read_owned_image'):
                    source = '\n'.join([
                        'import os,sys,time,types,json', 'from pathlib import Path',
                        'sys.path.insert(0,' + repr(str(Path(observation.__file__).parent)) + ')',
                        'import bootstatus_observation as observation',
                        'def image(pid, buffer, length):',
                        '    Path(' + repr(str(marker)) + ').write_text("lookup after original reap")',
                        '    return len(buffer.value)',
                        'class Buffer:', '    value=b"/usr/bin/xcrun"',
                        '    def __len__(self):',
                        '        Path(' + repr(str(ready)) + ').write_text("passed expiry")',
                        '        until=time.monotonic()+3',
                        '        while not Path(' + repr(str(release)) + ').exists() and time.monotonic()<until: time.sleep(.005)',
                        '        return 4096',
                        'sys.modules["ctypes"]=types.SimpleNamespace(CDLL=lambda *a,**k:types.SimpleNamespace(proc_pidpath=image),c_int=int,c_void_p=int,c_uint32=int,create_string_buffer=lambda n:Buffer())',
                        'os.environ["GITHUB_ACTIONS"]="true"', 'sys.platform="darwin"',
                        'try: observation.image_worker()', 'except BrokenPipeError: pass'])
                    def launch(argv, **kwargs):
                        self.assertIn('--image-worker', argv)
                        child = real_popen([sys.executable, '-B', '-c', source], **kwargs)
                        workers.append(child)
                        return child
                    def denied(pid, sig):
                        self.assertIn(pid, [x.pid for x in workers])
                        if sig:
                            raise PermissionError('synthetic observer-only denied kill')
                        return real_killpg(pid, sig)
                    with patch.object(observation.subprocess, 'Popen', side_effect=launch), \
                            patch.object(observation.os, 'killpg', side_effect=denied), \
                            patch.object(observation, 'PROBE_LIMIT_SECONDS', .3), \
                            patch.object(observation, 'REAP_RESERVE_SECONDS', .1):
                        value = observation.read_owned_image(primary, DEVICE, time.monotonic() + .6)
                    self.assertTrue(ready.exists(), 'Invalid fixture: post-check pause was not reached')
                    self.assertFalse(value['cleanupResolved'])
                    self.assertFalse(primary._waitpid_lock.locked())
                    primary_release.write_text('exit')
                    primary.wait(timeout=2)
                    release.write_text('resume')
                    for child in workers:
                        child.wait(timeout=2)
                else:
                    # The narrow fix removes the unsafe capability, rather than
                    # moving an expiry check across another preemption boundary.
                    primary_release.write_text('exit')
                    primary.wait(timeout=2)
                    point = observation.BootstatusCheckpoint(primary, DEVICE, root,
                        time.monotonic() - 151, time.monotonic() + 30, threading.Event())
                    with patch.object(observation.subprocess, 'Popen') as launch:
                        point.observe_once()
                    launch.assert_not_called()
                    self.assertFalse(point.evidence['image']['available'])
                    self.assertIn('identity', point.evidence['image']['notRunReason'])
                self.assertFalse(marker.exists(), 'Worker reached PID lookup after protection ended and original was reaped')
                print('Astra PID regression: ' + json.dumps({'imageUnavailable': not hasattr(observation, 'read_owned_image'),
                    'lookupAfterOriginalReap': marker.exists(), 'actualNativeCalled': False, 'actualPIDReuseTested': False}, sort_keys=True))
            finally:
                release.write_text('resume')
                primary_release.write_text('exit')
                for process in [primary] + workers:
                    if process.returncode is None:
                        process.wait(timeout=4)

    def test_claim_before_publication_and_main_error_wait_for_owned_cleanup(self):
        """Pause the real claim lock before publication; all child operations are models."""
        import verify_replay_seed as seed
        phase = next(node for node in ast.parse(Path(runner.__file__).read_text()).body
                     if isinstance(node, ast.FunctionDef) and node.name == 'run_owned_phase')
        stop = next(node for node in phase.body if isinstance(node, ast.FunctionDef) and node.name == 'stop_owned_group')
        claim_line = next(node.lineno for node in ast.walk(stop) if isinstance(node, ast.Assign)
                          and any(isinstance(target, ast.Name) and target.id == 'stop_deadline' for target in node.targets))
        snapshot_lines = {node.lineno for node in ast.walk(phase) if isinstance(node, ast.With)
                          and any(isinstance(item.context_expr, ast.Name) and item.context_expr.id == 'stop_claim'
                                  for item in node.items)}
        factory_ready, claim_held, release_claim, cleanup_entered, release_cleanup = [threading.Event() for _ in range(5)]
        original_error = OSError('synthetic required recorder failure')
        real_thread = threading.Thread
        main_ident = threading.get_ident()
        workers, signals, trace_hits, sync_boundaries, fixture_errors = [], [], [], [], []
        class Child:
            pid, returncode, initial_wait, running = 12345, None, True, True
            def wait(inner, timeout=None):
                if inner.initial_wait:
                    inner.initial_wait = False
                    if not factory_ready.wait(3):
                        raise AssertionError('Invalid fixture: factory not ready')
                    raise subprocess.TimeoutExpired('synthetic-original', timeout)
                cleanup_entered.set()
                if not release_cleanup.wait(3):
                    raise AssertionError('Invalid fixture: cleanup was not released')
                inner.running, inner.returncode = False, -15
                return inner.returncode
        child = Child()
        def trace(frame, event, arg):
            if event == 'line' and frame.f_code.co_filename == runner.__file__:
                if (frame.f_code.co_name == 'stop_owned_group' and frame.f_lineno == claim_line
                        and threading.current_thread().name == 'owned-phase-wait'):
                    trace_hits.append({'stopStarted': frame.f_locals['stop_started'],
                                       'claimLocked': frame.f_locals['stop_claim'].locked()})
                    claim_held.set()
                    if not release_claim.wait(3):
                        raise AssertionError('Invalid fixture: claim publication was not released')
                elif (frame.f_code.co_name == 'run_owned_phase' and frame.f_lineno in snapshot_lines
                        and threading.get_ident() == main_ident and claim_held.is_set()):
                    # Resume at the first main cleanup synchronization boundary.
                    # On the old code this is its join; on the fix it is the claim lock.
                    sync_boundaries.append('claim-lock')
                    release_claim.set()
            return trace
        def make_thread(*args, **kwargs):
            worker = real_thread(*args, **kwargs)
            raw_join = worker.join
            def join(timeout=None):
                sync_boundaries.append('waiter-join')
                release_claim.set()
                return raw_join(timeout=timeout)
            worker.join = join
            workers.append(worker)
            return worker
        def finish_cleanup():
            if not cleanup_entered.wait(3):
                fixture_errors.append('Cleanup was not entered')
            release_cleanup.wait(1.3)  # Longer than the old one-second join.
            release_cleanup.set()
        finisher = real_thread(target=finish_cleanup, name='synthetic-cleanup-release')
        def factory(*args):
            factory_ready.set()
            return None
        def progress(*args):
            if not claim_held.wait(3):
                raise AssertionError('Invalid fixture: claim pause was not reached')
            raise original_error
        def signal_or_probe(pid, number):
            self.assertEqual(pid, child.pid)
            if number:
                signals.append(number)
            else:
                raise ProcessLookupError()
        old_trace = sys.gettrace()
        old_thread_trace = threading.gettrace() if hasattr(threading, 'gettrace') else None
        result = None
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            finisher.start()
            try:
                threading.settrace(trace)
                sys.settrace(trace)
                with patch.object(runner.threading, 'Thread', side_effect=make_thread), \
                        patch.object(runner.subprocess, 'Popen', return_value=child), \
                        patch.object(runner.os, 'killpg', side_effect=signal_or_probe), \
                        patch.object(seed, 'owned_progress', side_effect=progress), \
                        patch.object(observation, 'checkpoint_for', side_effect=factory), \
                        patch.object(failure_observation, 'failure_snapshot', return_value={}):
                    with self.assertRaises(OSError) as caught:
                        runner.run_owned_phase(['synthetic-phase'], root / 'phase.log', root / 'phase.json', .2)
                    value = json.loads((root / 'phase.json').read_text())
                    result = {'originalExceptionIdentityPreserved': caught.exception is original_error,
                        'traceHits': trace_hits, 'synchronizationBoundaries': sync_boundaries[:],
                        'callerReturnedWhilePrimaryRunning': child.running,
                        'callerReturnedWithWaiterAlive': any(worker.is_alive() for worker in workers),
                        'signalsAtReturn': signals[:], 'cleanupOwner': value.get('groupStopOwner'),
                        'groupStopAwaitedByCaller': value.get('groupStopAwaitedByCaller'),
                        'groupStopReturnedBeforeCaller': value.get('groupStopReturnedBeforeCaller'),
                        'groupStopFinished': value.get('groupStopFinished'),
                        'completionWaiterStopped': value.get('completionWaiterStopped'),
                        'actualNativeOrOSChildLaunch': False}
            finally:
                sys.settrace(old_trace)
                threading.settrace(old_thread_trace)
                release_claim.set()
                release_cleanup.set()
                for worker in workers:
                    worker.join(timeout=3)
                finisher.join(timeout=3)
            result['fixtureAllWorkersStopped'] = not finisher.is_alive() and not any(worker.is_alive() for worker in workers)
        print('Astra claim publication regression: ' + json.dumps(result, sort_keys=True))
        self.assertEqual(fixture_errors, [], 'The synthetic cleanup must reach the intended boundary')
        self.assertEqual(trace_hits, [{'stopStarted': False, 'claimLocked': True}])
        self.assertTrue(result['originalExceptionIdentityPreserved'])
        self.assertEqual(result['signalsAtReturn'], [15])
        self.assertTrue(result['fixtureAllWorkersStopped'])
        self.assertFalse(result['callerReturnedWhilePrimaryRunning'], 'Main skipped an already-acquired cleanup claim before publication')
        self.assertFalse(result['callerReturnedWithWaiterAlive'])
        self.assertTrue(result['groupStopAwaitedByCaller'])
        self.assertTrue(result['groupStopReturnedBeforeCaller'])
        self.assertTrue(result['groupStopFinished'])
        self.assertTrue(result['completionWaiterStopped'])


if __name__ == '__main__':
    unittest.main()
