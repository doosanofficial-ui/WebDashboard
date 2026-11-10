import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import failure_observation as observation
import verify_offline_replay as runner


class NeutralDiagnosticTests(unittest.TestCase):
    def test_control_is_persisted_before_optional_metadata_consumes_deadline(self):
        for slow in ('resources', 'identity'):
            with self.subTest(slow=slow), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                clock = {'now': 100.0}
                calls = []
                def metadata(name, value):
                    if name == slow:
                        clock['now'] = 121.0
                    return value
                def probe(name, command, timeout, device, owned_children):
                    calls.append((name, command, timeout, device))
                    return {'name': name, 'childReaped': True, 'childExitCode': 0}
                with patch.object(observation.time, 'monotonic', side_effect=lambda: clock['now']), \
                     patch.object(observation, 'resources', side_effect=lambda: metadata('resources', {'cpuCount': 3})), \
                     patch.object(observation, 'simctl_identity', side_effect=lambda _: metadata('identity', {'files': []})), \
                     patch.object(observation, 'run_probe', side_effect=probe):
                    self.assertEqual(observation.worker(root, None, 120.0), 0)
                receipt = json.loads((root / 'failure-diagnostic-probes.json').read_text())
                self.assertEqual(calls, [('neutral-process', [sys.executable, '-c', 'pass'], 3, None)])
                self.assertEqual([x['name'] for x in receipt['probes']], ['neutral-process'])
                self.assertTrue(receipt['deadlineReached'])
                self.assertEqual(receipt['deadlineMonotonic'], 120.0)

    def test_expired_worker_does_not_start_a_control_or_metadata(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(observation.time, 'monotonic', return_value=121), \
             patch.object(observation, 'resources') as resources, \
             patch.object(observation, 'simctl_identity') as identity, \
             patch.object(observation, 'run_probe') as probe:
            observation.worker(Path(directory), None, 120)
            receipt = json.loads((Path(directory) / 'failure-diagnostic-probes.json').read_text())
        resources.assert_not_called()
        identity.assert_not_called()
        probe.assert_not_called()
        self.assertTrue(receipt['deadlineReached'])
        self.assertEqual(receipt['probes'], [])

    def test_neutral_baseline_has_separate_journal_and_no_native_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            failure = root / 'first-failure-observation.json'
            journal = root / 'failure-diagnostic-probes.json'
            failure.write_text('{"errorType":"TimeoutExpired"}')
            journal.write_text('{"previous":true}')
            before = failure.read_bytes(), journal.read_bytes()
            result = {'name': 'neutral-process', 'childReaped': True, 'childExitCode': 0}
            with patch.object(observation.time, 'monotonic', return_value=100), \
                 patch.object(observation, 'resources') as resources, \
                 patch.object(observation, 'simctl_identity') as identity, \
                 patch.object(observation, 'run_probe', return_value=result) as probe:
                self.assertEqual(observation.worker(root, None, 120, neutral_only=True), 0)
            probe.assert_called_once_with('neutral-process', [sys.executable, '-c', 'pass'], 3, None, [])
            resources.assert_not_called()
            identity.assert_not_called()
            self.assertEqual((failure.read_bytes(), journal.read_bytes()), before)
            baseline = json.loads((root / 'neutral-process-baseline.json').read_text())
            self.assertEqual(baseline['probes'], [result])
            self.assertEqual([x['name'] for x in baseline['stages']], ['neutral-process'])

    def test_neutral_baseline_timeout_nonzero_and_unreaped_are_not_success(self):
        outcomes = [
            {'childReaped': True, 'childExitCode': -9, 'errorType': 'TimeoutExpired'},
            {'childReaped': True, 'childExitCode': 7, 'errorType': 'CalledProcessError'},
            {'childReaped': False, 'childExitCode': None, 'cleanupErrorType': 'TimeoutExpired'},
        ]
        for outcome in outcomes:
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory, \
                 patch.object(observation.time, 'monotonic', return_value=100), \
                 patch.object(observation, 'run_probe', return_value=outcome):
                root = Path(directory)
                self.assertNotEqual(observation.worker(root, None, 120, neutral_only=True), 0)
                receipt = json.loads((root / 'neutral-process-baseline.json').read_text())
                self.assertEqual(receipt['probes'], [outcome])

    def test_baseline_publication_delay_does_not_admit_a_late_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            clock = {'now': 100.0}
            original_dump = observation.json.dump
            def dump(value, stream, *args, **kwargs):
                result = original_dump(value, stream, *args, **kwargs)
                if value.get('stages'):
                    clock['now'] = 121.0
                return result
            with patch.object(observation.time, 'monotonic', side_effect=lambda: clock['now']), \
                 patch.object(observation.json, 'dump', side_effect=dump), \
                 patch.object(observation, 'run_probe') as probe:
                self.assertNotEqual(observation.worker(root, None, 120, neutral_only=True), 0)
            probe.assert_not_called()
            receipt = json.loads((root / 'neutral-process-baseline.json').read_text())
            self.assertEqual(receipt['probes'], [])
            self.assertTrue(receipt['deadlineReached'])

    def test_baseline_rejects_a_simulator_argument_without_launching(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(observation, 'run_probe') as probe:
            with self.assertRaises(ValueError):
                observation.worker(Path(directory), '11111111-1111-4111-8111-111111111111',
                                   time.monotonic() + 20, neutral_only=True)
        probe.assert_not_called()

    @unittest.skipUnless(os.name == 'posix', 'Owned worker groups require POSIX')
    def test_real_baseline_cli_runs_fixed_control_in_supervised_group_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command = [sys.executable, '-B', str(Path(observation.__file__).resolve()),
                       '--worker', str(root), '--simulator', '-',
                       '--deadline', str(time.monotonic() + 20), '--neutral-baseline']
            with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}), \
                 patch('verify_replay_seed.owned_progress', return_value={}):
                receipt = runner.run_owned_phase(command, root / 'baseline-worker.log',
                    root / 'baseline-worker.json', 20, ensure_group_cleanup=True)
            baseline = json.loads((root / 'neutral-process-baseline.json').read_text())
            self.assertEqual(receipt['exitCode'], 0)
            self.assertIs(receipt['groupExistsAfterCleanup'], False)
            self.assertTrue(receipt['completionWaiterStopped'])
            self.assertEqual(receipt['timeoutSeconds'], 20)
            self.assertEqual([x['name'] for x in baseline['probes']], ['neutral-process'])
            self.assertEqual(baseline['probes'][0]['childExitCode'], 0)
            self.assertTrue(baseline['probes'][0]['childReaped'])
            self.assertNotIn('resources', [x['name'] for x in baseline['stages']])
            self.assertFalse((root / 'first-failure-observation.json').exists())
            self.assertFalse((root / 'failure-diagnostic-probes.json').exists())


if __name__ == '__main__':
    unittest.main()
