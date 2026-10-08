"""Behavior regression: retain early owned events when later host queries time out."""
from contextlib import ExitStack
import json
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

SCRIPT_ROOT = Path(os.environ.get('WEBDASHBOARD_SCRIPT_ROOT', Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(SCRIPT_ROOT))
spec = importlib.util.spec_from_file_location('bootstrap_stream_runner', SCRIPT_ROOT / 'verify_offline_replay.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class BootstrapStreamIntegrationTests(unittest.TestCase):
    def boot_with_observer_errors(self, cleanup_error=None, start_error=None, stop_error=None, finalize_error=None):
        device = '11111111-1111-4111-8111-111111111111'
        primary = subprocess.TimeoutExpired(['xcrun', 'simctl', 'bootstatus', device, '-b'], 180)
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            results = Path(directory) / 'results'
            argv = ['verify_offline_replay.py', '--group', 'replay', '--seed-artifact', directory,
                    '--seed-manifest-sha256', '0' * 64, '--result-directory', str(results)]
            stack.enter_context(patch.object(sys, 'argv', argv))
            for name, value in [('record_toolchain', {}), ('private_artifact', {'manifest': {}}),
                                ('current_commit', 'fixture'), ('select_ui_destination', ('ios27', 'iphone'))]:
                stack.enter_context(patch.object(runner, name, return_value=value))
            for name in ['run_artifact', 'stage_sources', 'capture_simulator_bootstrap_failure']:
                stack.enter_context(patch.object(runner, name))
            stack.enter_context(patch.object(runner.export_fixture, 'instrument_export_sources', return_value={}))
            def output(command, **kwargs):
                if command[1:4] == ['simctl', 'list', 'runtimes']:
                    return json.dumps({'runtimes': [{'identifier': 'ios27', 'version': '27.0'}]})
                return device
            def phase(command, *args, **kwargs):
                if 'bootstatus' in command: raise primary
                return {}
            stack.enter_context(patch.object(runner, 'output', side_effect=output))
            stack.enter_context(patch.object(runner, 'run_owned_phase', side_effect=phase))
            stack.enter_context(patch.object(runner, 'cleanup_simulator', side_effect=cleanup_error, return_value=True))
            factory = stack.enter_context(patch.object(runner, 'OwnedSimulatorBootLog', side_effect=start_error))
            factory.return_value.request_stop.side_effect = stop_error
            factory.return_value.finalize.side_effect = finalize_error
            factory.return_value.finalize.return_value = {'collectorCleaned': True}
            with self.assertRaises(Exception) as caught:
                runner.main()
            self.assertIs(caught.exception, primary, 'Observer and Simulator cleanup errors must preserve the primary boot object')

    def test_boot_error_is_preserved_when_simulator_cleanup_and_collector_finalize_both_fail(self):
        self.boot_with_observer_errors(cleanup_error=OSError('synthetic cleanup failure'),
                                       finalize_error=OSError('synthetic finalize failure'))

    def test_observer_start_stop_and_finalize_errors_do_not_mask_boot(self):
        for stage in ['start', 'stop', 'finalize']:
            with self.subTest(stage=stage):
                self.boot_with_observer_errors(**{stage + '_error': OSError('synthetic ' + stage + ' failure')})

    def test_early_owned_event_survives_bootstatus_and_post_failure_log_timeouts(self):
        device = '11111111-1111-4111-8111-111111111111'
        launched = threading.Event()
        primary = subprocess.TimeoutExpired(['xcrun', 'simctl', 'bootstatus', device, '-b'], 180)
        native_popen = subprocess.Popen
        calls = []
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'results'
            def output(command, **kwargs):
                if command[1:4] == ['simctl', 'list', 'runtimes']:
                    return json.dumps({'runtimes': [{'identifier': 'ios27', 'version': '27.0'}]})
                if command[1:3] == ['simctl', 'create']:
                    return device
                return ''
            def launch(command, **kwargs):
                self.assertEqual(command[:2], ['/usr/bin/log', 'stream'])
                self.assertIn('eventMessage CONTAINS[c] "' + device + '"', command)
                source = 'import json,time; print(json.dumps({"eventMessage": "early owned ' + device + '"}), flush=True); time.sleep(10)'
                child = native_popen([sys.executable, '-c', source], **kwargs)
                launched.set()
                return child
            def phase(command, log, receipt, timeout, **kwargs):
                calls.append((command, timeout))
                if command[1:3] == ['simctl', 'boot']:
                    # A fake blocked host gives the real collector time to read an early event.
                    launched.wait(0.4)
                    if launched.is_set():
                        import time
                        deadline = time.monotonic() + 1
                        while time.monotonic() < deadline:
                            path = results / 'simulator-boot-stream.ndjson'
                            if path.exists() and device in path.read_text(): break
                            threading.Event().wait(0.01)
                if 'bootstatus' in command: raise primary
                if command[:2] == ['/usr/bin/log', 'show']:
                    raise subprocess.TimeoutExpired(command, 10)
                return {}
            argv = ['verify_offline_replay.py', '--group', 'replay', '--seed-artifact', directory,
                    '--seed-manifest-sha256', '0' * 64, '--result-directory', str(results)]
            with ExitStack() as stack:
                for name, value in [('record_toolchain', {}), ('private_artifact', {'manifest': {}}),
                                    ('current_commit', 'fixture'), ('select_ui_destination', ('ios27', 'iphone'))]:
                    stack.enter_context(patch.object(runner, name, return_value=value))
                for name in ['run_artifact', 'stage_sources']:
                    stack.enter_context(patch.object(runner, name))
                stack.enter_context(patch.object(runner.export_fixture, 'instrument_export_sources', return_value={}))
                stack.enter_context(patch.object(sys, 'argv', argv))
                stack.enter_context(patch.object(runner, 'output', side_effect=output))
                stack.enter_context(patch.object(runner, 'run_owned_phase', side_effect=phase))
                stack.enter_context(patch.object(subprocess, 'Popen', side_effect=launch))
                stack.enter_context(patch.object(Path, 'home', return_value=Path(directory)))
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    runner.main()
            self.assertIs(caught.exception, primary)
            events = results / 'simulator-boot-stream.ndjson'
            self.assertTrue(events.exists(), 'Early owned events must be collected before blocked post-failure log show')
            self.assertIn('early owned ' + device, events.read_text())
            self.assertEqual([(c[2], t) for c, t in calls if c[:2] == ['xcrun', 'simctl'] and c[2] in ['boot', 'bootstatus']],
                             [('boot', 60), ('bootstatus', 180)])
            self.assertTrue(any(c[:2] == ['/usr/bin/log', 'show'] and t == 10 for c, t in calls))
            receipt = json.loads((results / 'simulator-boot-stream.json').read_text())
            self.assertTrue(receipt['workerStopped'])
            self.assertTrue(receipt['leaderReaped'])
            self.assertTrue(receipt['groupGoneFinal'])
            self.assertTrue(receipt['pipeClosed'])


class BootLogBoundaryTests(unittest.TestCase):
    device = '11111111-1111-4111-8111-111111111111'

    def trial(self, source, window=2, byte_limit=2 * 1024 * 1024, probe_error=False, event_open_error=False):
        from owned_simulator_boot_log import OwnedSimulatorBootLog
        native_popen, native_killpg, native_open = subprocess.Popen, os.killpg, Path.open
        children = []
        def launch(command, **kwargs):
            child = native_popen([sys.executable, '-c', source], **kwargs)
            children.append(child.pid)
            return child
        def signal_owned(pid, value):
            self.assertIn(pid, children, 'Every signal/probe must target this test-owned child')
            if probe_error and value == 0:
                raise PermissionError('synthetic group probe unavailable')
            return native_killpg(pid, value)
        def open_path(path, *args, **kwargs):
            if event_open_error and path.name == 'simulator-boot-stream.ndjson' and args == ('wb',):
                raise OSError('synthetic event file unavailable')
            return native_open(path, *args, **kwargs)
        with tempfile.TemporaryDirectory() as directory, patch.object(subprocess, 'Popen', side_effect=launch), \
                patch.object(os, 'killpg', side_effect=signal_owned), patch.object(Path, 'open', open_path):
            collector = OwnedSimulatorBootLog(self.device, Path(directory), window=window, byte_limit=byte_limit)
            collector.worker.join(timeout=3)
            receipt = collector.finalize()
            path = Path(directory) / 'simulator-boot-stream.ndjson'
            data = path.read_bytes() if path.exists() else b''
            self.assertTrue(receipt['workerStopped'])
            self.assertTrue(receipt['pipeClosed'])
            self.assertTrue(receipt['leaderReaped'])
            return receipt, data

    def test_foreign_invalid_and_nonstring_events_are_not_saved(self):
        lines = [json.dumps({'eventMessage': 'foreign 22222222-2222-4222-8222-222222222222'}),
                 'not JSON', json.dumps({'eventMessage': ['owned', self.device]}),
                 json.dumps({'eventMessage': 'owned ' + self.device.lower()})]
        receipt, data = self.trial('import sys; sys.stdout.write(' + repr('\n'.join(lines) + '\n') + '); sys.stdout.flush()')
        self.assertEqual(receipt['events'], 1)
        self.assertEqual(receipt['discardedLines'], 3)
        self.assertEqual(json.loads(data)['eventMessage'], 'owned ' + self.device.lower())
        self.assertTrue(receipt['collectorCleaned'])

    def test_newlineless_output_cannot_exceed_total_input_or_saved_byte_cap(self):
        receipt, data = self.trial('import os; os.write(1, b"x" * (3 * 1024 * 1024))')
        self.assertEqual(receipt['inputBytes'], 2 * 1024 * 1024)
        self.assertEqual(receipt['terminationReason'], 'input-limit')
        self.assertEqual(receipt['events'], 0)
        self.assertEqual(data, b'')
        self.assertLessEqual(receipt['partialBytes'], receipt['lineLimit'])
        self.assertTrue(receipt['collectorCleaned'])

    def test_oversized_line_tail_is_not_mistaken_for_an_owned_event(self):
        owned = json.dumps({'eventMessage': 'owned ' + self.device})
        source = 'import sys; sys.stdout.write(' + repr('x' * 100000 + owned + '\n' + owned + '\n') + '); sys.stdout.flush()'
        receipt, data = self.trial(source)
        self.assertEqual(receipt['events'], 1)
        self.assertEqual(receipt['oversizedLines'], 1)
        self.assertEqual(len(data.splitlines()), 1)

    def test_empty_eof_and_no_output_deadline_have_distinct_results(self):
        eof, _ = self.trial('pass')
        deadline, _ = self.trial('import time; time.sleep(10)', window=0.15)
        self.assertEqual(eof['terminationReason'], 'eof')
        self.assertEqual(deadline['terminationReason'], 'deadline')
        self.assertEqual(deadline['inputBytes'], 0)
        self.assertTrue(eof['collectorCleaned'])
        self.assertTrue(deadline['collectorCleaned'])

    def test_group_probe_error_remains_unresolved_after_leader_is_reaped(self):
        receipt, _ = self.trial('pass', probe_error=True)
        self.assertIsNone(receipt['groupGoneFinal'])
        self.assertFalse(receipt['collectorCleaned'])
        self.assertTrue(any(e['operation'] == 'group-probe' for e in receipt['errors']))

    def test_event_file_failure_still_closes_pipe_and_cleans_the_owned_group(self):
        receipt, data = self.trial('import time; time.sleep(10)', event_open_error=True)
        self.assertEqual(receipt['terminationReason'], 'collector-error')
        self.assertTrue(receipt['collectorCleaned'])
        self.assertTrue(any(e['operation'] == 'collect' for e in receipt['errors']))
        self.assertEqual(data, b'')

    def test_term_handler_cannot_block_on_a_pipe_the_collector_no_longer_reads(self):
        from owned_simulator_boot_log import OwnedSimulatorBootLog
        native_popen = subprocess.Popen
        source = ('import os,signal,time,json; '
                  'signal.signal(signal.SIGTERM, lambda *_: os.write(1, b"x" * (1024 * 1024))); '
                  'print(json.dumps({"eventMessage": "ready ' + self.device + '"}), flush=True); time.sleep(20)')
        def launch(command, **kwargs):
            return native_popen([sys.executable, '-c', source], **kwargs)
        with tempfile.TemporaryDirectory() as directory, patch.object(subprocess, 'Popen', side_effect=launch):
            collector = OwnedSimulatorBootLog(self.device, Path(directory), window=5)
            try:
                deadline = time.monotonic() + 4
                ready = False
                while time.monotonic() < deadline and collector.worker.is_alive():
                    with collector.lock:
                        ready = collector.state['events'] >= 1
                    if ready: break
                    threading.Event().wait(0.01)
                self.assertTrue(ready, 'The child must install its TERM handler and emit an actually captured ready event')
                self.assertIn('ready ' + self.device, (Path(directory) / 'simulator-boot-stream.ndjson').read_text())
                collector.request_stop()
                collector.worker.join(timeout=2)
                first = collector.finalize(join_timeout=0)
                self.assertGreaterEqual(first['events'], 1)
                self.assertEqual(first['terminationReason'], 'stop-request')
                self.assertTrue(first['workerStopped'], 'Close the unread pipe before waiting for a TERM handler that writes output')
                self.assertTrue(first['collectorCleaned'])
            finally:
                # Preserve the first failure while allowing the existing bounded cleanup to finish.
                collector.request_stop()
                collector.worker.join(timeout=22)
                self.assertFalse(collector.worker.is_alive(), 'Test-owned collector cleanup must finish')

    def test_delayed_launch_does_not_block_boot_and_late_child_is_cleaned(self):
        from owned_simulator_boot_log import OwnedSimulatorBootLog
        entered, release = threading.Event(), threading.Event()
        native_popen = subprocess.Popen
        def launch(command, **kwargs):
            entered.set()
            if not release.wait(3): raise RuntimeError('test launch was not released')
            return native_popen([sys.executable, '-c', 'import time; time.sleep(10)'], **kwargs)
        with tempfile.TemporaryDirectory() as directory, patch.object(subprocess, 'Popen', side_effect=launch):
            collector = OwnedSimulatorBootLog(self.device, Path(directory))
            try:
                self.assertTrue(entered.wait(1))
                collector.mark_boot_started()  # A delayed Popen cannot prevent this caller's progress.
                collector.request_stop()
                pending = collector.finalize(join_timeout=0)
                self.assertTrue(pending['launchPending'])
                self.assertFalse(pending['workerStopped'])
                self.assertFalse(pending['collectorCleaned'])
            finally:
                release.set()
            final = collector.finalize(join_timeout=2)
            self.assertEqual(final['terminationReason'], 'stopped-after-launch')
            self.assertTrue(final['collectorCleaned'])
            self.assertEqual(final['inputBytes'], 0)
            self.assertTrue(pending['launchPending'], 'Later worker completion must not mutate the earlier snapshot')
            self.assertFalse(pending['workerStopped'])


if __name__ == '__main__': unittest.main()
