"""Guard Lifecycle's direct call until observation can be cancelled and reaped.

Exercise actual main; every native boundary, device and workspace is synthetic.
The fixture releases deliberately blocked optional work only after taking the
verdict/cleanup snapshot, so a join regression cannot hide behind fixture cleanup.
"""
from contextlib import ExitStack, redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bootstatus_observation as observation
import verify_ios_lifecycle as lifecycle

SIMULATOR = '11111111-1111-4111-8111-111111111111'
COMMAND = ['xcrun', 'simctl', 'bootstatus', SIMULATOR, '-b']


class LifecycleObserverIsolationRegressionTests(unittest.TestCase):
    def trial(self, optional='journal', cleanup_fault=False, success=False):
        with tempfile.TemporaryDirectory(prefix='lifecycle-join-contract-') as directory:
            root = Path(directory); results = root / 'results'; private = root / 'private'
            private.mkdir()
            owned = root / SIMULATOR
            unrelated = root / 'unrelated'; unrelated.write_text('preserve fixture')
            entered, release, primary_done, returned = (threading.Event() for _ in range(4))
            events, first_failures, native_calls, popen_attempts, journals, caught = [], [], [], [], [], []
            operation_threads = []
            original = subprocess.TimeoutExpired(COMMAND, 180, output=b'synthetic partial output', stderr=b'synthetic stderr')
            original_write = observation.failure_observation.safe_write
            real_thread = threading.Thread
            stdout, stderr = io.StringIO(), io.StringIO()

            class Workspace:
                name = str(private)
                def cleanup(self):
                    events.append('workspace'); shutil.rmtree(private)

            def stage(_root, destination):
                destination.mkdir(parents=True)
                (destination / 'fixture.txt').write_text('Synthetic source boundary only')

            def output(command, timeout=60):
                native_calls.append((list(command), timeout))
                if command[1:4] == ['simctl', 'list', 'runtimes']:
                    return json.dumps({'runtimes': [{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                        'version': '27.0', 'isAvailable': True,
                        'supportedDeviceTypes': [{'identifier': 'fixture-phone', 'productFamily': 'iPhone'}]}]})
                if command[1:3] == ['simctl', 'create']:
                    owned.write_text('owned fixture'); return SIMULATOR
                if command[1:3] == ['simctl', 'boot']: return ''
                if command == COMMAND:
                    operation_threads.append(threading.get_ident())
                    # In the rejected adapter this allows the blocked observer to
                    # enter before the primary fails. Restored main starts none.
                    entered.wait(.04)
                    events.append('primary-return'); primary_done.set()
                    if not success: raise original
                    return 'original bootstatus result'
                if command[0] == 'xcodegen': return ''
                if command[1:5] == ['xcresulttool', 'get', 'test-results', 'summary']:
                    return json.dumps({'totalTestCount': lifecycle.EXPECTED_TEST_COUNT,
                        'passedTests': lifecycle.EXPECTED_TEST_COUNT, 'failedTests': 0, 'skippedTests': 0})
                raise AssertionError('Unreplaced native boundary: ' + repr(command))

            def run(command, **kwargs):
                native_calls.append((list(command), kwargs))
                if command[0] == 'xcodebuild':
                    kwargs['stdout'].write('Synthetic xcode boundary, no XCTest execution\n')
                    return subprocess.CompletedProcess(command, 0)
                phase = command[2]
                if phase not in ('shutdown', 'delete'):
                    raise AssertionError('Unreplaced cleanup boundary')
                events.append(phase)
                if cleanup_fault and phase == 'shutdown': raise subprocess.TimeoutExpired(command, 60)
                if cleanup_fault and phase == 'delete': raise subprocess.CalledProcessError(7, command)
                if phase == 'delete': owned.unlink()
                return subprocess.CompletedProcess(command, 0)

            def journal(path, value):
                if path.name == 'bootstatus-inflight-observation.json':
                    journals.append(path.name); entered.set()
                    if not release.wait(3): raise RuntimeError('Synthetic optional journal release guard')
                return original_write(path, value)

            def late_popen(command, **kwargs):
                popen_attempts.append(list(command)); entered.set()
                if not release.wait(3): raise RuntimeError('Synthetic optional launch release guard')
                raise OSError('Synthetic late Popen; no child was started')

            def first_failure(*args, **kwargs):
                first_failures.append(args); events.append('first-failure')

            def invoke():
                try: lifecycle.main()
                except BaseException as error: caught.append(error)
                finally: returned.set()

            probe = real_thread(target=invoke, name='lifecycle-main-contract-fixture')
            before_release = None
            with ExitStack() as stack:
                stack.enter_context(patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}))
                stack.enter_context(patch.object(sys, 'platform', 'darwin'))
                stack.enter_context(patch.object(lifecycle.platform, 'system', return_value='Darwin'))
                stack.enter_context(patch.object(sys, 'argv', ['verify_ios_lifecycle.py', '--result-directory', str(results)]))
                stack.enter_context(patch.object(lifecycle.tempfile, 'TemporaryDirectory', return_value=Workspace()))
                stack.enter_context(patch.object(lifecycle, 'stage_sources', side_effect=stage))
                stack.enter_context(patch.object(lifecycle.export_fixture, 'instrument_export_sources', return_value={}))
                stack.enter_context(patch.object(lifecycle, 'record_toolchain', return_value={}))
                stack.enter_context(patch.object(lifecycle, 'output', side_effect=output))
                stack.enter_context(patch.object(lifecycle.subprocess, 'run', side_effect=run))
                stack.enter_context(patch.object(lifecycle.subprocess, 'Popen', side_effect=late_popen))
                stack.enter_context(patch.object(lifecycle, 'observe_first_failure', side_effect=first_failure))
                stack.enter_context(patch.object(observation, 'OBSERVE_AFTER_SECONDS', .001))
                if optional == 'journal':
                    stack.enter_context(patch.object(observation, 'read_owned_state', return_value={'scope': 'synthetic query'}))
                stack.enter_context(patch.object(observation.failure_observation, 'safe_write', side_effect=journal))
                workers = stack.enter_context(patch.object(threading, 'Thread', wraps=real_thread))
                stack.enter_context(redirect_stdout(stdout)); stack.enter_context(redirect_stderr(stderr))
                try:
                    probe.start()
                    primary_seen = primary_done.wait(1)
                    # No optional release occurs until after this snapshot.
                    completed_without_release = returned.wait(.15)
                    before_release = {'primaryCompleted': primary_seen, 'mainReturned': completed_without_release,
                        'firstFailurePublished': bool(first_failures), 'cleanup': list(events),
                        'optionalEntered': entered.is_set(),
                        'liveObservers': sum(t.name.startswith('telemetry-lifecycle-boot-observer') for t in threading.enumerate())}
                finally:
                    release.set(); probe.join(2)
                observer_starts = workers.call_count
            receipt = results / 'simulator-cleanup.json'
            return {'snapshot': before_release, 'error': caught[0] if caught else None, 'original': original,
                'events': events, 'firstFailures': first_failures, 'nativeCalls': native_calls,
                'popenAttempts': popen_attempts, 'journals': journals, 'observerStarts': observer_starts,
                'probeReaped': not probe.is_alive(), 'operationThreads': operation_threads, 'callerThread': probe.ident,
                'liveObserversAfter': sum(t.name.startswith('telemetry-lifecycle-boot-observer') for t in threading.enumerate()),
                'ownedRemoved': not owned.exists(), 'workspaceRemoved': not private.exists(),
                'unrelatedPreserved': unrelated.read_text() == 'preserve fixture',
                'receipt': json.loads(receipt.read_text()) if receipt.exists() else None, 'stdout': stdout.getvalue()}

    def assert_original_timeout_reaches_cleanup_without_optional_release(self, value):
        self.assertTrue(value['snapshot']['primaryCompleted'])
        self.assertTrue(value['snapshot']['mainReturned'], 'Optional observation blocked exception delivery or Simulator cleanup')
        self.assertTrue(value['snapshot']['firstFailurePublished'])
        self.assertEqual(value['snapshot']['cleanup'], ['primary-return', 'first-failure', 'shutdown', 'delete', 'workspace'])
        self.assertIs(value['error'], value['original'])
        self.assertEqual(value['error'].timeout, 180); self.assertIs(value['error'].cmd, COMMAND)
        self.assertIs(value['error'].output, value['original'].output)
        self.assertIs(value['error'].stderr, value['original'].stderr)
        self.assertEqual(value['error'].output, b'synthetic partial output')
        self.assertEqual(value['error'].stderr, b'synthetic stderr')
        self.assertEqual(value['operationThreads'], [value['callerThread']])
        self.assertFalse(value['snapshot']['optionalEntered'])
        self.assertEqual(value['observerStarts'], 0)
        self.assertEqual(value['snapshot']['liveObservers'], 0); self.assertEqual(value['liveObserversAfter'], 0)
        self.assertEqual(value['popenAttempts'], []); self.assertEqual(value['journals'], [])
        self.assertTrue(value['probeReaped']); self.assertTrue(value['workspaceRemoved']); self.assertTrue(value['unrelatedPreserved'])
        self.assertNotIn('HOSTED XCTEST PASS', value['stdout'])
        boot = [call for call in value['nativeCalls'] if call[0] == COMMAND]
        self.assertEqual(boot, [(COMMAND, 180)])
        cleanup = [call for call in value['nativeCalls'] if call[0][1:3] in (['simctl', 'shutdown'], ['simctl', 'delete'])]
        self.assertEqual([call[1]['timeout'] for call in cleanup], [60, 60])
        self.assertEqual([call[1]['check'] for call in cleanup], [False, True])

    def test_timeout_does_not_wait_for_blocked_optional_journal(self):
        value = self.trial('journal')
        self.assert_original_timeout_reaches_cleanup_without_optional_release(value)
        self.assertTrue(value['ownedRemoved'])

    def test_timeout_does_not_start_late_optional_popen_or_leave_worker(self):
        value = self.trial('late-popen')
        self.assert_original_timeout_reaches_cleanup_without_optional_release(value)
        self.assertTrue(value['ownedRemoved'])

    def test_original_timeout_survives_cleanup_faults_and_still_attempts_delete(self):
        value = self.trial('journal', cleanup_fault=True)
        self.assert_original_timeout_reaches_cleanup_without_optional_release(value)
        self.assertFalse(value['receipt']['success'])
        self.assertEqual(value['receipt']['phases'][1]['exitCode'], 7)

    def test_success_retains_original_budgets_without_starting_lifecycle_observer(self):
        value = self.trial('journal', success=True)
        self.assertTrue(value['snapshot']['mainReturned'])
        self.assertIsNone(value['error']); self.assertEqual(value['firstFailures'], [])
        self.assertEqual(value['observerStarts'], 0); self.assertEqual(value['popenAttempts'], [])
        self.assertEqual(value['journals'], []); self.assertEqual(value['liveObserversAfter'], 0)
        self.assertTrue(value['probeReaped']); self.assertTrue(value['ownedRemoved']); self.assertTrue(value['workspaceRemoved'])
        self.assertEqual([call[1] for call in value['nativeCalls'] if call[0] == COMMAND], [180])
        xcode = [call for call in value['nativeCalls'] if call[0][0] == 'xcodebuild']
        self.assertEqual(len(xcode), 1); self.assertEqual(xcode[0][1]['timeout'], 900)
        self.assertEqual(value['events'], ['primary-return', 'shutdown', 'delete', 'workspace'])


if __name__ == '__main__':
    unittest.main()
