import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import verify_bootstrap_compare as trial

NEW = '49234AC2-B449-4BDD-9736-62F2AA518C16'
EXISTING = '11111111-1111-4111-8111-111111111111'


class BootstrapCompareTests(unittest.TestCase):
    def setup_trial(self, directory, *, returned=NEW, failure=None, cleanup_failure=None):
        output_calls = []
        def output(command, **kwargs):
            output_calls.append(command)
            if command[2:4] == ['list', 'devices']:
                return json.dumps({'devices': {'runtime': [{'udid': EXISTING}]}})
            if command[2:4] == ['list', 'runtimes']:
                return json.dumps({'runtimes': [{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                                                'version': '27.0', 'buildversion': '24A434'}]})
            if command[2] == 'create':
                return returned
            raise AssertionError(command)
        phases = []
        def phase(command, log, receipt, timeout):
            phases.append((command, timeout))
            if failure is not None:
                raise failure
        patcher = mock.patch.multiple(trial,
            output=mock.Mock(side_effect=output),
            run_owned_phase=mock.Mock(side_effect=phase),
            record_toolchain=mock.Mock(return_value={'xcode_version': '27.0'}),
            select_ui_destination=mock.Mock(return_value=('com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'iPhone17')),
            current_commit=mock.Mock(return_value='910fbf1bb16573d14359d52859de2551ef0872b7'),
            cleanup_simulator=mock.Mock(return_value=True, side_effect=cleanup_failure),
            OwnedSimulatorBootLog=mock.Mock())
        patcher.start()
        self.addCleanup(patcher.stop)
        trial.OwnedSimulatorBootLog.return_value.finalize.return_value = {'collectorCleaned': True}
        return phases, output_calls

    def test_combined_owns_one_new_uuid_and_waits_at_most180_without_separate_boot(self):
        with tempfile.TemporaryDirectory() as directory:
            phases, calls = self.setup_trial(directory)
            trial.run_trial(ROOT, Path(directory) / 'result', combined=True)
            self.assertEqual(phases, [(['xcrun', 'simctl', 'bootstatus', NEW, '-b', '-d'], 180)])
            self.assertEqual(sum(c[2] == 'create' for c in calls), 1)
            trial.cleanup_simulator.assert_called_once_with(NEW, Path(directory) / 'result')
            result = json.loads((Path(directory) / 'result/comparison.json').read_text())
            self.assertTrue(result['officialBootstatusPassed'])
            self.assertEqual(result['uiTestsExecuted'], 0)

    def test_separate_preserves60_then180_and_matches_migration_verbosity(self):
        with tempfile.TemporaryDirectory() as directory:
            phases, _ = self.setup_trial(directory)
            trial.run_trial(ROOT, Path(directory) / 'result', combined=False)
            self.assertEqual(phases, [(['xcrun', 'simctl', 'boot', NEW], 60),
                (['xcrun', 'simctl', 'bootstatus', NEW, '-b', '-d'], 180)])

    def test_creation_returning_existing_uuid_cannot_boot_or_delete_it(self):
        with tempfile.TemporaryDirectory() as directory:
            phases, _ = self.setup_trial(directory, returned=EXISTING)
            with self.assertRaisesRegex(ValueError, 'existing'):
                trial.run_trial(ROOT, Path(directory) / 'result', combined=True)
            self.assertEqual(phases, [])
            trial.cleanup_simulator.assert_not_called()

    def test_invalid_creation_uuid_cannot_boot_or_cleanup_any_device(self):
        with tempfile.TemporaryDirectory() as directory:
            phases, _ = self.setup_trial(directory, returned='not-a-uuid')
            with self.assertRaises(ValueError):
                trial.run_trial(ROOT, Path(directory) / 'result', combined=True)
            self.assertEqual(phases, [])
            trial.cleanup_simulator.assert_not_called()

    def test_primary_timeout_survives_cleanup_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            original = subprocess.TimeoutExpired('owned bootstatus', 180)
            self.setup_trial(directory, failure=original, cleanup_failure=OSError('cleanup failed'))
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                trial.run_trial(ROOT, Path(directory) / 'result', combined=True)
            self.assertIs(caught.exception, original)
            trial.cleanup_simulator.assert_called_once()
            trial.OwnedSimulatorBootLog.return_value.finalize.assert_called_once()
            result = json.loads((Path(directory) / 'result/comparison.json').read_text())
            self.assertFalse(result['officialBootstatusPassed'])
            self.assertFalse(result['cleanupResolved'])

    def test_cleanup_failure_does_not_publish_bootstrap_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            self.setup_trial(directory, cleanup_failure=OSError('cleanup failed'))
            with self.assertRaises(OSError):
                trial.run_trial(ROOT, Path(directory) / 'result', combined=True)

    def test_collector_stop_failure_cannot_replace_primary_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            original = subprocess.TimeoutExpired('owned bootstatus', 180)
            self.setup_trial(directory, failure=original)
            trial.OwnedSimulatorBootLog.return_value.request_stop.side_effect = OSError('optional observer')
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                trial.run_trial(ROOT, Path(directory) / 'result', combined=True)
            self.assertIs(caught.exception, original)

    def test_receipt_failure_cannot_replace_primary_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            original = subprocess.TimeoutExpired('owned bootstatus', 180)
            self.setup_trial(directory, failure=original)
            writer = Path.write_text
            def fail_comparison(path, *args, **kwargs):
                if path.name == 'comparison.json':
                    raise OSError('full evidence volume')
                return writer(path, *args, **kwargs)
            with mock.patch.object(Path, 'write_text', fail_comparison):
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    trial.run_trial(ROOT, Path(directory) / 'result', combined=True)
            self.assertIs(caught.exception, original)


if __name__ == '__main__':
    unittest.main()
