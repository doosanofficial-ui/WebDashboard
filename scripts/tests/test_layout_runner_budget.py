"""Execute the real runner selection/timeout handoff with every native call stubbed."""
import ast
from contextlib import ExitStack, nullcontext, redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify_offline_replay as runner
from test_native_ui_scheduling import job_block, job_setting


def workflow_timeout(block, group):
    value = job_setting(block, "timeout-minutes").split("#", 1)[0].strip()
    if value.isdecimal():
        return int(value)
    if not (value.startswith("${{") and value.endswith("}}")):
        raise ValueError("Unsupported workflow timeout")
    expression = value[3:-2].replace("matrix.group", "group").replace("&&", " and ").replace("||", " or ").strip()
    tree = ast.parse(expression, mode="eval")
    allowed = (ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.Compare, ast.Eq,
               ast.Name, ast.Load, ast.Constant)
    if any(not isinstance(node, allowed) for node in ast.walk(tree)):
        raise ValueError("Unsupported workflow timeout expression")
    return eval(compile(tree, "<workflow-timeout>", "eval"), {"__builtins__": {}}, {"group": group})


class LayoutRunnerBudgetTests(unittest.TestCase):
    layout_tests = [
        "TelemetryUITests/DashboardEditingUITests/testSelectedCardKeepsConfigurationAvailableOnDemand",
        "TelemetryUITests/DashboardEditingUITests/testMoveReleaseUndoRedoAndReentryPreserveNeighbor",
        "TelemetryUITests/DashboardEditingUITests/testResizeReleaseUndoPreserveNeighbor",
        "TelemetryUITests/DashboardEditingUITests/testOverlappingResizeKeepsSelectedHandleUsableForNextResize",
        "TelemetryUITests/DashboardEditingUITests/testLandscapeMoveUsesCurrentMeasuredGeometry",
        "TelemetryUITests/UIClarityUITests/testSyntheticDemoNeverClaimsLiveVehicleAcquisition",
        "TelemetryUITests/UIClarityUITests/testReplayUnknownFreshnessDoesNotBecomeProvenStale",
        "TelemetryUITests/UIClarityUITests/testSelectedSOCProfileIsVisibleBeforeGenericUnavailableSignals",
        "TelemetryUITests/UIClarityUITests/testRecordedTimeAccessibilityAtLargeTextAndLandscape",
        "TelemetryUITests/UIClarityUITests/testSingleInstantRecordingExplainsUnavailableTimeNavigation",
        "TelemetryUITests/TelemetryUITests/testMeasurementExportControlIsVisible",
        "TelemetryUITests/TelemetryUITests/testMeasurementCSVExportControlIsVisible",
        "TelemetryUITests/SmallViewportUIRegression/testSmallViewportLiveAndEditorReachability",
        "TelemetryUITests/SmallViewportStatusUIRegression/testStatusAndEditingHelpRemainAccessibleAtMaximumText",
    ]

    def run_selection(self, selection, container_error=None):
        calls = []
        container_calls = []
        primary = container_error or subprocess.CalledProcessError(65, ["xcodebuild", "synthetic-ui-test"])
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            root = Path(directory)
            results = root / "results"
            device = "11111111-1111-4111-8111-111111111111"

            def output(command, timeout=60):
                if command[1:4] == ["simctl", "list", "runtimes"]:
                    return json.dumps({"runtimes": [{"identifier": "ios27", "version": "27.0"}]})
                if command[1:3] == ["simctl", "create"]:
                    return device
                if command[1:3] == ["simctl", "get_app_container"]:
                    return str(root / "Containers/Data/Application/synthetic")
                return ""

            def phase(command, log, receipt, timeout, **kwargs):
                calls.append((command, log.name, timeout))
                if log.name == "test.log":
                    raise primary
                return {}

            def container_output(command, results, phase, timeout):
                container_calls.append((command, phase, timeout))
                if container_error is not None:
                    raise container_error
                return output(command)

            stack.enter_context(patch.object(sys, "argv", ["verify_offline_replay.py", *selection,
                "--seed-artifact", directory, "--seed-manifest-sha256", "0" * 64,
                "--result-directory", str(results)]))
            boundaries = {}
            for name in ("run_artifact", "stage_sources", "prepare_simulator", "install_fixture",
                         "observe_first_failure", "collect_failed_test_results", "capture_simulator_bootstrap_failure"):
                boundaries[name] = stack.enter_context(patch.object(runner, name))
            observer = stack.enter_context(patch.object(runner, "OwnedSimulatorBootLog"))
            observer.return_value.finalize.return_value = {"collectorCleaned": True}
            stack.enter_context(patch.object(runner, "cleanup_simulator", return_value=True))
            stack.enter_context(patch.object(runner, "record_toolchain", return_value={}))
            stack.enter_context(patch.object(runner, "private_artifact", return_value={"manifest": {}}))
            stack.enter_context(patch.object(runner, "current_commit", return_value="synthetic"))
            stack.enter_context(patch.object(runner, "select_ui_destination", return_value=("ios27", "iphone")))
            stack.enter_context(patch.object(runner, "output", side_effect=output))
            stack.enter_context(patch.object(runner.failure_observation, "simctl_output",
                side_effect=container_output))
            stack.enter_context(patch.object(runner, "run_owned_phase", side_effect=phase))
            stack.enter_context(patch.object(runner.export_fixture, "instrument_export_sources", return_value={}))
            stack.enter_context(patch.object(runner.export_audit, "install_marker"))
            stack.enter_context(patch.object(runner.export_audit, "RunnerHeartbeat", side_effect=lambda *args: nullcontext()))
            stack.enter_context(patch.object(runner.help_sources, "begin_capture", return_value={}))
            stack.enter_context(patch.object(runner.help_provenance, "prepare_run", return_value={
                "productsBefore": {"application": {"path": "Synthetic.app"}},
                "xctestrun": "Synthetic.xctestrun", "simulatorUUID": device}))
            # Product bytes are an external fixture; keep the actual test command builder.
            stack.enter_context(patch.object(runner.help_provenance, "_unchanged_products"))
            with redirect_stdout(io.StringIO()), self.assertRaises(type(primary)) as caught:
                runner.main()
            self.assertIs(caught.exception, primary, "Extra budget must not turn a native assertion failure into success")
            selection_file = results / "selection.json"
            selected = json.loads(selection_file.read_text()) if selection_file.exists() else None
            fixture = boundaries["install_fixture"]
            details = {"containerCalls": container_calls, "fixtureCalls": fixture.call_count,
                "fixtureDestination": str(fixture.call_args.args[1]) if fixture.call_args else None,
                "expectedFixtureDestination": str(root / "Containers/Data/Application/synthetic/Library/Application Support/Telemetry")}
        ui = next((call for call in calls if call[1] == "test.log"), None)
        self.assertEqual(next(call[2] for call in calls if call[1] == "build.log"), 600)
        return ui, selected, details

    def test_actual_layout_command_gets_1800_seconds_and_other_selections_keep_1200(self):
        cases = [(["--group", "layout"], 1800, 14)]
        cases += [(["--group", group], 1200, count) for group, count in
                  [("replay", 10), ("replay-route", 1), ("help", 4), ("help-max-en", 1), ("help-max-ko", 1)]]
        cases += [([], 1200, 8), (["--se-viewport"], 1200, 2)]
        cases += [(["--only-test", name], 1200, count) for name, count in
                  [("background-export-lifecycle", 1), ("active-slider-drag", 1), ("ui-clarity", 1),
                   ("single-instant", 1), ("large-text", 1), ("recorded-history", 1),
                   ("recorded-route", 1), ("native-save-reentry", 2), ("native-export-dismissal", 1), ("help-capture", 2)]]
        for selection, seconds, count in cases:
            with self.subTest(selection=selection):
                (command, _, timeout), selected, _ = self.run_selection(selection)
                self.assertEqual(timeout, seconds)
                selectors = [item for item in command if item.startswith("-only-testing:")]
                self.assertEqual(len(selectors), count)
                if selection == ["--group", "layout"]:
                    self.assertEqual(selected, {"group": "layout", "tests": self.layout_tests})
                    self.assertEqual(selectors, ["-only-testing:" + test for test in self.layout_tests])

    def test_required_container_wait_uses_180_seconds_and_exact_owned_command(self):
        for selection in (["--group", "layout"], ["--group", "help-max-en"],
                          ["--se-viewport"], ["--only-test", "single-instant"]):
            with self.subTest(selection=selection):
                ui, _, details = self.run_selection(selection)
                self.assertEqual(details["containerCalls"], [([
                    "xcrun", "simctl", "get_app_container", "11111111-1111-4111-8111-111111111111",
                    "local.webdashboard.Telemetry", "data"], "app-container", 180)])
                self.assertEqual(details["fixtureCalls"], 1)
                self.assertEqual(details["fixtureDestination"], details["expectedFixtureDestination"])
                self.assertIsNotNone(ui)

    def test_container_nonzero_or_timeout_preserves_failure_without_fixture_or_ui(self):
        command = ["xcrun", "simctl", "get_app_container", "11111111-1111-4111-8111-111111111111",
                   "local.webdashboard.Telemetry", "data"]
        for error in (subprocess.CalledProcessError(7, command, output="partial container"),
                      subprocess.TimeoutExpired(command, 180, output=b"partial container")):
            with self.subTest(error=type(error).__name__):
                ui, _, details = self.run_selection(["--group", "help-max-en"], container_error=error)
                self.assertEqual(details["containerCalls"], [(command, "app-container", 180)])
                self.assertEqual(details["fixtureCalls"], 0)
                self.assertIsNone(ui, "Partial failure output must never become a fixture path")

    def test_matrix_and_se_jobs_preserve_headroom_for_the_required_container_wait(self):
        root = Path(__file__).resolve().parents[2]
        for filename, job in [("native-reliability.yml", "native-replay-ui"), ("native-selected-ui.yml", "selected-ui")]:
            block = job_block((root / ".github/workflows" / filename).read_text(), job)
            for group, expected in [("layout", 67), ("replay", 57), ("replay-route", 57),
                                    ("help", 57), ("help-max-en", 57), ("help-max-ko", 57)]:
                with self.subTest(workflow=filename, group=group):
                    self.assertEqual(workflow_timeout(block, group), expected)
        se = job_block((root / ".github/workflows/native-reliability.yml").read_text(), "native-se-viewport")
        self.assertEqual(workflow_timeout(se, "layout"), 57)


if __name__ == "__main__":
    unittest.main()
