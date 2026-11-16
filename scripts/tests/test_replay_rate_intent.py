import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/verify_replay_rate_intent.py"
FIXTURES = ROOT / "scripts/fixtures/replay_rate_intent"


class ReplayRateIntentTests(unittest.TestCase):
    def run_capture(self, name, optimized=False):
        args = [sys.executable] + (["-O"] if optimized else [])
        return subprocess.run(args + [str(SCRIPT), str(FIXTURES / (name + "-ui.txt")),
                              str(FIXTURES / (name + "-rates.txt"))], capture_output=True, text=True, timeout=10)

    def test_actual_wrong_picker_value_is_not_hidden_by_controller_acceptance(self):
        result = self.run_capture("failure")
        self.assertEqual(result.returncode, 1, result.stderr)
        body = json.loads(result.stdout)
        self.assertEqual(body["result"], "FAIL")
        self.assertEqual((body["tapCount"], body["correctCount"]), (5, 4))
        last = body["observations"][-1]
        self.assertEqual(last["expectedRate"], 2.0)
        self.assertEqual(last["actualPickerRequests"][-1][1], 0.5)
        self.assertTrue(body["controllerAcceptedAll"])

    def test_actual_successful_capture_matches_all_ten_public_taps(self):
        result = self.run_capture("pass")
        self.assertEqual(result.returncode, 0, result.stderr)
        body = json.loads(result.stdout)
        self.assertEqual((body["tapCount"], body["correctCount"], body["boundaryRequests"]), (10, 10, 9))

    def test_optimized_python_cannot_turn_the_real_failure_green(self):
        result = self.run_capture("failure", optimized=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["correctCount"], 4)

    def run_modified_rates(self, rates, optimized=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rates.txt"
            path.write_text(rates)
            args = [sys.executable] + (["-O"] if optimized else [])
            result = subprocess.run(args + [str(SCRIPT), str(FIXTURES / "pass-ui.txt"), str(path)],
                                    capture_output=True, text=True, timeout=10)
            self.assertNotIn(directory, result.stdout)
            return result, json.loads(result.stdout)

    def test_missing_admission_is_an_error_not_a_lost_callback_diagnosis(self):
        rates = "\n".join(line for line in (FIXTURES / "pass-rates.txt").read_text().splitlines()
                          if "stage=armed" not in line)
        result, body = self.run_modified_rates(rates, optimized=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(body["error"], {"code": "admission_missing", "field": "rate_log"})

    def test_incomplete_boundary_receipt_fails_closed_under_optimization(self):
        rates = (FIXTURES / "pass-rates.txt").read_text()
        removed = False
        lines = []
        for line in rates.splitlines():
            if not removed and "stage=controller.received" in line:
                removed = True
            else:
                lines.append(line)
        self.assertTrue(removed)
        result, body = self.run_modified_rates("\n".join(lines), optimized=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(body["error"]["code"], "boundary_sequence_incomplete")

    def test_real_model_rejection_is_preserved_in_actual_response_body(self):
        original = (FIXTURES / "pass-rates.txt").read_text()
        changed = original.replace("accepted=true", "accepted=false", 1)
        self.assertNotEqual(original, changed)
        result, body = self.run_modified_rates(changed)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(body["controllerAcceptedAll"])
        self.assertEqual(body["receiverErrors"][0], {"id": 1, "reason": "controller_not_accepted"})

    def test_missing_file_returns_safe_structured_error(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "not-present.txt"
            result = subprocess.run([sys.executable, str(SCRIPT), str(missing), str(FIXTURES / "pass-rates.txt")],
                                    capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error"], {"code": "input_unavailable", "field": "ui_log"})
        self.assertNotIn(directory, result.stdout)
        self.assertNotIn("Traceback", result.stderr)

    def test_large_noncontiguous_ids_are_rejected_without_range_allocation(self):
        rates = (FIXTURES / "pass-rates.txt").read_text().replace("id=1 ", "id=1000000000 ")
        result, body = self.run_modified_rates(rates)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(body["error"]["code"], "request_receipts_missing")

    def test_different_capture_clocks_are_not_misdiagnosed_as_wrong_ui_input(self):
        rates = (FIXTURES / "pass-rates.txt").read_text().replace("2026-11-16", "2026-11-15")
        result, body = self.run_modified_rates(rates)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(body["error"]["code"], "uncorrelated_rate_requests")


if __name__ == "__main__":
    unittest.main()
