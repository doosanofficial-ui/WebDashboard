import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import verify_ios_lifecycle as lifecycle
import verify_offline_replay as replay

GREEN = {"totalTestCount":92,"passedTests":92,"failedTests":0,"skippedTests":0,"result":"Passed"}

class SummaryBudgetTests(unittest.TestCase):
    """Virtual elapsed time models a slow reader; no Apple tool or CI is invoked."""
    def test_valid_result_available_at90_seconds_can_finish_in_the_finite_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            results=Path(directory)
            def virtual_reader(command, log, receipt, timeout, **options):
                if timeout < 90:
                    raise subprocess.TimeoutExpired(command, timeout)
                log.write_text(json.dumps(GREEN))
            with mock.patch.object(replay, 'run_owned_phase', side_effect=virtual_reader):
                try:
                    value=lifecycle.read_test_summary_output(results/'saved.xcresult',results)
                except subprocess.TimeoutExpired:
                    self.fail('Valid structured result at virtual90seconds was cut off by the old60second budget')
            summary=json.loads(value)
            lifecycle.verify_summary(summary,92)

    def test_reader_remains_bounded_at180_even_with_complete_green_partial_output(self):
        with tempfile.TemporaryDirectory() as directory:
            results=Path(directory)
            failures=[]
            def virtual_reader(command,log,receipt,timeout,**options):
                log.write_text(json.dumps(GREEN))
                if timeout>=181:
                    return
                error=subprocess.TimeoutExpired(command,timeout)
                failures.append(error)
                raise error
            with mock.patch.object(replay,'run_owned_phase',side_effect=virtual_reader):
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    lifecycle.read_test_summary_output(results/'saved.xcresult',results)
            self.assertIs(caught.exception,failures[0])
            self.assertEqual(caught.exception.timeout,180)
