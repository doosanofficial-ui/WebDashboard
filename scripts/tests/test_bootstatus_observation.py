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
        entered = threading.Event()
        real_selector = observation.selectors.DefaultSelector
        selects = []
        def selector():
            value = real_selector()
            real_select = value.select
            def select(timeout=None):
                selects.append(timeout)
                entered.set()
                self.event.set()  # Publish completion only after the real query reaches its read loop.
                return real_select(timeout)
            value.select = select
            return value
        began = time.monotonic()
        with patch.object(observation.selectors, 'DefaultSelector', side_effect=selector):
            value = self.query('import time; time.sleep(20)')
        self.assertLess(time.monotonic() - began, .3)
        self.assertTrue(entered.is_set(), 'The query must enter its real read loop before completion')
        self.assertEqual(value.get('notRunReason'), 'primary-completed-during-query')
        self.assertEqual(len(selects), 1)
        self.assertEqual(len(self.launched), 1)
        self.assertNotIn('errorType', value)
        self.assertTrue(value['childReaped'])
        self.assertTrue(value['cleanupResolved'])
        self.assertTrue(self.launched[0].stdout.closed)
        print('SE entered query cancellation: ' + json.dumps({'readLoopEntered': entered.is_set(),
            'queryChildren': len(self.launched), 'notRunReason': value['notRunReason'],
            'childReaped': value['childReaped'], 'cleanupResolved': value['cleanupResolved'],
            'actualToyPythonChild': True, 'actualNativeLaunch': False}, sort_keys=True))

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

    def synchronized_failure_trial(self, budget, code=None, hook_error=None):
        """Finish the optional query before releasing the original primary verdict."""
        import verify_replay_seed as seed
        primary_waiting, finish_primary = threading.Event(), threading.Event()
        clock, notice, work_deadline = [0.0], [], []
        waiters, calls, queries, states, attempts, order, waits, fixture_errors, launches = [], [], [], [], [], [], [], [], []
        command = ['synthetic-primary']
        def require(event, message):
            if not event.wait(3):
                fixture_errors.append(message)
                raise AssertionError('Invalid fixture: ' + message)
        class Primary:
            pid, returncode, initial_wait = 12345, None, True
            def wait(inner, timeout=None):
                waits.append(('primary', timeout))
                if inner.initial_wait:
                    inner.initial_wait = False
                    waiters.append(threading.current_thread())
                    order.append('primary-wait')
                    primary_waiting.set()
                    require(finish_primary, 'observation did not release the primary')
                    if code is None:
                        clock[0] = budget
                        order.append('primary-timeout')
                        raise subprocess.TimeoutExpired('synthetic-original-wait', timeout)
                    clock[0], inner.returncode = .09, code
                    order.append('primary-nonzero')
                    return code
                order.append('primary-reap')
                if inner.returncode is None:
                    inner.returncode = -15
                return inner.returncode
        class Query:
            pid, returncode, stdin = 12346, None, None
            def __init__(inner):
                inner.stdout = io.BytesIO()
            def wait(inner, timeout=None):
                waits.append(('query', timeout))
                inner.returncode = -9
                order.append('query-reap')
                return inner.returncode
        primary, query_child = Primary(), Query()
        class ExpiringSelector:
            def __enter__(inner): return inner
            def __exit__(inner, *args): return False
            def register(inner, stream, events):
                self.assertIs(stream, query_child.stdout)
                self.assertEqual(events, observation.selectors.EVENT_READ)
            def get_map(inner): return {query_child.stdout: True}
            def select(inner, timeout=None):
                order.append('query-blocked')
                self.assertFalse(notice[0].is_set())
                self.assertGreater(timeout, 0)
                self.assertLessEqual(timeout, .02)
                clock[0] = work_deadline[0]  # Expire the real query loop, not its original primary waiter.
                return []
        def factory(argv, child, results, began, deadline, event):
            notice.append(event)
            require(primary_waiting, 'original waiter did not enter')
            point = observation.BootstatusCheckpoint(child, DEVICE, results, began, deadline, event)
            real_observe = point.observe_once
            def observe():
                real_observe()
                order.append('observation-finished')
                finish_primary.set()
                require(event, 'original waiter did not publish its outcome')
            point.observe_once = observe
            clock[0] = point.scheduled
            return point
        def launch(argv, **kwargs):
            launches.append(list(argv))
            self.assertTrue(kwargs['start_new_session'])
            if argv == command:
                return primary
            self.assertEqual(argv, ['xcrun', 'simctl', 'list', 'devices', DEVICE, '--json'])
            self.assertFalse(notice[0].is_set())
            self.assertIsNone(primary.returncode)
            self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
            self.assertEqual(kwargs['stdout'], subprocess.PIPE)
            self.assertEqual(kwargs['stderr'], subprocess.DEVNULL)
            queries.append(query_child)
            order.append('query-start')
            return query_child
        real_query = observation.read_owned_state
        def read_state(*args):
            calls.append(args[0])
            if hook_error is not None:
                order.append('observation-error')
                raise hook_error
            work_deadline.append(min(args[1] - observation.REAP_RESERVE_SECONDS,
                                     clock[0] + observation.PROBE_LIMIT_SECONDS))
            value = real_query(*args)
            states.append(value)
            return value
        def signal_or_probe(pid, number):
            attempts.append((pid, number))  # Never let product exception handlers hide a signal attempt.
            order.append(('query' if pid == query_child.pid else 'primary') + ('-stop' if number else '-probe'))
            if number == 0:
                raise ProcessLookupError()
        error = None
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(observation, 'OBSERVE_AFTER_SECONDS', .04),                 patch.object(observation, 'OBSERVATION_BUDGET_SECONDS', .12),                 patch.object(observation, 'REAP_RESERVE_SECONDS', .04),                 patch.object(observation, 'PROBE_LIMIT_SECONDS', .05),                 patch.object(runner.time, 'monotonic', side_effect=lambda: clock[0]),                 patch.object(observation, 'checkpoint_for', side_effect=factory),                 patch.object(observation.subprocess, 'Popen', side_effect=launch),                 patch.object(observation.selectors, 'DefaultSelector', ExpiringSelector),                 patch.object(observation, 'read_owned_state', side_effect=read_state),                 patch.object(observation.os, 'killpg', side_effect=signal_or_probe),                 patch.object(seed, 'owned_progress', return_value={}),                 patch.object(failure_observation, 'parse_probe') as parse:
                try:
                    try:
                        runner.run_owned_phase(command, root / 'phase.log', root / 'phase.json', budget)
                    except subprocess.SubprocessError as caught:
                        error = caught
                finally:
                    finish_primary.set()
                    for waiter in waiters:
                        waiter.join(timeout=3)
                        self.assertFalse(waiter.is_alive(), 'The fixture must stop its original waiter')
                receipt = json.loads((root / 'phase.json').read_text())
                checkpoint = json.loads((root / 'bootstatus-inflight-observation.json').read_text())
        self.assertEqual(fixture_errors, [])
        self.assertEqual(calls, [DEVICE], 'The optional observation must actually be attempted once')
        self.assertEqual(waits[0], ('primary', budget))
        self.assertEqual([v for owner, v in waits if owner == 'primary'][1:], [10, 10])
        self.assertEqual(receipt['timeoutSeconds'], budget)
        self.assertEqual(receipt['groupStopOwner'], 'completion-waiter')
        self.assertTrue(receipt['groupStopFinished'])
        self.assertTrue(receipt['groupStopReturnedBeforeCaller'])
        self.assertTrue(receipt['completionWaiterStopped'])
        self.assertNotIn('completionCleanupErrorType', receipt)
        self.assertNotIn('groupCleanupErrors', receipt)
        self.assertIsNotNone(error)
        self.assertEqual(error.cmd, command)
        self.assertEqual(receipt['firstFailure']['source'], 'completion-waiter')
        self.assertEqual(receipt['firstFailure']['childExitCodeBeforeStop'], code)
        self.assertEqual(checkpoint['budgetSeconds'], .12)
        self.assertEqual(checkpoint['scheduledMonotonic'], .04)
        self.assertEqual(checkpoint['deadlineMonotonic'], .04 + .12)
        expected_signals = [(query_child.pid, 9), (query_child.pid, 0)] if hook_error is None else []
        self.assertEqual(attempts, expected_signals + [(primary.pid, 15), (primary.pid, 0)])
        self.assertEqual(launches, [command] + ([['xcrun', 'simctl', 'list', 'devices', DEVICE, '--json']]
                                             if hook_error is None else []))
        parse.assert_not_called()
        return error, receipt, checkpoint, queries, states, order, waits

    def test_original_primary_timeout_and_budget_survive_query_timeout(self):
        error, receipt, checkpoint, queries, states, order, waits = self.synchronized_failure_trial(.2)
        self.assertIsInstance(error, subprocess.TimeoutExpired)
        self.assertEqual(error.timeout, .2)
        self.assertEqual(receipt['timeoutSeconds'], .2)
        self.assertTrue(receipt['timedOut'])
        self.assertEqual(len(queries), 1)
        self.assertEqual(checkpoint['state'], states[0])
        self.assertEqual(states[0].get('errorType'), 'TimeoutExpired')
        self.assertNotIn('notRunReason', states[0], 'Cancellation/skipped work must not impersonate query timeout')
        self.assertTrue(states[0]['childReaped'])
        self.assertTrue(states[0]['cleanupResolved'])
        self.assertEqual(states[0]['cleanupReapBudgetSeconds'], .04)
        query_waits = [v for owner, v in waits if owner == 'query']
        self.assertEqual(len(query_waits), 1)
        self.assertGreater(query_waits[0], 0)
        self.assertAlmostEqual(query_waits[0], .04)
        self.assertTrue(queries[0].stdout.closed)
        self.assertEqual(queries[0].returncode, -9)
        self.assertEqual(receipt['exitCode'], -15)
        self.assertEqual(order, ['primary-wait', 'query-start', 'query-blocked', 'query-stop', 'query-reap',
                                 'query-probe', 'observation-finished', 'primary-timeout', 'primary-stop',
                                 'primary-reap', 'primary-probe', 'primary-reap'])
        print('SE synchronized primary timeout: ' + json.dumps({'order': order,
            'originalTimeoutSeconds': error.timeout, 'receiptTimeoutSeconds': receipt['timeoutSeconds'],
            'timedOut': receipt['timedOut'], 'queryErrorType': states[0]['errorType'],
            'queryReaped': states[0]['childReaped'], 'queryCleanupResolved': states[0]['cleanupResolved'],
            'actualNativeOrOSChildLaunch': False}, sort_keys=True))

    def test_original_primary_nonzero_exit_survives_observation_error(self):
        error, receipt, checkpoint, queries, states, order, _ = self.synchronized_failure_trial(
            .3, code=7, hook_error=ValueError('PRIVATE_TOKEN'))
        self.assertIsInstance(error, subprocess.CalledProcessError)
        self.assertEqual(error.returncode, 7)
        self.assertFalse(receipt['timedOut'])
        self.assertEqual(receipt['timeoutSeconds'], .3)
        self.assertLessEqual(receipt['processCompletionObservedElapsedSeconds'], .3)
        self.assertEqual(receipt['exitCode'], 7)
        self.assertEqual(checkpoint.get('errorType'), 'ValueError')
        self.assertNotIn('PRIVATE_TOKEN', json.dumps(checkpoint) + json.dumps(receipt))
        self.assertEqual(queries, [])
        self.assertEqual(states, [])
        self.assertEqual(order, ['primary-wait', 'observation-error', 'observation-finished',
                                 'primary-nonzero', 'primary-stop', 'primary-reap', 'primary-probe', 'primary-reap'])
        print('SE synchronized observation error: ' + json.dumps({'order': order,
            'originalReturnCode': error.returncode, 'timedOut': receipt['timedOut'],
            'receiptTimeoutSeconds': receipt['timeoutSeconds'], 'observationErrorType': checkpoint['errorType'],
            'actualNativeOrOSChildLaunch': False}, sort_keys=True))


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
    def retain_failed_trial(self, kind, error, evidence):
        """Keep synthetic receipts after TemporaryDirectory cleanup, including CI Seed failure."""
        previous = getattr(error, 'bootstatus_fixture_receipt', None)
        if previous:
            return Path(previous)
        import hashlib
        try:
            source_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        except OSError:
            source_hash = None
        value = {'schemaVersion': 1, 'scope': 'synthetic-bootstatus-fixture-failure-only',
                 'qualifiedSeedProduced': False, 'kind': kind, 'errorType': type(error).__name__,
                 'error': str(error), 'fixtureSourceSHA256': source_hash,
                 'ci': {key: os.environ.get(key) for key in ('GITHUB_RUN_ID', 'GITHUB_JOB', 'GITHUB_SHA')},
                 'evidence': evidence, 'nativeExecuted': False}
        try:
            configured = os.environ.get('TELEMETRY_FIXTURE_FAILURE_DIR')
            if configured:
                base = Path(configured)
            elif os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_TEMP'):
                # The existing Seed always-upload step preserves this directory
                # when its preceding contract step fails. On success we create
                # nothing, so the qualified Seed producer still gets a new path.
                base = Path(os.environ['RUNNER_TEMP']) / 'replay-seed/contract-failures'
            else:
                base = Path(tempfile.gettempdir()) / 'telemetry-contract-failures'
            base.mkdir(parents=True, exist_ok=True)
            safe_kind = kind if kind in ('control', 'image-popen', 'state-popen', 'receipt-write') else 'fixture'
            saved = Path(tempfile.mkdtemp(prefix=safe_kind + '-', dir=base)) / 'failure.json'
            saved.write_text(json.dumps(value, indent=2), encoding='utf-8')
            error.bootstatus_fixture_receipt = str(saved)
        except Exception as recording_error:
            # The original assertion still propagates. CI logs retain the same
            # structured receipt even if optional filesystem recording fails.
            value['recordingErrorType'] = type(recording_error).__name__
            try:
                print('BOOTSTATUS_FIXTURE_FAILURE ' + json.dumps(value, sort_keys=True), flush=True)
            except Exception:
                pass
            return None
        try:
            print('BOOTSTATUS_FIXTURE_FAILURE ' + json.dumps({'path': str(saved), **value}, sort_keys=True), flush=True)
        except Exception:
            pass
        return saved

    def phase_trial(self, kind, admission_pause=0):
        """Actual primary/fault/cleanup time; model only the selected fault's admission."""
        real_popen, real_killpg = subprocess.Popen, os.killpg
        real_write, real_parse = failure_observation.safe_write, failure_observation.parse_probe
        processes, calls, launches, attempts, waits, writes, faults, points = [], [], [], [], [], [], [], []
        launch_options = []
        fault_entered, checkpoint_entered, admitting = threading.Event(), threading.Event(), threading.Event()
        admission = {'scope': 'Fixture observation admission only; runner/fault/cleanup clocks remain actual',
                     'pauseRequestedSeconds': admission_pause, 'modeledSamples': 0,
                     'primaryClockUnmodified': runner.time is time}
        waiters = []
        with tempfile.TemporaryDirectory(prefix='bootstatus-term-boundary-') as directory:
            root = Path(directory)
            marker = root / 'primary-lived-after-deadline'
            source = ('import time,os,json; from pathlib import Path; time.sleep(1.05); Path(' + repr(str(marker)) +
                      ').write_text(json.dumps({"monotonic":time.monotonic(),"pid":os.getpid()})); time.sleep(1.5)')
            command = [sys.executable, '-B', '-c', source]
            def fault(label):
                calls.append(label)
                admission['releasedAtRealMonotonic'] = time.monotonic()
                admitting.clear()  # The blocking Popen/journal and all cleanup use actual time.
                fault_entered.set()
                value = {'label': label, 'started': time.monotonic(),
                         'checkpointAttemptedAtEntry': bool(points and points[0].attempted)}
                faults.append(value)
                time.sleep(1)  # Real stall after admission release; primary clock/waiter are never frozen.
                value['returned'] = time.monotonic()
            def launch(argv, **kwargs):
                launches.append(list(argv))
                launch_options.append(dict(kwargs))
                if argv == command:
                    role, actual = 'primary', argv
                elif argv == ['xcrun', 'simctl', 'list', 'devices', DEVICE, '--json']:
                    role, actual = 'query', [sys.executable, '-B', '-c', 'print("{}",flush=True)']
                    if kind == 'state-popen':
                        fault('state-popen')
                else:
                    raise AssertionError('Only owned host Python surrogates may launch')
                child = real_popen(actual, **kwargs)
                processes.append((role, child))
                real_wait = child.wait
                def wait(timeout=None):
                    thread = threading.current_thread()
                    item = {'role': role, 'pid': child.pid, 'timeout': timeout,
                            'started': time.monotonic(), 'thread': thread.name}
                    waits.append(item)
                    if role == 'primary' and thread.name == 'owned-phase-wait' and thread not in waiters:
                        waiters.append(thread)
                    try:
                        code = real_wait(timeout=timeout)
                    except BaseException as error:
                        item['errorType'] = type(error).__name__
                        raise
                    else:
                        item['exitCode'] = code
                        return code
                    finally:
                        item['returned'] = time.monotonic()
                child.wait = wait
                return child
            def signal_or_probe(pid, number):
                attempts.append({'pid': pid, 'signal': number, 'started': time.monotonic()})
                if pid not in [child.pid for _, child in processes]:
                    raise AssertionError('Refuse to signal an unowned process group')
                return real_killpg(pid, number)
            def factory(argv, child, results, began, deadline, event):
                if kind == 'control':
                    return None
                point = observation.BootstatusCheckpoint(child, DEVICE, results, began, deadline, event)
                points.append(point)
                real_observe = point.observe_once
                def observe():
                    checkpoint_entered.set()
                    if kind == 'state-popen':
                        admission['startedAtRealMonotonic'] = time.monotonic()
                        admission['pinnedMonotonic'] = point.scheduled
                        admitting.set()
                    try:
                        return real_observe()
                    finally:
                        admitting.clear()
                point.observe_once = observe
                return point
            def admission_clock():
                if admitting.is_set():
                    admission['modeledSamples'] += 1
                    return admission['pinnedMonotonic']
                return time.monotonic()
            real_state = observation.read_owned_state
            def prepared_state(*args):
                if admission_pause:
                    started = time.monotonic()
                    time.sleep(admission_pause)
                    admission['pauseActualSeconds'] = time.monotonic() - started
                return real_state(*args)
            def write(path, value):
                if Path(path).name != 'bootstatus-inflight-observation.json':
                    return real_write(path, value)
                if kind == 'receipt-write':
                    fault('receipt-write')
                result = real_write(path, value)
                writes.append({'success': result, 'returned': time.monotonic(),
                               'persistedValueMatches': bool(result) and json.loads(Path(path).read_text()) == value})
                return result
            def read_receipt(name):
                path = root / name
                try:
                    return json.loads(path.read_text()) if path.exists() else None
                except Exception as read_error:
                    return {'unavailable': type(read_error).__name__}
            from contextlib import ExitStack
            stack = ExitStack()
            try:
                for name, value in [('OBSERVE_AFTER_SECONDS', .3), ('OBSERVATION_BUDGET_SECONDS', .1),
                                    ('REAP_RESERVE_SECONDS', .02), ('PROBE_LIMIT_SECONDS', .05)]:
                    stack.enter_context(patch.object(observation, name, value))
                stack.enter_context(patch.object(observation, 'checkpoint_for', side_effect=factory))
                stack.enter_context(patch.object(observation.subprocess, 'Popen', side_effect=launch))
                stack.enter_context(patch.object(observation.os, 'killpg', side_effect=signal_or_probe))
                image = stack.enter_context(patch.object(observation, 'read_owned_image', create=True))
                parse = stack.enter_context(patch.object(failure_observation, 'parse_probe', wraps=real_parse))
                stack.enter_context(patch.object(failure_observation, 'safe_write', side_effect=write))
                if kind == 'state-popen':
                    # The contract here is TERM while the caller is inside Popen,
                    # not opportunistic query admission (covered by StateQueryTests).
                    # Freeze only that preparation gate until wrapped Popen enters;
                    # never patch the shared time module or the runner's real clock.
                    stack.enter_context(patch.object(observation, 'time',
                        types.SimpleNamespace(monotonic=admission_clock, sleep=time.sleep)))
                    stack.enter_context(patch.object(observation, 'read_owned_state', side_effect=prepared_state))
                if kind == 'receipt-write':
                    stack.enter_context(patch.object(observation, 'read_owned_state', return_value={'synthetic': True}))
                with self.assertRaises(subprocess.TimeoutExpired) as raised:
                    runner.run_owned_phase(command, root / 'phase.log', root / 'phase.json', .9)
                receipt = json.loads((root / 'phase.json').read_text())
                checkpoint_path = root / 'bootstatus-inflight-observation.json'
                checkpoint = json.loads(checkpoint_path.read_text()) if checkpoint_path.exists() else None
                # Snapshot product-owned cleanup before the fixture's final leak-prevention reap.
                product_reaped = all(child.returncode is not None for _, child in processes)
                product_codes = {role: child.returncode for role, child in processes}
                pipes_closed = all(child.stdout is None or child.stdout.closed for role, child in processes if role == 'query')
                primary = next(child for role, child in processes if role == 'primary')
                terms = [item for item in attempts if item['pid'] == primary.pid and item['signal'] == 15]
                marker_value = json.loads(marker.read_text()) if marker.exists() else None
                image.assert_not_called()
                self.assertEqual(raised.exception.timeout, .9)
                self.assertEqual(raised.exception.cmd, command)
                self.assertTrue(receipt['timedOut'])
                self.assertEqual(len(terms), 1)
                self.assertEqual(len(waiters), 1)
                self.assertTrue(receipt['completionWaiterStopped'])
                self.assertTrue(all(not worker.is_alive() for worker in waiters))
                self.assertNotIn('completionCleanupErrorType', receipt)
                self.assertNotIn('groupCleanupErrors', receipt)
                self.assertEqual(receipt['firstFailure']['source'], 'completion-waiter')
                self.assertIsNone(receipt['firstFailure']['childExitCodeBeforeStop'])
                self.assertEqual(launches[0], command)
                self.assertTrue(all(item.get('start_new_session') is True for item in launch_options))
                self.assertTrue(all(item.get('stdin') == subprocess.DEVNULL for item in launch_options))
                self.assertEqual(launch_options[0]['stderr'], subprocess.STDOUT)
                self.assertTrue(all(item['stdout'] == subprocess.PIPE and item['stderr'] == subprocess.DEVNULL
                                    for item in launch_options[1:]))
                self.assertTrue(all(argv == ['xcrun', 'simctl', 'list', 'devices', DEVICE, '--json'] for argv in launches[1:]))
                self.assertTrue(all(item['pid'] in [child.pid for _, child in processes] for item in attempts))
                primary_waits = [item for item in waits if item['role'] == 'primary']
                self.assertGreater(primary_waits[0]['timeout'], 0)
                self.assertLessEqual(primary_waits[0]['timeout'], .9)
                self.assertEqual(primary_waits[0]['errorType'], 'TimeoutExpired')
                self.assertEqual(primary_waits[0]['thread'], 'owned-phase-wait')
                self.assertEqual(len(primary_waits), 3)
                self.assertTrue(all(0 < item['timeout'] <= 10 for item in primary_waits[1:]))
                self.assertLess(terms[0]['started'], primary_waits[1]['started'])
                self.assertEqual([item['signal'] for item in attempts if item['pid'] == primary.pid], [15, 0])
                if marker_value is not None:
                    self.assertEqual(marker_value['pid'], primary.pid)
                self.assertEqual(checkpoint_entered.is_set(), kind != 'control')
                self.assertEqual(fault_entered.is_set(), kind in ['state-popen', 'receipt-write'])
                self.assertEqual(calls, [kind] if kind in ['state-popen', 'receipt-write'] else [])
                self.assertEqual(len(writes), 0 if kind == 'control' else 1)
                self.assertTrue(all(item['success'] and item['persistedValueMatches'] for item in writes))
                if kind == 'state-popen':
                    self.assertEqual(len(launches), 2)
                    self.assertEqual(checkpoint['state']['notRunReason'], 'observation-deadline-reached')
                    self.assertTrue(checkpoint['state']['childReaped'])
                    self.assertTrue(checkpoint['state']['cleanupResolved'])
                    self.assertTrue(checkpoint['state']['cleanupBeyondObservationDeadline'])
                    self.assertEqual(checkpoint['state']['cleanupReapBudgetSeconds'], .02)
                    query_waits = [item for item in waits if item['role'] == 'query']
                    self.assertEqual(len(query_waits), 1)
                    self.assertGreater(query_waits[0]['timeout'], 0)
                    self.assertLessEqual(query_waits[0]['timeout'], .02)
                    query = next(child for role, child in processes if role == 'query')
                    query_signals = [item for item in attempts if item['pid'] == query.pid]
                    self.assertEqual([item['signal'] for item in query_signals], [9, 0])
                    self.assertLess(query_signals[0]['started'], query_waits[0]['started'])
                    self.assertLess(query_waits[0]['returned'], query_signals[1]['started'])
                    parse.assert_not_called()
                phase_started = receipt['phaseStartedMonotonic']
                return {'kind': kind, 'admission': admission,
                        '_failureEvidence': {'phaseReceipt': receipt, 'checkpointReceipt': checkpoint,
                            'launches': launches, 'attempts': attempts, 'waits': waits, 'writes': writes,
                            'faults': faults, 'admission': admission,
                            'productSnapshotBeforeFixtureCleanup': {'allReaped': product_reaped,
                                'exitCodes': product_codes, 'queryStdoutClosed': pipes_closed, 'marker': marker_value,
                                'waitersStopped': all(not worker.is_alive() for worker in waiters)}},
                        'termSeconds': receipt['groupStopRequestedElapsedSeconds'],
                        'actualTermSeconds': terms[0]['started'] - phase_started,
                        'primaryMarkerAfterDeadline': marker_value is not None, 'marker': marker_value,
                        'diagnosticCalls': calls, 'faultEntered': fault_entered.is_set(),
                        'faults': [{'startedElapsed': item['started'] - phase_started,
                                    'returnedElapsed': item['returned'] - phase_started,
                                    'realDurationSeconds': item['returned'] - item['started'],
                                    'checkpointAttemptedAtEntry': item['checkpointAttemptedAtEntry']} for item in faults],
                        'originalTimeoutSeconds': receipt['timeoutSeconds'],
                        'cleanupOwner': receipt.get('groupStopOwner'), 'cleanupFinished': receipt.get('groupStopFinished', False),
                        'preStopCode': receipt.get('firstFailure', {}).get('childExitCodeBeforeStop'),
                        'allSyntheticChildrenReaped': product_reaped, 'productExitCodes': product_codes,
                        'queryStdoutClosedAtReturn': pipes_closed,
                        'actualHostPythonChildren': [{'role': role, 'pid': child.pid} for role, child in processes],
                        'allFixtureWaitersStopped': all(not worker.is_alive() for worker in waiters),
                        'timingScope': 'Actual primary/fault/cleanup time and host Python children; fixture admission modeled',
                        'actualNativeLaunch': False}
            except BaseException as error:
                self.retain_failed_trial(kind, error, {
                    'phaseReceipt': read_receipt('phase.json'),
                    'checkpointReceipt': read_receipt('bootstatus-inflight-observation.json'),
                    'launches': launches, 'attempts': attempts, 'waits': waits, 'writes': writes,
                    'faults': faults, 'admission': admission, 'faultEntered': fault_entered.is_set(),
                    'primaryMarker': read_receipt('primary-lived-after-deadline'),
                    'productCodesBeforeFixtureCleanup': {role: child.returncode for role, child in processes},
                    'waitersStoppedBeforeFixtureCleanup': all(not worker.is_alive() for worker in waiters)})
                raise
            finally:
                try:
                    for _, child in processes:
                        if child.returncode is None:
                            child.wait(timeout=3)  # Self-expiring surrogates; no second signal after reap.
                    for worker in waiters:
                        worker.join(timeout=3)
                        self.assertFalse(worker.is_alive(), 'The fixture must stop its original waiter')
                except BaseException as error:
                    self.retain_failed_trial(kind, error, {
                        'failureDuringFixtureCleanup': True, 'phaseReceipt': read_receipt('phase.json'),
                        'checkpointReceipt': read_receipt('bootstatus-inflight-observation.json'),
                        'launches': launches, 'attempts': attempts, 'waits': waits, 'faults': faults,
                        'admission': admission, 'ownedCodesAfterFixtureCleanupAttempt': {
                            role: child.returncode for role, child in processes}})
                    raise
                finally:
                    stack.close()

    def test_diagnostic_launch_and_receipt_delays_do_not_delay_original_term(self):
        control = self.phase_trial('control')
        results = [control]
        self.assertEqual(control['diagnosticCalls'], [])
        for kind in ['image-popen', 'state-popen', 'receipt-write']:
            with self.subTest(kind=kind):
                trial = None
                try:
                    trial = self.phase_trial(kind)
                    results.append(trial)
                    self.assertFalse(trial['primaryMarkerAfterDeadline'], 'Diagnostic delay kept the original primary alive beyond deadline')
                    self.assertLessEqual(trial['termSeconds'], control['termSeconds'] + .12)
                    self.assertLessEqual(trial['actualTermSeconds'], control['actualTermSeconds'] + .12)
                    self.assertEqual(trial['diagnosticCalls'], [] if kind == 'image-popen' else [kind])
                    self.assertEqual(trial['originalTimeoutSeconds'], .9)
                    self.assertTrue(trial['allSyntheticChildrenReaped'])
                    self.assertEqual(trial['productExitCodes']['primary'], -15)
                    self.assertTrue(trial['queryStdoutClosedAtReturn'])
                    self.assertTrue(trial['allFixtureWaitersStopped'])
                    self.assertEqual(trial['cleanupOwner'], 'completion-waiter')
                    self.assertTrue(trial['cleanupFinished'])
                    self.assertIsNone(trial['preStopCode'])
                    for fault in trial['faults']:
                        self.assertTrue(fault['checkpointAttemptedAtEntry'])
                        self.assertLess(fault['startedElapsed'], .9)
                        self.assertLess(fault['startedElapsed'], trial['actualTermSeconds'])
                        self.assertGreaterEqual(fault['realDurationSeconds'], 1)
                        self.assertGreater(fault['returnedElapsed'], trial['actualTermSeconds'])
                except BaseException as error:
                    self.retain_failed_trial(kind, error, trial['_failureEvidence'] if trial else {'trialUnavailable': True})
                    raise
        print('Astra termination regression: ' + json.dumps(
            [{key: value for key, value in trial.items() if key != '_failureEvidence'} for trial in results], sort_keys=True))



    def test_state_popen_preparation_preemption_cannot_skip_selected_fault(self):
        control = self.phase_trial('control')
        trial = None
        try:
            trial = self.phase_trial('state-popen', admission_pause=.12)
            self.assertTrue(trial['faultEntered'])
            self.assertTrue(trial['admission']['primaryClockUnmodified'])
            self.assertGreater(trial['admission']['modeledSamples'], 0)
            self.assertGreaterEqual(trial['admission']['pauseActualSeconds'], .1)
            self.assertFalse(trial['primaryMarkerAfterDeadline'])
            self.assertLessEqual(trial['actualTermSeconds'], control['actualTermSeconds'] + .12)
            self.assertEqual(trial['originalTimeoutSeconds'], .9)
            self.assertEqual(trial['diagnosticCalls'], ['state-popen'])
            self.assertTrue(trial['allSyntheticChildrenReaped'])
            self.assertTrue(trial['queryStdoutClosedAtReturn'])
            self.assertTrue(trial['allFixtureWaitersStopped'])
            self.assertGreaterEqual(trial['faults'][0]['realDurationSeconds'], 1)
            self.assertLess(trial['faults'][0]['startedElapsed'], trial['actualTermSeconds'])
            self.assertGreater(trial['faults'][0]['returnedElapsed'], trial['actualTermSeconds'])
        except BaseException as error:
            self.retain_failed_trial('state-popen', error, trial['_failureEvidence'] if trial else {'trialUnavailable': True})
            raise

    def test_failed_trial_receipt_outlives_temporary_phase_and_uses_seed_upload_path(self):
        from contextlib import redirect_stdout
        with tempfile.TemporaryDirectory(prefix='bootstatus-failure-receipt-test-') as directory:
            root = Path(directory)
            captured = io.StringIO()
            # Expected negative fixture: admission completes only after the real
            # primary outcome. It must fail, retain evidence, and never be skipped.
            with patch.dict(os.environ, {'TELEMETRY_FIXTURE_FAILURE_DIR': '',
                    'GITHUB_ACTIONS': 'true', 'RUNNER_TEMP': str(root)}), redirect_stdout(captured):
                with self.assertRaises(AssertionError) as raised:
                    self.phase_trial('state-popen', admission_pause=.65)
            saved = Path(raised.exception.bootstatus_fixture_receipt)
            value = json.loads(saved.read_text())
            saved.relative_to(root / 'replay-seed/contract-failures')
            self.assertEqual(value['scope'], 'synthetic-bootstatus-fixture-failure-only')
            self.assertFalse(value['qualifiedSeedProduced'])
            self.assertFalse(value['nativeExecuted'])
            self.assertEqual(value['errorType'], 'AssertionError')
            self.assertEqual(len(value['fixtureSourceSHA256']), 64)
            evidence = value['evidence']
            self.assertFalse(evidence['faultEntered'])
            self.assertTrue(evidence['phaseReceipt']['timedOut'])
            self.assertEqual(evidence['phaseReceipt']['timeoutSeconds'], .9)
            self.assertTrue(evidence['phaseReceipt']['completionWaiterStopped'])
            self.assertTrue(evidence['phaseReceipt']['groupStopFinished'])
            self.assertTrue(evidence['waitersStoppedBeforeFixtureCleanup'])
            self.assertEqual(evidence['checkpointReceipt']['state']['notRunReason'], 'primary-completed-before-query')
            self.assertIn('BOOTSTATUS_FIXTURE_FAILURE ', captured.getvalue())

    def test_receipt_write_error_preserves_original_assertion_and_log_evidence(self):
        from contextlib import redirect_stdout
        original = AssertionError('synthetic receipt failure oracle')
        captured = io.StringIO()
        with tempfile.TemporaryDirectory(prefix='bootstatus-failure-log-test-') as directory, \
             patch.dict(os.environ, {'TELEMETRY_FIXTURE_FAILURE_DIR': directory}), \
             patch.object(Path, 'write_text', side_effect=OSError('synthetic disk fault')), redirect_stdout(captured):
            caught = None
            try:
                try:
                    raise original
                except BaseException as error:
                    self.retain_failed_trial('state-popen', error, {'synthetic': True})
                    raise
            except BaseException as error:
                caught = error
        self.assertIs(caught, original)
        payload = captured.getvalue().split('BOOTSTATUS_FIXTURE_FAILURE ', 1)[1]
        value = json.loads(payload)
        self.assertEqual(value['recordingErrorType'], 'OSError')
        self.assertEqual(value['errorType'], 'AssertionError')
        self.assertEqual(value['evidence'], {'synthetic': True})

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
