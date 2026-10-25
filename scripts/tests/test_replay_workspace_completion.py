"""Real runner/aggregate CLI boundaries with synthetic native operations only."""
from contextlib import ExitStack, redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as runner


class WorkspaceCompletionBoundaryTests(unittest.TestCase):
    def run_case(self, mode):
        group = "help-max-en"
        device = "11111111-1111-4111-8111-111111111111"
        cleanup_error = OSError("synthetic workspace cleanup failure")
        seed_error = ValueError("synthetic invalid seed artifact")
        body_error = subprocess.CalledProcessError(65, ["synthetic", "test"])
        output_error = BrokenPipeError("synthetic final status output failure")
        publish_error = OSError("synthetic completed pending-file close failure")
        events, visible_during_cleanup, install_errors = [], [], []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            results = root / group
            workspace = root / "workspace"
            workspace.mkdir()
            container = root / "synthetic/Containers/Data/Application/app"

            def green(target, name):
                target.mkdir()
                tests = runner.TEST_GROUPS[name]
                for filename, value in {
                    "selection.json": {"group": name, "tests": tests},
                    "summary.json": {"totalTestCount": len(tests), "passedTests": len(tests), "failedTests": 0, "skippedTests": 0},
                    "test-process.json": {"launched": True, "exitCode": 0, "timedOut": False},
                    "ui-completion.json": {"group": name, "executedTests": len(tests), "result": "passed"},
                }.items():
                    (target / filename).write_text(json.dumps(value))

            for name in runner.TEST_GROUPS:
                if name != group or mode == "rerun":
                    green(root / name, name)
            old_receipt = (results / "ui-completion.json").read_bytes() if mode == "rerun" else None
            other_files = ({p.name: p.read_bytes() for p in results.iterdir() if p.name != "ui-completion.json"}
                           if mode == "rerun" else {})

            class Workspace:
                def __enter__(self):
                    events.append("workspace-enter")
                    return str(workspace)

                def __exit__(self, *args):
                    events.append("workspace-cleanup")
                    visible_during_cleanup.append((results / "ui-completion.json").exists())
                    if mode in ("cleanup-fail", "body-and-cleanup-fail", "seed-and-cleanup-fail"):
                        raise cleanup_error

            def output(command, timeout=60):
                if command[1:4] == ["simctl", "list", "runtimes"]:
                    return json.dumps({"runtimes": [{"identifier": "ios27", "version": "27.0"}]})
                if command[1:3] == ["simctl", "create"]:
                    return device
                if command[1:3] == ["simctl", "install"]:
                    events.append("app-install")
                    ready_after = 300 if mode == "install-slow" else 601 if mode == "install-timeout" else 0
                    if ready_after > timeout:
                        error = subprocess.TimeoutExpired(command, timeout, output=b"install still pending")
                        install_errors.append(error)
                        raise error
                    if mode == "install-error":
                        error = subprocess.CalledProcessError(9, command, output="synthetic install refusal")
                        install_errors.append(error)
                        raise error
                if command[1:3] == ["simctl", "get_app_container"]:
                    events.append("app-container")
                    return str(container)
                if command[1:5] == ["xcresulttool", "get", "test-results", "summary"]:
                    return json.dumps({"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0})
                return ""

            def phase(command, log, receipt, timeout, **kwargs):
                if command[-1] == "test":
                    events.append("ui-test")
                failed = mode == "body-and-cleanup-fail" and command[-1] == "test"
                receipt.write_text(json.dumps({"launched": True, "exitCode": 65 if failed else 0, "timedOut": False}))
                log.write_text("synthetic")
                if failed:
                    raise body_error
                return {}

            def cleanup(*args):
                events.append("simulator-cleanup")
                return True

            actual_print, actual_write = print, Path.write_text

            def status_print(*args, **kwargs):
                if args and str(args[0]).startswith("OFFLINE REPLAY UI PASS"):
                    events.append("status-output")
                    if mode == "output-fail":
                        raise output_error
                return actual_print(*args, **kwargs)

            def write(path, *args, **kwargs):
                value = actual_write(path, *args, **kwargs)
                if mode == "publish-fail" and path.name.startswith(".ui-completion-pending-"):
                    raise publish_error
                return value

            arguments = ["verify_offline_replay.py", "--group", group, "--seed-artifact", directory,
                         "--seed-manifest-sha256", "0" * 64, "--result-directory", str(results)]
            caught = None
            with ExitStack() as stack:
                stack.enter_context(patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}))
                stack.enter_context(patch.object(sys, "argv", arguments))
                stack.enter_context(patch.object(runner.tempfile, "TemporaryDirectory", return_value=Workspace()))
                observer = stack.enter_context(patch.object(runner, "OwnedSimulatorBootLog"))
                observer.return_value.finalize.return_value = {"collectorCleaned": True}
                for name, value in [("record_toolchain", {}), ("private_artifact", {"manifest": {}}),
                                    ("run_artifact", None), ("stage_sources", None), ("current_commit", "synthetic"),
                                    ("select_ui_destination", ("ios27", "iphone")),
                                    ("capture_simulator_bootstrap_failure", {})]:
                    stack.enter_context(patch.object(runner, name, return_value=value))
                stack.enter_context(patch.object(runner, "install_fixture", side_effect=lambda *args: events.append("fixture-install")))
                if mode == "seed-and-cleanup-fail":
                    stack.enter_context(patch.object(runner, "private_artifact", side_effect=seed_error))
                stack.enter_context(patch.object(runner, "output", side_effect=output))
                stack.enter_context(patch.object(runner.failure_observation, "simctl_output",
                                                side_effect=lambda command, *a, **k: output(command)))
                run = stack.enter_context(patch.object(runner, "run_owned_phase", side_effect=phase))
                stack.enter_context(patch.object(runner, "cleanup_simulator", side_effect=cleanup))
                stack.enter_context(patch.object(runner, "print", side_effect=status_print, create=True))
                stack.enter_context(patch.object(Path, "write_text", write))
                with redirect_stdout(io.StringIO()):
                    try:
                        runner.main()
                    except BaseException as error:
                        caught = error
            expected = {"cleanup-fail": cleanup_error, "body-and-cleanup-fail": body_error,
                        "seed-and-cleanup-fail": seed_error,
                        "output-fail": output_error, "publish-fail": publish_error,
                        "install-timeout": install_errors[0] if install_errors else None,
                        "install-error": install_errors[0] if install_errors else None}.get(mode)
            completion = results / "ui-completion.json"
            archived = list(results.glob("ui-completion.previous-*.json"))
            cli = subprocess.run([sys.executable, "-B", str(Path(runner.__file__)), "--verify-groups", str(root)],
                                 text=True, capture_output=True, timeout=10)
            public_pass = False
            with redirect_stdout(io.StringIO()):
                try:
                    runner.verify_group_results(root)
                    public_pass = True
                except (ValueError, FileNotFoundError):
                    pass
            first_failure = results / "first-failure-observation.json"
            cleanup_failure = results / "workspace-cleanup-failure.json"
            install_observation = results / "app-install-observation.json"
            return {"installObservation": json.loads(install_observation.read_text()) if install_observation.exists() else None,
                    "installErrorTimeout": getattr(caught, "timeout", None),
                    "installErrorOutput": getattr(caught, "output", None),
                    "firstFailureObservation": json.loads(first_failure.read_text()) if first_failure.exists() else None,
                    "workspaceCleanupFailure": json.loads(cleanup_failure.read_text()) if cleanup_failure.exists() else None,
                    "mode": mode, "events": events, "completionVisibleDuringWorkspaceCleanup": visible_during_cleanup,
                    "completionExists": completion.exists(), "publicAggregatePassed": public_pass,
                    "cliExitCode": cli.returncode, "cliPassPrinted": "FULL GATE PASS" in cli.stdout,
                    "originalErrorPreserved": (caught is expected if mode != "rerun" else isinstance(caught, FileExistsError)),
                    "errorType": type(caught).__name__ if caught else None,
                    "archivedReceiptPreserved": bool(archived) and old_receipt is not None and archived[0].read_bytes() == old_receipt,
                    "otherPriorFilesPreserved": all((results / name).read_bytes() == raw for name, raw in other_files.items()),
                    "ownedPhaseCalls": run.call_count}

    def assert_rejected(self, result):
        self.assertFalse(result["completionExists"], result)
        self.assertFalse(result["publicAggregatePassed"], result)
        self.assertNotEqual(result["cliExitCode"], 0, result)
        self.assertFalse(result["cliPassPrinted"], result)
        self.assertTrue(result["originalErrorPreserved"], result)

    def test_install_ready_at_virtual300_seconds_reaches_identity_fixture_and_ui(self):
        result = self.run_case("install-slow")
        self.assertTrue(result["completionExists"] and result["publicAggregatePassed"], result)
        self.assertEqual(result["installObservation"]["timeoutSeconds"], 600)
        self.assertTrue(result["installObservation"]["returnedNormally"])
        stages = ["app-install", "app-container", "fixture-install", "ui-test"]
        self.assertEqual([name for name in result["events"] if name in stages], stages)

    def test_install_past600_keeps_original_timeout_and_blocks_identity_fixture_ui(self):
        result = self.run_case("install-timeout")
        self.assert_rejected(result)
        self.assertEqual(result["installErrorTimeout"], 600)
        self.assertEqual(result["installErrorOutput"], b"install still pending")
        self.assertEqual(result["installObservation"]["timeoutSeconds"], 600)
        for stage in ("app-container", "fixture-install", "ui-test"):
            self.assertNotIn(stage, result["events"])

    def test_install_nonzero_keeps_original_error_and_blocks_identity_fixture_ui(self):
        result = self.run_case("install-error")
        self.assert_rejected(result)
        self.assertEqual(result["errorType"], "CalledProcessError")
        for stage in ("app-container", "fixture-install", "ui-test"):
            self.assertNotIn(stage, result["events"])

    def test_workspace_cleanup_failure_cannot_publish_completion_or_pass_cli(self):
        self.assert_rejected(self.run_case("cleanup-fail"))

    def test_normal_completion_is_published_after_workspace_cleanup_and_passes_cli(self):
        result = self.run_case("normal")
        self.assertTrue(result["completionExists"], result)
        self.assertEqual(result["completionVisibleDuringWorkspaceCleanup"], [False])
        self.assertLess(result["events"].index("workspace-cleanup"), result["events"].index("status-output"))
        self.assertEqual(result["cliExitCode"], 0, result)
        self.assertTrue(result["publicAggregatePassed"] and result["cliPassPrinted"], result)

    def test_workspace_cleanup_error_preserves_original_body_exception(self):
        self.assert_rejected(self.run_case("body-and-cleanup-fail"))

    def test_refused_rerun_archives_old_success_and_cli_rejects(self):
        result = self.run_case("rerun")
        self.assert_rejected(result)
        self.assertTrue(result["archivedReceiptPreserved"] and result["otherPriorFilesPreserved"], result)
        self.assertEqual(result["ownedPhaseCalls"], 0, result)

    def test_status_output_failure_cannot_leave_success_completion(self):
        self.assert_rejected(self.run_case("output-fail"))

    def test_pending_receipt_write_failure_cannot_publish_valid_json_as_success(self):
        self.assert_rejected(self.run_case("publish-fail"))


    def test_seed_failure_stays_first_when_workspace_cleanup_also_fails(self):
        result = self.run_case("seed-and-cleanup-fail")
        self.assert_rejected(result)
        self.assertEqual(result["ownedPhaseCalls"], 0, result)
        self.assertEqual(result["firstFailureObservation"]["errorType"], "ValueError", result)
        self.assertEqual(result["firstFailureObservation"]["phase"], "workspace-body", result)
        self.assertEqual(result["workspaceCleanupFailure"]["errorType"], "OSError", result)


if __name__ == "__main__":
    unittest.main()
