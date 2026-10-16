"""Failure-path contracts with synthetic commands, time, and result bundles only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import ExitStack
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as runner
import failure_observation
from verify_ios_lifecycle import output as actual_output


class SharedFailureBudgetTests(unittest.TestCase):
    def test_boot_observer_and_followup_probes_share_one_deadline(self):
        device = "11111111-1111-4111-8111-111111111111"
        primary = subprocess.TimeoutExpired(["xcrun", "simctl", "bootstatus", device, "-b"], 180)
        clock = [100.0]
        probes = []

        def observe(*args, **kwargs):
            clock[0] += 17

        def phase(command, log, receipt, timeout, **kwargs):
            if command[1:3] == ["simctl", "boot"]:
                return {}
            if "bootstatus" in command:
                raise primary
            probes.append((command, timeout))
            clock[0] += timeout
            raise subprocess.TimeoutExpired(command, timeout)

        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}), \
                patch.object(runner.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(runner, "observe_first_failure", side_effect=observe), \
                patch.object(runner, "run_owned_phase", side_effect=phase), \
                patch.object(runner, "owned_posterboard_signatures", return_value={"reports": []}) as scan:
            results = Path(directory)
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                runner.prepare_simulator(device, results)
            self.assertIs(caught.exception, primary)
            self.assertEqual(len(probes), 1, "Expired diagnostics must not delay owned cleanup with fresh budgets")
            self.assertEqual(probes[0][1], 3)
            scan.assert_not_called()
            evidence = json.loads((results / "simulator-bootstrap-diagnostics.json").read_text())
            self.assertEqual(evidence["diagnosticDeadlineMonotonic"], 120)
            self.assertEqual([entry["phase"] for entry in evidence["phases"]], ["state", "logs", "screenshot"])
            self.assertTrue(all(entry["notRunReason"] == "diagnostic-deadline-reached"
                                for entry in evidence["phases"][1:]))

    def test_exhausted_budget_records_unavailable_evidence_without_fresh_probes(self):
        device = "11111111-1111-4111-8111-111111111111"
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(runner, "run_owned_phase") as phase, \
                patch.object(runner, "owned_posterboard_signatures") as scan:
            evidence = runner.capture_simulator_bootstrap_failure(
                device, Path(directory), deadline=120, clock=lambda: 121)
        phase.assert_not_called()
        scan.assert_not_called()
        self.assertFalse(evidence["screenshotCaptured"])
        self.assertTrue(all(entry["notRunReason"] == "diagnostic-deadline-reached"
                            for entry in evidence["phases"]))
        self.assertTrue(evidence["posterBoard"]["metadataScanIncomplete"])

    def test_prompt_probes_receive_only_remaining_budget(self):
        device = "11111111-1111-4111-8111-111111111111"
        clock = [100.0]
        budgets = []

        def phase(command, log, receipt, timeout, **kwargs):
            budgets.append(timeout)
            clock[0] += 8 if len(budgets) < 3 else 1

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(runner, "run_owned_phase", side_effect=phase), \
                patch.object(runner, "owned_posterboard_signatures", return_value={"reports": []}) as scan:
            evidence = runner.capture_simulator_bootstrap_failure(
                device, Path(directory), deadline=120, clock=lambda: clock[0])
        self.assertEqual(budgets, [10, 10, 4])
        self.assertEqual(clock[0], 117)
        self.assertEqual(scan.call_args.kwargs["deadline"], 120)
        self.assertFalse(evidence["screenshotCaptured"], "A successful command alone cannot invent a PNG")

    def test_first_failure_worker_uses_remaining_budget_and_latches_once(self):
        device = "11111111-1111-4111-8111-111111111111"
        calls = []

        def phase(command, log, receipt, timeout, **kwargs):
            calls.append((command, timeout))
            receipt.write_text(json.dumps({"exitCode": 0, "groupExistsAfterCleanup": False}))
            return {"exitCode": 0}

        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
            results = Path(directory)
            failure_observation.observe_first_failure(
                OSError("primary"), results, device, "simulator-bootstatus",
                run_phase=phase, deadline=107, clock=lambda: 100)
            original = (results / "first-failure-observation.json").read_bytes()
            failure_observation.observe_first_failure(
                RuntimeError("cleanup"), results, device, "cleanup",
                run_phase=phase, deadline=200, clock=lambda: 100)
            self.assertEqual((results / "first-failure-observation.json").read_bytes(), original)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1], 7)
        self.assertEqual(float(calls[0][0][-1]), 107)

    def test_expired_observer_budget_latches_failure_without_launching_worker(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}), \
                patch.object(runner, "run_owned_phase") as phase:
            results = Path(directory)
            failure_observation.observe_first_failure(
                OSError("primary"), results, None, "boot", run_phase=phase,
                deadline=120, clock=lambda: 120)
            self.assertEqual(json.loads((results / "first-failure-observation.json").read_text())["phase"], "boot")
            self.assertEqual(json.loads((results / "failure-diagnostic-status.json").read_text())["skipped"],
                             "diagnostic-deadline-reached")
        phase.assert_not_called()


class FailedNativeResultTests(unittest.TestCase):
    def failed_run(self, summary_error=None, export_error=None):
        """Replay exit65 at the actual runner boundary; no native process is started."""
        device = "11111111-1111-4111-8111-111111111111"
        primary = subprocess.CalledProcessError(65, ["xcodebuild", "test"])
        expected = {"totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0}
        events = []
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / "results"
            container = Path(directory) / "synthetic/Containers/Data/Application/app"

            def command_output(command, timeout=60):
                if command[1:4] == ["simctl", "list", "runtimes"]:
                    return json.dumps({"runtimes": [{"identifier": "ios27", "version": "27.0"}]})
                if command[1:3] == ["simctl", "create"]:
                    return device
                if command[1:3] == ["simctl", "get_app_container"]:
                    return str(container)
                if command[1:5] == ["xcresulttool", "get", "test-results", "summary"]:
                    events.append("summary")
                    if summary_error:
                        raise summary_error
                    return json.dumps(expected)
                if command[1:3] == ["xcresulttool", "export"]:
                    events.append("attachments")
                    if export_error:
                        raise export_error
                    destination = Path(command[command.index("--output-path") + 1])
                    destination.mkdir()
                    (destination / "synthetic-failure.txt").write_text("Synthetic attachment; not screenshot evidence")
                return ""

            def phase(command, *args, **kwargs):
                if Path(command[1]).name == "bounded_command_output.py":
                    log, receipt, timeout = args
                    self.assertTrue(kwargs["ensure_group_cleanup"])
                    self.assertEqual(kwargs["group_cleanup_timeout"], 1)
                    recorded = {"launched": True, "groupExistsAfterCleanup": False}
                    receipt.write_text(json.dumps(recorded))
                    value = command_output(command[3:], timeout)
                    log.write_text(value)
                    return recorded
                if command[-1] == "test":
                    bundle = Path(command[command.index("-resultBundlePath") + 1])
                    bundle.mkdir()
                    (results / "test.log").write_text("Synthetic replay: Failed to get matching snapshots: Timed out while evaluating UI query")
                    events.append("test-failed")
                    raise primary
                return {}

            arguments = ["verify_offline_replay.py", "--group", "help-max-en", "--seed-artifact", directory,
                         "--seed-manifest-sha256", "0" * 64, "--result-directory", str(results)]
            with ExitStack() as stack:
                stack.enter_context(patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}))
                stack.enter_context(patch.object(sys, "argv", arguments))
                observer = stack.enter_context(patch.object(runner, "OwnedSimulatorBootLog"))
                observer.return_value.finalize.return_value = {"collectorCleaned": True}
                stack.enter_context(patch.object(runner, "record_toolchain", return_value={}))
                stack.enter_context(patch.object(runner, "private_artifact", return_value={"manifest": {}}))
                stack.enter_context(patch.object(runner, "run_artifact"))
                stack.enter_context(patch.object(runner, "stage_sources"))
                stack.enter_context(patch.object(runner, "current_commit", return_value="synthetic"))
                stack.enter_context(patch.object(runner, "select_ui_destination", return_value=("ios27", "iphone")))
                stack.enter_context(patch.object(runner, "install_fixture"))
                stack.enter_context(patch.object(runner, "output", side_effect=command_output))
                stack.enter_context(patch.object(runner.failure_observation, "simctl_output",
                                                side_effect=lambda command, *args, **kwargs: command_output(command)))
                stack.enter_context(patch.object(runner, "run_owned_phase", side_effect=phase))
                stack.enter_context(patch.object(runner, "capture_simulator_bootstrap_failure",
                                                side_effect=lambda *args, **kwargs: events.append("capture")))
                stack.enter_context(patch.object(runner, "cleanup_simulator",
                                                side_effect=lambda *args, **kwargs: events.append("cleanup") or True))
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    runner.main()
            self.assertIs(caught.exception, primary, "Artifact failures must not replace the original test exit65")
            return {"events": events,
                    "summary": json.loads((results / "failed-summary.json").read_text()) if (results / "failed-summary.json").exists() else None,
                    "normalSummaryExists": (results / "summary.json").exists(),
                    "collection": json.loads((results / "test-result-collection.json").read_text()) if (results / "test-result-collection.json").exists() else None,
                    "firstFailure": json.loads((results / "first-failure-observation.json").read_text()),
                    "attachmentExists": (results / "screenshots/synthetic-failure.txt").exists()}

    def test_failed_test_retains_native_counts_and_attachments_before_cleanup(self):
        result = self.failed_run()
        self.assertEqual(result["summary"], {"totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0})
        self.assertTrue(result["attachmentExists"])
        self.assertFalse(result["normalSummaryExists"])
        self.assertEqual(result["events"], ["test-failed", "summary", "attachments", "capture", "cleanup"])
        self.assertEqual(result["firstFailure"]["phase"], "ui-test")

    def test_summary_parse_error_still_attempts_attachments_and_preserves_exit65(self):
        result = self.failed_run(summary_error=ValueError("synthetic summary parse error"))
        self.assertIsNone(result["summary"])
        self.assertTrue(result["attachmentExists"])
        self.assertEqual(result["collection"]["phases"][0]["errorType"], "ValueError")
        self.assertEqual(result["events"][-1], "cleanup")

    def test_attachment_timeout_keeps_failed_native_counts_and_original_exit65(self):
        result = self.failed_run(export_error=subprocess.TimeoutExpired(["xcrun", "xcresulttool"], 10))
        self.assertEqual(result["summary"]["failedTests"], 1)
        self.assertFalse(result["attachmentExists"])
        self.assertEqual(result["collection"]["phases"][1]["errorType"], "TimeoutExpired")
        self.assertEqual(result["events"][-1], "cleanup")

    def test_native_result_export_does_not_reset_the_shared_deadline(self):
        clock = [100.0]
        calls = []

        def phase(command, log, receipt, timeout, **kwargs):
            calls.append((command, timeout))
            clock[0] += timeout
            receipt.write_text(json.dumps({"launched": True, "groupExistsAfterCleanup": False}))
            raise subprocess.TimeoutExpired(command, timeout)

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(runner, "run_owned_phase", side_effect=phase):
            results = Path(directory)
            bundle = results / "synthetic.xcresult"
            bundle.mkdir()
            evidence = runner.collect_failed_test_results(bundle, results, deadline=103, clock=lambda: clock[0])
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1], 3)
        self.assertEqual(evidence["phases"][1]["notRunReason"], "diagnostic-deadline-reached")

    def test_missing_native_result_is_unavailable_and_never_fabricated(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(runner, "run_owned_phase") as phase:
            results = Path(directory)
            evidence = runner.collect_failed_test_results(results / "missing.xcresult", results,
                                                         deadline=120, clock=lambda: 100)
            self.assertFalse((results / "summary.json").exists())
            self.assertFalse((results / "screenshots").exists())
        phase.assert_not_called()
        self.assertTrue(all(entry["notRunReason"] == "xcresult-unavailable" for entry in evidence["phases"]))


class OwnedResultDescendantTests(unittest.TestCase):
    def test_unconfirmed_group_cannot_promote_collected_output(self):
        def phase(command, log, receipt, timeout, **kwargs):
            log.write_text('{}')
            return {"launched": True, "groupExistsAfterCleanup": True}

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(runner, "run_owned_phase", side_effect=phase):
            root = Path(directory)
            bundle = root / "Synthetic.xcresult"
            bundle.mkdir()
            collected = runner.collect_failed_test_results(bundle, root, time.monotonic() + 1)
            self.assertFalse((root / "failed-summary.json").exists())
        self.assertTrue(all(not entry["success"] and not entry["groupCleanupConfirmed"]
                            and entry["evidenceUnavailableReason"] == "owned-group-cleanup-unconfirmed"
                            for entry in collected["phases"]))

    def test_real_output_is_capped_before_parsing(self):
        actual_phase = runner.run_owned_phase

        def phase(command, *args, **kwargs):
            index = command.index("xcrun")
            code = ("import sys;sys.stdout.write('x'*" + str(runner.FAILED_RESULT_OUTPUT_LIMIT_BYTES + 1000) + ")"
                    if "summary" in command[index:] else "print('{}')")
            return actual_phase(command[:index] + [sys.executable, "-B", "-c", code], *args, **kwargs)

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(runner, "run_owned_phase", side_effect=phase):
            root = Path(directory)
            bundle = root / "Synthetic.xcresult"
            bundle.mkdir()
            collected = runner.collect_failed_test_results(bundle, root, time.monotonic() + 3)
            first = collected["phases"][0]
            self.assertEqual((root / first["stdoutLog"]).stat().st_size, runner.FAILED_RESULT_OUTPUT_LIMIT_BYTES)
            self.assertFalse((root / "failed-summary.json").exists())
        self.assertEqual(first["errorType"], "CalledProcessError")
        self.assertFalse(first["success"])
        self.assertTrue(first["groupCleanupConfirmed"])

    def descendant_trial(self, mode):
        """Use real host Python families and actual command helpers, never native tools."""
        parent_code = """import json, pathlib, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
