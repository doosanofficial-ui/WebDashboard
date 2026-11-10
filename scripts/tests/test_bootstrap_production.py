"""Device-free caller contracts; every native/process boundary is replaced."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import verify_bootstrap_compare as trial
import verify_offline_replay as runner

NEW = '49234AC2-B449-4BDD-9736-62F2AA518C16'
EXISTING = '11111111-1111-4111-8111-111111111111'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'


class ProductionBootstrapTests(unittest.TestCase):
    def fixtures(self, *, baseline='good', created=NEW, failure=None, shutdown_error=None):
        events = []

        def output(command, **kwargs):
            events.append(('output', command))
            if command[2:4] == ['list', 'devices']:
                return json.dumps({'devices': {RUNTIME: [{'udid': EXISTING}]}})
            if command[2:4] == ['list', 'runtimes']:
                return json.dumps({'runtimes': [{'identifier': RUNTIME, 'version': '27.0',
                                                'buildversion': '24A434'}]})
            if command[2] == 'create':
                return created
            raise AssertionError('Unexpected external call: ' + repr(command))

        def phase(command, log, receipt, timeout, **kwargs):
            events.append(('phase', command, timeout, kwargs))
            recorded = {'command': command, 'timeoutSeconds': timeout, 'launched': True,
                        'timedOut': False, 'exitCode': 0, 'completionWaiterStopped': True,
                        'groupExistsAfterCleanup': False}
            if '--neutral-baseline' in command:
                probes = [{'name': 'neutral-process', 'childReaped': True, 'childExitCode': 0}]
                if baseline == 'empty':
                    probes = []
                if baseline == 'group-live':
                    recorded['groupExistsAfterCleanup'] = True
                if baseline == 'waiter-live':
                    recorded['completionWaiterStopped'] = False
                journal = {'diagnosisStartedMonotonic': 10, 'deadlineMonotonic': 30,
                           'budgetSeconds': 20, 'resources': None, 'stages': [],
                           'probes': probes, 'controlSucceeded': True}
                (receipt.parent / 'neutral-process-baseline.json').write_text(json.dumps(journal))
            elif command[:2] == ['xcrun', 'simctl']:
                if command[2] == 'bootstatus' and failure is not None:
                    raise failure
                if command[2] == 'shutdown' and shutdown_error is not None:
                    raise shutdown_error
                if command[2] not in ('boot', 'bootstatus', 'shutdown', 'delete'):
                    raise AssertionError(command)
            else:
                raise AssertionError('Unexpected process: ' + repr(command))
            receipt.write_text(json.dumps(recorded))
            return recorded

        def observe(error, results, simulator, name, **kwargs):
            first = results / 'first-failure-observation.json'
            if first.exists():
                return
            first.write_text(json.dumps({
                'errorType': type(error).__name__, 'phase': name, 'simulator': simulator}))
            (results / 'failure-diagnostic-status.json').write_text(json.dumps({
                'success': True, 'ownedGroupCleanupResolved': True,
                'worker': {'exitCode': 0, 'completionWaiterStopped': True}}))
            (results / 'failure-diagnostic-probes.json').write_text(json.dumps({'probes': []}))

        collector = mock.Mock()
        collector.finalize.return_value = {'collectorCleaned': True}
        patchers = [mock.patch.multiple(trial, output=output, run_owned_phase=phase,
            record_toolchain=lambda _: {'xcode_version': '27.0'},
            current_commit=lambda _: '604d4744c6d18bb4c2746f7ec9caca7dc4676e07',
            select_ui_destination=lambda *_: (RUNTIME, 'iPhone17'),
            OwnedSimulatorBootLog=lambda *_: collector),
            mock.patch.object(runner, 'run_owned_phase', side_effect=phase),
            mock.patch.object(runner, 'observe_first_failure', side_effect=observe),
            mock.patch.object(runner, 'capture_simulator_bootstrap_failure'),
            mock.patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}),
            mock.patch.object(trial, 'os', SimpleNamespace(environ=os.environ, name='posix'), create=True),
            mock.patch.object(trial, 'sys', SimpleNamespace(platform='darwin', executable=sys.executable), create=True)]
        for patcher in patchers:
            patcher.start()
            self.addCleanup(patcher.stop)
        return events

    def run_production(self, results):
        try:
            return trial.run_trial(ROOT, results, combined=False, production=True)
        except TypeError as error:
            self.fail('Missing production boot-only caller contract: ' + str(error))

    def test_baseline_precedes_creation_and_existing_production_protocol_runs_once(self):
        events = self.fixtures()
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            value = self.run_production(results)
            self.assertTrue(value['trialPassed'])
            self.assertEqual(value['mode'], 'production')
            self.assertEqual(value['uiTestsExecuted'], 0)
            self.assertEqual(value['bootstatusLimitSeconds'], runner.BOOTSTATUS_TIMEOUT_SECONDS)
            self.assertTrue((results / 'boot-only.json').is_file())
            self.assertFalse((results / 'comparison.json').exists())
        self.assertIn('--neutral-baseline', events[0][1])
        self.assertEqual(events[0][2:], (20, {'ensure_group_cleanup': True}))
        self.assertEqual(events[0][1][events[0][1].index('--simulator') + 1], '-')
        commands = [(e[1], e[2]) for e in events if e[0] == 'phase' and e[1][0] == 'xcrun']
        self.assertEqual(commands, [(['xcrun', 'simctl', 'boot', NEW], 60),
            (['xcrun', 'simctl', 'bootstatus', NEW, '-b'], runner.BOOTSTATUS_TIMEOUT_SECONDS),
            (['xcrun', 'simctl', 'shutdown', NEW], 60), (['xcrun', 'simctl', 'delete', NEW], 60)])
        self.assertEqual(sum(e[0] == 'output' and e[1][2] == 'create' for e in events), 1)

    def test_empty_control_blocks_before_any_device_query_or_creation(self):
        events = self.fixtures(baseline='empty')
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            with self.assertRaises(RuntimeError):
                self.run_production(results)
            admission = json.loads((results / 'baseline-admission.json').read_text())
            self.assertFalse(admission['admitted'])
            self.assertFalse(admission['controlObserved'])
        self.assertEqual(len(events), 1)

    def test_live_worker_group_blocks_creation_even_with_successful_control(self):
        events = self.fixtures(baseline='group-live')
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(RuntimeError):
                self.run_production(Path(directory) / 'result')
        self.assertEqual(len(events), 1)

    def test_waiter_must_stop_before_creation(self):
        events = self.fixtures(baseline='waiter-live')
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(RuntimeError):
                self.run_production(Path(directory) / 'result')
        self.assertEqual(len(events), 1)

    def test_existing_creation_uuid_is_never_booted_or_cleaned(self):
        events = self.fixtures(created=EXISTING)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'existing'):
                self.run_production(Path(directory) / 'result')
        self.assertEqual([e for e in events if e[0] == 'phase' and e[1][0] == 'xcrun'], [])

    def test_boot_timeout_remains_primary_after_shutdown_failure_and_delete_attempt(self):
        original = subprocess.TimeoutExpired('owned bootstatus', 180)
        events = self.fixtures(failure=original, shutdown_error=OSError('fixture shutdown failure'))
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                self.run_production(results)
            self.assertIs(caught.exception, original)
            value = json.loads((results / 'boot-only.json').read_text())
            self.assertFalse(value['trialPassed'])
            self.assertFalse(value['cleanupResolved'])
            self.assertFalse(value['officialBootstatusPassed'])
            first = json.loads((results / 'first-failure-observation.json').read_text())
            self.assertEqual(first['phase'], 'simulator-bootstatus')
            self.assertTrue(value['diagnosticCoverage']['workerSucceeded'])
            self.assertFalse(value['diagnosticCoverage']['controlObserved'])
            self.assertFalse(value['diagnosticCoverage']['controlSucceeded'])
        self.assertEqual([e[1][2] for e in events if e[0] == 'phase' and e[1][0] == 'xcrun'],
                         ['boot', 'bootstatus', 'shutdown', 'delete'])

    def test_local_environment_is_rejected_before_result_or_process_creation(self):
        events = self.fixtures()
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}):
            results = Path(directory) / 'result'
            with self.assertRaises(ValueError):
                self.run_production(results)
            self.assertFalse(results.exists())
        self.assertEqual(events, [])

    def test_final_optional_path_read_cannot_replace_the_boot_timeout(self):
        original = subprocess.TimeoutExpired('owned bootstatus', 180)
        events = self.fixtures(failure=original)
        exists = Path.exists
        def inaccessible_after_cleanup(path):
            deleted = any(e[0] == 'phase' and e[1][:3] == ['xcrun', 'simctl', 'delete'] for e in events)
            if path.name == 'first-failure-observation.json' and deleted:
                raise OSError('fixture final metadata read failed')
            return exists(path)
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            caught = None
            with mock.patch.object(Path, 'exists', inaccessible_after_cleanup):
                try:
                    self.run_production(results)
                except BaseException as error:
                    caught = error
            self.assertIs(caught, original)

    def test_production_cannot_combine_the_different_verbose_boot_protocol(self):
        events = self.fixtures()
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            try:
                with self.assertRaises(ValueError):
                    trial.run_trial(ROOT, results, combined=True, production=True)
            except TypeError as error:
                self.fail('Missing production boot-only caller contract: ' + str(error))
            self.assertFalse(results.exists())
        self.assertEqual(events, [])


    def test_baseline_popen_error_is_preserved_before_toolchain_or_device_queries(self):
        events = self.fixtures()
        original = FileNotFoundError('fixture worker launch failed')
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            with mock.patch.object(trial, 'record_toolchain') as toolchain:
                with mock.patch.object(trial, 'run_owned_phase', side_effect=original):
                    with self.assertRaises(FileNotFoundError) as caught:
                        self.run_production(results)
                toolchain.assert_not_called()
            self.assertIs(caught.exception, original)
            admission = json.loads((results / 'baseline-admission.json').read_text())
            self.assertFalse(admission['admitted'])
            self.assertEqual(admission['workerErrorType'], 'FileNotFoundError')
            self.assertFalse((results / 'environment.json').exists())
        self.assertFalse(any(event[0] == 'output' for event in events))

    def test_baseline_timeout_keeps_the_original_exception_and_never_admits(self):
        events = self.fixtures()
        completed_phase = trial.run_owned_phase
        original = subprocess.TimeoutExpired('neutral worker', 20)

        def timeout_after_receipt(command, log, receipt, budget, **kwargs):
            recorded = completed_phase(command, log, receipt, budget, **kwargs)
            recorded.update(exitCode=-15, timedOut=True)
            receipt.write_text(json.dumps(recorded))
            raise original

        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            with mock.patch.object(trial, 'run_owned_phase', side_effect=timeout_after_receipt):
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    self.run_production(results)
            self.assertIs(caught.exception, original)
            admission = json.loads((results / 'baseline-admission.json').read_text())
            self.assertFalse(admission['admitted'])
            self.assertFalse(admission['workerSucceeded'])
            self.assertTrue(admission['controlObserved'])
            self.assertTrue(admission['controlSucceeded'])
            self.assertFalse(json.loads((results / 'boot-only.json').read_text())['baselineAdmitted'])
        self.assertFalse(any(event[0] == 'output' for event in events))

    def test_baseline_nonzero_and_incomplete_receipts_fail_closed(self):
        for receipt_case in ('nonzero', 'missing-group-confirmation'):
            with self.subTest(receipt_case=receipt_case):
                events = self.fixtures()
                phase = trial.run_owned_phase

                def altered_receipt(command, log, receipt, budget, **kwargs):
                    recorded = phase(command, log, receipt, budget, **kwargs)
                    if '--neutral-baseline' in command:
                        if receipt_case == 'nonzero':
                            recorded['exitCode'] = 9
                            receipt.write_text(json.dumps(recorded))
                        else:
                            recorded.pop('groupExistsAfterCleanup')
                    return recorded

                with tempfile.TemporaryDirectory() as directory:
                    results = Path(directory) / 'result'
                    with mock.patch.object(trial, 'run_owned_phase', side_effect=altered_receipt):
                        with self.assertRaises(RuntimeError):
                            self.run_production(results)
                    admission = json.loads((results / 'baseline-admission.json').read_text())
                    self.assertFalse(admission['admitted'])
                    if receipt_case == 'nonzero':
                        self.assertFalse(admission['workerSucceeded'])
                        self.assertTrue(admission['controlSucceeded'])
                    else:
                        self.assertFalse(admission['workerCleanupResolved'])
                        self.assertFalse(admission['completionWaiterStopped'] is False)
                self.assertFalse(any(event[0] == 'output' for event in events))
                self.doCleanups()

    def test_baseline_does_not_read_control_journal_when_owned_worker_is_unresolved(self):
        events = self.fixtures()
        phase = trial.run_owned_phase
        read_paths = []
        read_object = trial.read_object

        def unresolved(command, log, receipt, budget, **kwargs):
            recorded = phase(command, log, receipt, budget, **kwargs)
            if '--neutral-baseline' in command:
                recorded['groupExistsAfterCleanup'] = True
            return recorded

        def track_reads(path):
            read_paths.append(Path(path).name)
            return read_object(path)

        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            with mock.patch.object(trial, 'run_owned_phase', side_effect=unresolved):
                with mock.patch.object(trial, 'read_object', side_effect=track_reads):
                    with self.assertRaises(RuntimeError):
                        self.run_production(results)
            self.assertFalse(json.loads((results / 'baseline-admission.json').read_text())['controlObserved'])
        self.assertNotIn('neutral-process-baseline.json', read_paths)
        self.assertFalse(any(event[0] == 'output' for event in events))

    def test_baseline_rejects_malformed_or_ambiguous_control_journals(self):
        valid = {'name': 'neutral-process', 'childReaped': True, 'childExitCode': 0}
        cases = [
            ('invalid-json', b'{'),
            ('non-object', b'[]'),
            ('oversized', b' ' * 65),
            ('missing-control', json.dumps({'probes': [], 'controlSucceeded': True}).encode()),
            ('wrong-probe-shape', json.dumps({'probes': 'neutral-process', 'controlSucceeded': True}).encode()),
            ('nonzero-control', json.dumps({'probes': [{**valid, 'childExitCode': 7}], 'controlSucceeded': False}).encode()),
            ('bool-exit-code', json.dumps({'probes': [{**valid, 'childExitCode': False}], 'controlSucceeded': True}).encode()),
            ('unreaped-control', json.dumps({'probes': [{**valid, 'childReaped': False}], 'controlSucceeded': True}).encode()),
            ('duplicate-control', json.dumps({'probes': [valid, valid], 'controlSucceeded': True}).encode()),
            ('extra-probe', json.dumps({'probes': [valid, {'name': 'unexpected'}], 'controlSucceeded': True}).encode()),
            ('control-flag-only', json.dumps({'controlSucceeded': True}).encode()),
        ]
        for case, payload in cases:
            with self.subTest(case=case):
                events = self.fixtures()
                phase = trial.run_owned_phase

                def replace_journal(command, log, receipt, budget, **kwargs):
                    recorded = phase(command, log, receipt, budget, **kwargs)
                    if '--neutral-baseline' in command:
                        (receipt.parent / 'neutral-process-baseline.json').write_bytes(payload)
                    return recorded

                with tempfile.TemporaryDirectory() as directory:
                    results = Path(directory) / 'result'
                    size_patch = mock.patch.object(trial.failure_observation,
                        'MAX_PROBE_OUTPUT_BYTES', 64) if case == 'oversized' else mock.patch.object(
                            trial.failure_observation, 'MAX_PROBE_OUTPUT_BYTES',
                            trial.failure_observation.MAX_PROBE_OUTPUT_BYTES)
                    with size_patch:
                        with mock.patch.object(trial, 'run_owned_phase', side_effect=replace_journal):
                            with self.assertRaises(RuntimeError):
                                self.run_production(results)
                    admission = json.loads((results / 'baseline-admission.json').read_text())
                    self.assertFalse(admission['admitted'])
                    if case in ('invalid-json', 'non-object', 'oversized', 'wrong-probe-shape'):
                        self.assertIn('journalErrorType', admission)
                    self.assertFalse(json.loads((results / 'boot-only.json').read_text())['baselineAdmitted'])
                self.assertFalse(any(event[0] == 'output' for event in events))
                self.doCleanups()

    def test_diagnostic_worker_success_does_not_invent_control_observation(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            (results / 'failure-diagnostic-status.json').write_text(json.dumps({
                'success': True, 'ownedGroupCleanupResolved': True,
                'worker': {'completionWaiterStopped': True}}))
            (results / 'failure-diagnostic-probes.json').write_text(json.dumps({'probes': []}))
            coverage = trial.diagnostic_coverage(results)
            self.assertTrue(coverage['workerSucceeded'])
            self.assertTrue(coverage['workerCleanupResolved'])
            self.assertFalse(coverage['controlObserved'])
            self.assertFalse(coverage['controlSucceeded'])
            self.assertEqual(coverage['notObservedReason'], 'Neutral control not observed')

    def test_boot_success_with_cleanup_failure_cannot_publish_pass(self):
        events = self.fixtures(shutdown_error=OSError('fixture shutdown failure'))
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            with self.assertRaisesRegex(RuntimeError, 'cleanup'):
                self.run_production(results)
            value = json.loads((results / 'boot-only.json').read_text())
            self.assertTrue(value['officialBootstatusPassed'])
            self.assertFalse(value['cleanupResolved'])
            self.assertFalse(value['trialPassed'])
        commands = [event[1][2] for event in events if event[0] == 'phase' and event[1][0] == 'xcrun']
        self.assertEqual(commands, ['boot', 'bootstatus', 'shutdown', 'delete'])

    def test_boot_success_with_collector_failure_cannot_publish_pass(self):
        events = self.fixtures()
        collector = mock.Mock()
        collector.finalize.return_value = {'collectorCleaned': False}
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            with mock.patch.object(trial, 'OwnedSimulatorBootLog', return_value=collector):
                with self.assertRaisesRegex(RuntimeError, 'collector'):
                    self.run_production(results)
            value = json.loads((results / 'boot-only.json').read_text())
            self.assertTrue(value['officialBootstatusPassed'])
            self.assertFalse(value['collectorCleaned'])
            self.assertFalse(value['trialPassed'])
        self.assertEqual([event[1][2] for event in events if event[0] == 'phase' and
                          event[1][0] == 'xcrun'], ['boot', 'bootstatus', 'shutdown', 'delete'])

    def test_final_boot_receipt_write_failure_suppresses_success_marker(self):
        import contextlib
        import io

        events = self.fixtures()
        writer = Path.write_text
        output_stream = io.StringIO()

        def fail_receipt(path, *args, **kwargs):
            if path.name == 'boot-only.json' or path.name.startswith('.boot-only-pending-'):
                raise OSError('fixture receipt write failure')
            return writer(path, *args, **kwargs)

        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            with mock.patch.object(Path, 'write_text', fail_receipt):
                with contextlib.redirect_stdout(output_stream):
                    with self.assertRaisesRegex(OSError, 'receipt'):
                        self.run_production(results)
            self.assertFalse((results / 'boot-only.json').exists())
        self.assertNotIn('BOOTSTRAP PRODUCTION PASS', output_stream.getvalue())
        self.assertTrue(any(event[0] == 'phase' for event in events))

    def test_invalid_creation_uuid_never_reaches_boot_or_cleanup(self):
        events = self.fixtures(created='not-a-uuid')
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                self.run_production(Path(directory) / 'result')
        self.assertEqual([event[1][2] for event in events if event[0] == 'phase' and
                          event[1][0] == 'xcrun'], [])
        self.assertEqual(sum(event[0] == 'output' and event[1][2] == 'create' for event in events), 1)

    def test_existing_or_symlink_result_path_is_rejected_before_worker_launch(self):
        events = self.fixtures()
        with tempfile.TemporaryDirectory() as directory:
            existing = Path(directory) / 'existing'
            existing.mkdir()
            broken_link = Path(directory) / 'broken-link'
            broken_link.symlink_to(Path(directory) / 'missing-target')
            for results in (existing, broken_link):
                with self.subTest(path=results.name):
                    with self.assertRaises(FileExistsError):
                        self.run_production(results)
                    self.assertTrue(results.is_dir() if results == existing else results.is_symlink())
        self.assertEqual(events, [])

    def test_production_cli_rejects_raw_symlink_before_directory_or_external_calls(self):
        import contextlib
        import runpy
        import verify_ios_lifecycle as lifecycle
        import verify_replay_seed as seed

        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'missing-target'
            link = Path(directory) / 'result-link'
            link.symlink_to(target)
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}))
                stack.enter_context(mock.patch.object(sys, 'platform', 'darwin'))
                stack.enter_context(mock.patch.object(sys, 'argv', [
                    'verify_bootstrap_compare.py', '--mode', 'production',
                    '--result-directory', str(link)]))
                create = stack.enter_context(mock.patch.object(runner, 'create_result_directory',
                    wraps=runner.create_result_directory))
                worker = stack.enter_context(mock.patch.object(runner, 'run_owned_phase',
                    side_effect=OSError('fixture external launch disabled')))
                output = stack.enter_context(mock.patch.object(lifecycle, 'output',
                    side_effect=AssertionError('fixture native query disabled')))
                toolchain = stack.enter_context(mock.patch.object(lifecycle, 'record_toolchain',
                    side_effect=AssertionError('fixture toolchain query disabled')))
                stack.enter_context(mock.patch.object(seed, 'current_commit', return_value='fixture-source'))
                caught = None
                try:
                    runpy.run_path(str(ROOT / 'scripts/verify_bootstrap_compare.py'), run_name='__main__')
                except Exception as error:
                    caught = error
                self.assertIsInstance(caught, FileExistsError)
                create.assert_not_called()
                worker.assert_not_called()
                output.assert_not_called()
                toolchain.assert_not_called()
            self.assertTrue(link.is_symlink())
            self.assertFalse(target.exists())

    def test_late_receipt_close_failure_leaves_no_published_success(self):
        import contextlib
        import io

        self.fixtures()
        opener = Path.open
        original = OSError('fixture late receipt close failure')
        closed_receipts = []
        output_stream = io.StringIO()

        @contextlib.contextmanager
        def fail_after_close(stream, path):
            with stream:
                yield stream
            closed_receipts.append(json.loads(path.read_text()))
            raise original

        def open_with_late_failure(path, *args, **kwargs):
            stream = opener(path, *args, **kwargs)
            mode = args[0] if args else kwargs.get('mode', 'r')
            if mode == 'w' and (path.name == 'boot-only.json' or
                               path.name.startswith('.boot-only-pending-')):
                return fail_after_close(stream, path)
            return stream

        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            with mock.patch.object(Path, 'open', open_with_late_failure):
                with contextlib.redirect_stdout(output_stream):
                    with self.assertRaises(OSError) as caught:
                        self.run_production(results)
            self.assertIs(caught.exception, original)
            self.assertEqual(len(closed_receipts), 1)
            self.assertTrue(closed_receipts[0]['trialPassed'])
            self.assertFalse((results / 'boot-only.json').exists())
            self.assertFalse(any(path.name.startswith('.boot-only-pending-') for path in results.iterdir()))
        self.assertNotIn('BOOTSTRAP PRODUCTION PASS', output_stream.getvalue())

    def test_atomic_receipt_publication_failure_leaves_no_success(self):
        import contextlib
        import io

        self.fixtures()
        replace = Path.replace
        original = OSError('fixture atomic receipt publication failure')
        staged_receipts = []
        output_stream = io.StringIO()

        def fail_publication(path, target):
            if Path(target).name == 'boot-only.json':
                staged_receipts.append(json.loads(path.read_text()))
                self.assertFalse(Path(target).exists())
                raise original
            return replace(path, target)

        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'result'
            with mock.patch.object(Path, 'replace', fail_publication):
                with contextlib.redirect_stdout(output_stream):
                    with self.assertRaises(OSError) as caught:
                        self.run_production(results)
            self.assertIs(caught.exception, original)
            self.assertEqual(len(staged_receipts), 1)
            self.assertTrue(staged_receipts[0]['trialPassed'])
            self.assertFalse((results / 'boot-only.json').exists())
            self.assertFalse(any(path.name.startswith('.boot-only-pending-') for path in results.iterdir()))
        self.assertNotIn('BOOTSTRAP PRODUCTION PASS', output_stream.getvalue())



if __name__ == '__main__':
    unittest.main()
