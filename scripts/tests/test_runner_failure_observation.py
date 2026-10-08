import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'scripts/tests'))
import verify_offline_replay as replay
import test_ios_lifecycle_runner as hosted_tests
hosted = hosted_tests.runner


class FirstFailureObservationTests(unittest.TestCase):
    def observation_module(self):
        module = getattr(replay, 'failure_observation', None)
        self.assertIsNotNone(module, 'Missing private failure-observation helpers')
        return module

    def test_real_timeout_records_waiter_failure_before_owned_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with patch('verify_replay_seed.owned_progress', return_value={}):
                with self.assertRaises(subprocess.TimeoutExpired):
                    replay.run_owned_phase([sys.executable, '-c', 'import time;time.sleep(2)'],
                        folder/'child.log', folder/'phase.json', .12)
            value = json.loads((folder/'phase.json').read_text())
            self.assertIn('firstFailure', value, 'Missing original waiter failure observation')
            first = value['firstFailure']
            self.assertEqual(first['source'], 'completion-waiter')
            self.assertLessEqual(first['observedMonotonic'], value['phaseStartedMonotonic'] + value['groupStopRequestedElapsedSeconds'])
            self.assertIsNone(first['kernelExitTimestamp'])
            self.assertIsNone(first['childExitCodeBeforeStop'])
            self.assertEqual(value['timeoutSeconds'], .12)
            self.assertNotEqual(value['exitCode'], 0)

    def test_real_nonzero_exit_is_not_reported_as_timeout_or_kernel_timestamp(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with patch('verify_replay_seed.owned_progress', return_value={}):
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    replay.run_owned_phase([sys.executable, '-c', 'raise SystemExit(7)'],
                        folder/'child.log', folder/'phase.json', 2)
            self.assertEqual(raised.exception.returncode, 7)
            value = json.loads((folder/'phase.json').read_text())
            self.assertIn('firstFailure', value, 'Missing actual returned child status')
            self.assertEqual(value['firstFailure']['childExitCodeBeforeStop'], 7)
            self.assertIsNone(value['firstFailure']['kernelExitTimestamp'])
            self.assertFalse(value['timedOut'])

    def test_failed_optional_worker_is_once_only_and_first_failure_is_preserved(self):
        observe = getattr(replay, 'observe_first_failure', None)
        self.assertTrue(callable(observe), 'Missing bounded first-failure observer')
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            original = subprocess.TimeoutExpired(['fixture-boot'], 180)
            execute = Mock(side_effect=subprocess.TimeoutExpired(['optional-worker'], 20))
            with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}):
                observe(original, folder, '11111111-1111-4111-8111-111111111111', 'simulator-bootstatus', run_phase=execute)
                before = (folder/'first-failure-observation.json').read_bytes()
                observe(OSError('later cleanup failure'), folder, '11111111-1111-4111-8111-111111111111', 'cleanup', run_phase=execute)
            self.assertEqual((folder/'first-failure-observation.json').read_bytes(), before)
            self.assertEqual(execute.call_count, 1)
            self.assertEqual(execute.call_args.args[3], 20)
            value = json.loads(before)
            self.assertEqual(value['errorType'], 'TimeoutExpired')
            self.assertEqual(value['diagnosticBudgetSeconds'], 20)
            self.assertEqual(original.timeout, 180)

    def test_hosted_optional_observer_error_does_not_skip_owned_cleanup(self):
        with patch.object(hosted, 'observe_first_failure', side_effect=RuntimeError('synthetic observer fault'), create=True) as observe:
            value = hosted_tests.HostedCleanupControlFlowTests().trial(body='boot', shutdown='timeout')
        observe.assert_called_once()
        self.assertIs(value['error'], value['bootError'])
        self.assertEqual(value['events'], ['shutdown', 'delete', 'workspace'])
        self.assertTrue(value['ownedRemoved'])
        self.assertTrue(value['workspaceRemoved'])

    def test_hosted_checked_call_preserves_result_and_original_exception(self):
        module = self.observation_module()
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            result = subprocess.CompletedProcess(['fixture'], 7)
            call = Mock(return_value=result)
            self.assertIs(module.observe_call(call, folder, 'shutdown', 60), result)
            call.assert_called_once_with()
            receipt = json.loads((folder/'shutdown-observation.json').read_text())
            self.assertEqual(receipt['childExitCode'], 7)
            self.assertIsNone(receipt['kernelExitTimestamp'])
            original = subprocess.TimeoutExpired(['fixture-reader'], 60)
            call = Mock(side_effect=original)
            with self.assertRaises(subprocess.TimeoutExpired) as raised:
                module.observe_call(call, folder, 'result-read', 60)
            self.assertIs(raised.exception, original)
            self.assertIsNone(json.loads((folder/'result-read-observation.json').read_text())['childExitCode'])

    def test_owned_device_probe_excludes_other_device_and_private_fields(self):
        module = self.observation_module()
        device = '11111111-1111-4111-8111-111111111111'
        raw = json.dumps({'devices': {'ios27': [
            {'udid': device, 'state': 'Booted', 'isAvailable': True, 'name': 'PRIVATE_NAME', 'availabilityError': 'PRIVATE_TOKEN'},
            {'udid': '22222222-2222-4222-8222-222222222222', 'state': 'Shutdown', 'name': 'OTHER_PRIVATE'}]}})
        value = module.parse_probe('owned-simulator-state', raw, device)
        self.assertEqual(value, {'simulator': device, 'found': True, 'state': 'Booted', 'isAvailable': True})
        self.assertNotIn('PRIVATE', json.dumps(value))
        self.assertNotIn('22222222', json.dumps(value))

    def test_service_probe_excludes_arguments_paths_and_unrelated_processes(self):
        module = self.observation_module()
        raw = ' 11 S 0:00.12 /Library/CoreSimulatorService\n 12 S 0:00.01 PRIVATE_TOKEN\n 13 R 0:00.02 /usr/bin/simdiskimaged\n'
        value = module.parse_probe('service-processes', raw, None)
        self.assertEqual(value['counts'], {'CoreSimulatorService': 1, 'simdiskimaged': 1})
        self.assertNotIn('PRIVATE_TOKEN', json.dumps(value))
        self.assertNotIn('/Library', json.dumps(value))

    def test_memory_probe_retains_numeric_metrics_only(self):
        module = self.observation_module()
        raw = 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 13.\nPages active: 27.\nSwapins: 3.\nPRIVATE_TOKEN: secret\n'
        value = module.parse_probe('memory-pages', raw, None)
        self.assertEqual(value['pageSizeBytes'], 16384)
        self.assertEqual(value['pageCounts']['Pages free'], 13)
        self.assertEqual(value['pageCounts']['Swapins'], 3)
        self.assertNotIn('PRIVATE', json.dumps(value))

    def test_first_receipt_write_failure_never_runs_diagnostic_or_raises(self):
        module = self.observation_module()
        execute = Mock()
        with tempfile.TemporaryDirectory() as directory:
            original = Path.open
            def opened(path, *args, **kwargs):
                if path.name == 'first-failure-observation.json':
                    raise OSError('synthetic write failure')
                return original(path, *args, **kwargs)
            with patch.object(Path, 'open', opened), patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}):
                module.observe_first_failure(OSError('primary'), Path(directory), None, 'create', run_phase=execute)
        execute.assert_not_called()

    def test_successful_hosted_body_and_cleanup_do_not_collect_failure(self):
        with patch.object(hosted, 'observe_first_failure', create=True) as observe:
            value = hosted_tests.HostedCleanupControlFlowTests().trial()
        self.assertIsNone(value['error'])
        observe.assert_not_called()

    def test_actual_probe_timeout_reaps_child_and_never_saves_raw_output(self):
        module = self.observation_module()
        value = module.run_probe('fixture-only', [sys.executable, '-c',
            "import time;print('PRIVATE_TOKEN',flush=True);time.sleep(2)"], .12, None)
        self.assertEqual(value['errorType'], 'TimeoutExpired')
        self.assertNotEqual(value['childExitCode'], 0)
        self.assertTrue(value['childReaped'])
        self.assertNotIn('PRIVATE_TOKEN', json.dumps(value))

    def test_unresolved_diagnostic_group_is_not_reported_as_clean(self):
        module = self.observation_module()
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            def failed(command, log, receipt, timeout, **kwargs):
                receipt.write_text(json.dumps({'exitCode': -15, 'timedOut': True,
                    'groupStillExistsAfterLeaderWait': True, 'groupKillSent': True}))
                raise subprocess.TimeoutExpired(command, timeout)
            with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}):
                module.observe_first_failure(OSError('primary'), folder,
                    '11111111-1111-4111-8111-111111111111', 'boot', run_phase=failed)
            receipt = json.loads((folder/'failure-diagnostic-status.json').read_text())
            self.assertIsNot(receipt['ownedGroupCleanupResolved'], True)
            self.assertFalse(receipt['success'])

    def test_resource_fault_cannot_skip_success_or_mask_exception(self):
        m = self.observation_module()
        with tempfile.TemporaryDirectory() as d, patch.object(m, 'resources', side_effect=RuntimeError('fixture resource fault')):
            result=subprocess.CompletedProcess(['fixture'], 0)
            operation=Mock(return_value=result)
            self.assertIs(m.observe_call(operation,Path(d),'good',60),result)
            operation.assert_called_once_with()
            error=subprocess.TimeoutExpired(['fixture'],60)
            with self.assertRaises(subprocess.TimeoutExpired) as raised:
                m.observe_call(Mock(side_effect=error),Path(d),'bad',60)
            self.assertIs(raised.exception,error)
    def test_malformed_phase_record_still_captures_first_failure(self):
        m = self.observation_module()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            (root/'boot.json').write_text('not json')
            with patch.dict(os.environ, {'GITHUB_ACTIONS':'false'}):
                m.observe_first_failure(OSError('fixture'),root,None,'boot')
            self.assertTrue((root/'first-failure-observation.json').is_file())


    def test_hosted_reader_keeps_sixty_second_error_and_records_first_call_return(self):
        value = hosted_tests.HostedCleanupControlFlowTests().trial(body='reader', shutdown='timeout')
        self.assertIs(value['error'], value['readerError'])
        self.assertEqual(value['error'].timeout, 60)
        self.assertEqual(value['events'], ['shutdown', 'delete', 'workspace'])
        first = value['firstFailure']
        self.assertEqual(first['phase'], 'result-read')
        self.assertEqual(first['firstFailure']['source'], 'subprocess-call-return')
        self.assertIsNone(first['firstFailure']['childExitCodeBeforeStop'])
        self.assertLessEqual(first['firstFailure']['observedMonotonic'], first['callerReceivedMonotonic'])

    def test_hosted_nonzero_return_is_visible_without_changing_original_runtime_error(self):
        value = hosted_tests.HostedCleanupControlFlowTests().trial(body='xcode')
        self.assertIsInstance(value['error'], RuntimeError)
        self.assertIn('xcodebuild exited 65', str(value['error']))
        self.assertEqual(value['firstFailure']['errorType'], 'RuntimeError')
        self.assertEqual(value['firstFailure']['firstFailure']['childExitCodeBeforeStop'], 65)
        self.assertIsNone(value['firstFailure']['firstFailure']['kernelExitTimestamp'])

    def test_probe_output_cap_stops_owned_child_without_retaining_raw_bytes(self):
        m = self.observation_module()
        value = m.run_probe('fixture-only', [sys.executable, '-c',
            "import sys,time;sys.stdout.write('PRIVATE_'*400000);sys.stdout.flush();time.sleep(2)"], 2, None)
        self.assertEqual(value['errorType'], 'OutputLimitExceeded')
        self.assertTrue(value['childReaped'])
        self.assertTrue(value['forcedStop'])
        self.assertNotIn('PRIVATE_', json.dumps(value))

    def test_actual_diagnostic_deadline_handles_late_spawn_and_term_ignoring_descendant(self):
        m = self.observation_module()
        for mode in ('late-spawn', 'descendant'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as d:
                root = Path(d)
                fixture = root/'fixture_worker.py'
                # Every child is a new Python fixture in the worker's inherited group.
                descendant = "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print('ready',flush=True);time.sleep(5)"
                fixture.write_text("import subprocess,sys,time\n" +
                    "p=subprocess.Popen([sys.executable,'-c'," + repr(descendant) + "],stdout=subprocess.PIPE)\n" +
                    "p.stdout.readline()\nprint('fixture ready',flush=True)\ntime.sleep(5)\n")
                original_popen = subprocess.Popen
                def launch(command, **kwargs):
                    if mode == 'late-spawn' and Path(command[1]).resolve() == fixture.resolve():
                        time.sleep(.18)
                    return original_popen(command, **kwargs)
                primary = subprocess.TimeoutExpired(['original-boot'], 180)
                with patch.object(m, '__file__', str(fixture)), patch.object(m, 'DIAGNOSTIC_BUDGET_SECONDS', .15), \
                     patch.dict(os.environ, {'GITHUB_ACTIONS':'true'}), \
                     patch('verify_replay_seed.owned_progress', return_value={}), \
                     patch.object(subprocess, 'Popen', side_effect=launch):
                    m.observe_first_failure(primary, root, None, 'boot', run_phase=replay.run_owned_phase)
                value = json.loads((root/'failure-diagnostic-status.json').read_text())
                self.assertEqual(value['errorType'], 'TimeoutExpired')
                self.assertFalse(value['success'])
                worker = json.loads((root/'failure-diagnostic-worker.json').read_text())
                self.assertTrue(worker['timedOut'])
                self.assertNotEqual(worker['exitCode'], 0)
                self.assertTrue(worker['completionWaiterStopped'])
                final = worker.get('groupExistsAfterCleanup')
                self.assertIs(value['ownedGroupCleanupResolved'], None if final is None else not final)
                if mode == 'descendant':
                    self.assertTrue(worker['groupKillSent'])
                else:
                    self.assertGreater(worker['launchReturnedElapsedSeconds'], .15)
                first = json.loads((root/'first-failure-observation.json').read_text())
                self.assertEqual(first['errorType'], 'TimeoutExpired')
                self.assertEqual(primary.timeout, 180)


    def test_normal_diagnostic_leader_exit_cleans_its_inherited_descendant_group(self):
        m = self.observation_module()
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            fixture = root/'fixture_worker.py'
            descendant = "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print('ready',flush=True);time.sleep(5)"
            fixture.write_text("import subprocess,sys\n"+
                "p=subprocess.Popen([sys.executable,'-c',"+repr(descendant)+"],stdout=subprocess.PIPE)\n"+
                "p.stdout.readline()\n")
            worker = None
            try:
                with patch.object(m, '__file__', str(fixture)), patch.dict(os.environ, {'GITHUB_ACTIONS':'true'}), \
                     patch('verify_replay_seed.owned_progress', return_value={}):
                    m.observe_first_failure(OSError('original failure'),root,None,'boot',run_phase=replay.run_owned_phase)
                worker = json.loads((root/'failure-diagnostic-worker.json').read_text())
                self.assertEqual(worker['exitCode'], 0)
                self.assertTrue(worker['groupTermSent'], 'Normal worker exit must still stop its inherited descendants')
                self.assertTrue(worker['groupKillSent'])
                self.assertIn('groupExistsAfterCleanup', worker)
                status = json.loads((root/'failure-diagnostic-status.json').read_text())
                self.assertIs(status['success'], worker['groupExistsAfterCleanup'] is False)
                self.assertEqual(json.loads((root/'first-failure-observation.json').read_text())['errorType'],'OSError')
            finally:
                # RED and exceptional test paths also stop only this fixture's newly owned group.
                if worker is not None and worker.get('launched'):
                    try:
                        os.killpg(worker['processGroup'], 9)
                    except ProcessLookupError:
                        pass


    def test_actual_xcode_service_executable_is_counted_without_private_paths(self):
        m = self.observation_module()
        raw = ' 23 S 0:00.1 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/com.apple.CoreSimulator.CoreSimulatorService\n 24 S 0:00.1 PRIVATE_TOKEN\n'
        value = m.parse_probe('service-processes', raw, None)
        self.assertEqual(value['counts'], {'CoreSimulatorService': 1})
        self.assertNotIn('/Library', json.dumps(value))
        self.assertNotIn('PRIVATE_TOKEN', json.dumps(value))


    def test_inflight_observation_preserves_started_stage_on_disk(self):
        m = self.observation_module()
        for blocked_stage in ['resources', 'simctl-identity', 'neutral-process']:
            with self.subTest(blocked_stage=blocked_stage), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                entered = threading.Event()
                release = threading.Event()
                failures = []
                returned = []

                def observe(name, result):
                    if name == blocked_stage:
                        entered.set()
                        if not release.wait(2):
                            raise RuntimeError('Fixture observation was not released')
                    return result

                def invoke():
                    try:
                        returned.append(m.worker(folder, None, time.monotonic() + 20))
                    except BaseException as error:
                        failures.append(error)

                # Replace only external observation seams; exercise the real worker and file writes.
                with patch.object(m, 'resources', side_effect=lambda: observe('resources', {'cpuCount': 1})), \
                     patch.object(m, 'simctl_identity', side_effect=lambda _: observe('simctl-identity', {'files': []})), \
                     patch.object(m, 'run_probe', side_effect=lambda name, *args: observe(name, {'childReaped': True})):
                    thread = threading.Thread(target=invoke)
                    thread.start()
                    try:
                        self.assertTrue(entered.wait(1), 'Worker did not enter the fixture observation')
                        receipt = folder / 'failure-diagnostic-probes.json'
                        self.assertTrue(receipt.is_file(), 'A blocked observation must leave a worker receipt')
                        value = json.loads(receipt.read_text())
                        self.assertTrue(value.get('stages'), 'The in-flight stage must be recorded before its call')
                        stage = value['stages'][-1]
                        self.assertEqual(stage['name'], blocked_stage)
                        self.assertIsInstance(stage['startedMonotonic'], (int, float))
                        self.assertNotIn('finishedMonotonic', stage, 'A blocked observation has not completed')
                        self.assertEqual(value['budgetSeconds'], 20)
                    finally:
                        release.set()
                        thread.join(2)
                    self.assertFalse(thread.is_alive(), 'Fixture worker must be joined')
                    self.assertEqual(failures, [])
                    self.assertEqual(returned, [0])



    def test_journal_write_deadline_does_not_start_a_late_probe(self):
        m = self.observation_module()
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            clock = {'now': 0.0}
            original_dump = m.json.dump

            def dump(value, stream, *args, **kwargs):
                result = original_dump(value, stream, *args, **kwargs)
                stages = value.get('stages', [])
                if stages and stages[-1]['name'] == 'neutral-process':
                    clock['now'] = 21.0
                return result

            with patch.object(m.time, 'monotonic', side_effect=lambda: clock['now']), \
                 patch.object(m.json, 'dump', side_effect=dump), \
                 patch.object(m, 'resources', return_value={'cpuCount': 1}), \
                 patch.object(m, 'simctl_identity', return_value={'files': []}), \
                 patch.object(m, 'run_probe', return_value={'childReaped': True}):
                self.assertEqual(m.worker(folder, None, 20.0), 0)
            value = json.loads((folder / 'failure-diagnostic-probes.json').read_text())
            self.assertTrue(value['deadlineReached'])
            self.assertEqual(value['probes'], [], 'Journal latency must not admit a probe after the budget')
            self.assertEqual(value['budgetSeconds'], 20)




    def test_failed_journal_update_preserves_last_snapshot_and_stops_observations(self):
        m = self.observation_module()
        for boundary in ('start', 'finish'):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                receipt = folder / 'failure-diagnostic-probes.json'
                original_dump = m.json.dump
                at_fault = []

                def dump(value, stream, *args, **kwargs):
                    stages = value.get('stages', [])
                    if stages and stages[-1]['name'] == 'resources' and (
                            ('finishedMonotonic' in stages[-1]) == (boundary == 'finish')):
                        stream.write('{"partial":')
                        stream.flush()
                        at_fault.append(receipt.read_bytes())
                        raise OSError('Synthetic journal write interruption')
                    return original_dump(value, stream, *args, **kwargs)

                with patch.object(m.json, 'dump', side_effect=dump), \
                     patch.object(m, 'resources', return_value={'cpuCount': 1}) as resources, \
                     patch.object(m, 'simctl_identity') as identity, \
                     patch.object(m, 'run_probe') as probe:
                    result = m.worker(folder, None, time.monotonic() + 20)
                self.assertEqual(result, 2, 'A journal failure must stop this optional worker')
                self.assertEqual(len(at_fault), 1)
                value = json.loads(at_fault[0])
                self.assertEqual(receipt.read_bytes(), at_fault[0], 'Retain the last complete published snapshot')
                self.assertEqual(value['probes'], [])
                self.assertNotIn('finishedMonotonic', value)
                identity.assert_not_called()
                probe.assert_not_called()
                if boundary == 'start':
                    resources.assert_not_called()
                    self.assertEqual(value['stages'], [])
                else:
                    resources.assert_called_once_with()
                    self.assertEqual(value['stages'][-1]['name'], 'resources')
                    self.assertNotIn('finishedMonotonic', value['stages'][-1])

    def test_nonpositive_probe_budget_never_launches_a_child(self):
        m = self.observation_module()
        for timeout in (0, -.1):
            with self.subTest(timeout=timeout), patch.object(m.subprocess, 'Popen') as launch:
                value = m.run_probe('fixture-only', ['fixture-not-launched'], timeout, None)
                launch.assert_not_called()
                self.assertEqual(value['notRunReason'], 'deadlineReached')
                self.assertIsNone(value['childExitCode'])
                self.assertFalse(value['childReaped'])

if __name__ == '__main__':
    unittest.main()