child = subprocess.Popen([sys.executable, '-B', '-c', sys.argv[3], str(root)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
(root / 'owned-child.json').write_text(json.dumps({'pid': child.pid}))
until = time.monotonic() + 2
while not (root / 'child-ready').exists() and time.monotonic() < until:
    time.sleep(0.01)
if sys.argv[2] == 'timeout':
    time.sleep(5)
else:
    print('{}', flush=True)
"""
        child_code = """import pathlib, sys, time
root = pathlib.Path(sys.argv[1])
(root / 'child-ready').write_text('ready')
until = time.monotonic() + 5
while time.monotonic() < until:
    if (root / 'release-child').exists():
        (root / 'late-attachment').write_text('late write')
        break
    time.sleep(0.01)
"""
        actual_phase = runner.run_owned_phase
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / "Synthetic.xcresult"
            bundle.mkdir()

            def replace_native(command):
                index = command.index("xcrun")
                native = command[index:]
                surrogate = ([sys.executable, "-B", "-c", parent_code, str(root), mode, child_code]
                             if "summary" in native else [sys.executable, "-B", "-c", "print('{}')"])
                return command[:index] + surrogate

            def output(command, timeout):
                return actual_output(replace_native(command), timeout)

            def phase(command, *args, **kwargs):
                return actual_phase(replace_native(command), *args, **kwargs)

            child_pid = None
            try:
                with patch.object(runner, "output", side_effect=output), \
                        patch.object(runner, "run_owned_phase", side_effect=phase):
                    receipt = runner.collect_failed_test_results(
                        bundle, root, time.monotonic() + (0.5 if mode == "timeout" else 3))
                child_pid = json.loads((root / "owned-child.json").read_text())["pid"]
                (root / "release-child").write_text("release after collector return")
                until = time.monotonic() + 0.3
                while not (root / "late-attachment").exists() and time.monotonic() < until:
                    time.sleep(0.01)
                self.assertFalse((root / "late-attachment").exists(), "A descendant must not write after the collector returns")
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
                first = receipt["phases"][0]
                self.assertTrue(first["groupCleanupConfirmed"])
                self.assertFalse(first["groupExistsAfterCleanup"])
                if mode == "timeout":
                    self.assertEqual(first["errorType"], "TimeoutExpired")
                else:
                    self.assertTrue(first["success"])
            finally:
                # The red version has no owned group. Release its one known child
                # to finish naturally; never signal the test runner's process group.
                (root / "release-child").write_text("finish synthetic child")
                if child_pid is None and (root / "owned-child.json").exists():
                    child_pid = json.loads((root / "owned-child.json").read_text())["pid"]
                until = time.monotonic() + 2
                while child_pid is not None and time.monotonic() < until:
                    try:
                        os.kill(child_pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.01)
                else:
                    if child_pid is not None:
                        raise AssertionError("Owned synthetic child cleanup was not confirmed")

    def test_timeout_stops_descendants_before_collector_returns(self):
        self.descendant_trial("timeout")

    def test_parent_exit_stops_descendants_before_collector_returns(self):
        self.descendant_trial("leader-exit")


if __name__ == "__main__":
    unittest.main()
