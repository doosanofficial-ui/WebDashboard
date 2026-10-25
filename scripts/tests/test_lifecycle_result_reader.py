import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import verify_offline_replay as replay
import verify_ios_lifecycle as lifecycle


class ResultReaderTests(unittest.TestCase):
    def trial(self, payload, error=None):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            bundle = results / 'saved.xcresult'
            def execute(command, log, receipt, timeout, **options):
                log.write_text(payload)
                if error is not None:
                    raise error
            with mock.patch.object(replay, 'run_owned_phase', side_effect=execute) as owner:
                value = lifecycle.read_test_summary_output(bundle, results)
            return value, owner.call_args, bundle, results

    def test_summary_command_uses180_seconds_file_output_and_owned_group_cleanup(self):
        payload = {'totalTestCount': 92, 'passedTests': 92, 'failedTests': 0, 'skippedTests': 0, 'result': 'Passed'}
        value, call, bundle, results = self.trial(json.dumps(payload))
        self.assertEqual(json.loads(value), payload)
        self.assertEqual(call.args[0], ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)])
        self.assertEqual(call.args[1:4], (results / 'result-read-command.log', results / 'result-read-process.json', 180))
        self.assertEqual(call.kwargs, {'ensure_group_cleanup': True})

    def test_nonzero_reader_cannot_pass_even_if_output_counts_are_green(self):
        original = subprocess.CalledProcessError(65, ['synthetic-result-reader'])
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.trial('{"totalTestCount":92,"passedTests":92,"failedTests":0,"skippedTests":0}', original)
        self.assertIs(caught.exception, original)

    def test_timeout_cannot_pass_even_if_partial_output_looks_complete(self):
        original = subprocess.TimeoutExpired(['synthetic-result-reader'], 60)
        with self.assertRaises(subprocess.TimeoutExpired) as caught:
            self.trial('{"totalTestCount":92,"passedTests":92,"failedTests":0,"skippedTests":0}', original)
        self.assertIs(caught.exception, original)

    def test_invalid_json_cannot_be_replaced_with_log_counts(self):
        with self.assertRaises(json.JSONDecodeError):
            json.loads(self.trial('TEST SUCCEEDED; Executed92 tests, zero failures')[0])

    def test_existing_command_evidence_is_preserved_before_any_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            for filename in ['result-read-command.log', 'result-read-process.json']:
                with self.subTest(filename=filename):
                    path = results / filename
                    path.write_text('preserved evidence')
                    with mock.patch.object(replay, 'run_owned_phase') as owner:
                        with self.assertRaises(FileExistsError):
                            lifecycle.read_test_summary_output(results / 'saved.xcresult', results)
                    owner.assert_not_called()
                    self.assertEqual(path.read_text(), 'preserved evidence')
                    path.unlink()


if __name__ == '__main__':
    unittest.main()
