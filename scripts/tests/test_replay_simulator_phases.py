import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from contextlib import ExitStack

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as runner


class SimulatorPhaseTests(unittest.TestCase):
    def boot_failure(self, shutdown_fails, receipt_fails=False, stderr_error=None):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / "results"
            device = "11111111-1111-4111-8111-111111111111"
            calls = []
            primary = subprocess.TimeoutExpired(["xcrun", "simctl", "bootstatus", device, "-b"], 180)
            def command_output(command, timeout=60):
                calls.append(command)
                if command[1:4] == ["simctl", "list", "runtimes"]:
                    return json.dumps({"runtimes": [{"identifier": "ios27", "version": "27.0"}]})
                if command[1:3] == ["simctl", "create"]: return device
                if "bootstatus" in command:
                    raise subprocess.TimeoutExpired(command, 180, output=b"Waiting on SpringBoard\n")
                return ""
            def phase(command, log, receipt, timeout, **kwargs):
                calls.append(command)
                status = command[2]
                log.write_text("Waiting on SpringBoard\n" if status == "bootstatus" else status + "\n")
                failed = status == "bootstatus" or (shutdown_fails and status == "shutdown")
                receipt.write_text(json.dumps({"command": command, "timeoutSeconds": timeout,
                                               "timedOut": failed, "exitCode": None if failed else 0}))
                if failed: raise primary if status == "bootstatus" else subprocess.TimeoutExpired(command, timeout)
            def old_cleanup(command, **kwargs):
                calls.append(command)
                if shutdown_fails and "shutdown" in command: raise subprocess.TimeoutExpired(command, 60)
                return subprocess.CompletedProcess(command, 0)
            arguments = ["verify_offline_replay.py", "--group", "replay", "--seed-artifact", directory,
                         "--seed-manifest-sha256", "0" * 64, "--result-directory", str(results)]
            original_write = Path.write_text
            def write(path, *args, **kwargs):
                if receipt_fails and path.name == "simulator-cleanup.json":
                    raise OSError("synthetic aggregate receipt failure")
                return original_write(path, *args, **kwargs)
            def diagnostic_print(*args, **kwargs):
                if stderr_error is not None and args and str(args[0]).startswith("Cleanup receipt could not be recorded:"):
                    raise stderr_error
                print(*args, **kwargs)
            with ExitStack() as stack:
                stack.enter_context(patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}))
                stack.enter_context(patch.object(Path, "write_text", write))
                if stderr_error is not None:
                    stack.enter_context(patch.object(runner, "print", side_effect=diagnostic_print, create=True))
                stack.enter_context(patch.object(runner, "capture_simulator_bootstrap_failure", return_value={}))
                stack.enter_context(patch.object(sys, "argv", arguments))
                observer = stack.enter_context(patch.object(runner, "OwnedSimulatorBootLog"))
                observer.return_value.finalize.return_value = {"collectorCleaned": True}
                stack.enter_context(patch.object(runner, "record_toolchain", return_value={}))
                stack.enter_context(patch.object(runner, "private_artifact", return_value={"manifest": {}}))
                stack.enter_context(patch.object(runner, "run_artifact"))
                stack.enter_context(patch.object(runner, "stage_sources"))
                stack.enter_context(patch.object(runner, "current_commit", return_value="fixture"))
                stack.enter_context(patch.object(runner, "select_ui_destination", return_value=("ios27", "iphone")))
                stack.enter_context(patch.object(runner, "output", side_effect=command_output))
                stack.enter_context(patch.object(runner, "run_owned_phase", side_effect=phase, create=True))
                stack.enter_context(patch.object(runner.subprocess, "run", side_effect=old_cleanup))
                with self.assertRaises(subprocess.TimeoutExpired) as raised:
                    runner.main()
            self.assertIs(raised.exception, primary, "Cleanup must preserve the original boot failure object")
            observer.return_value.finalize.assert_called_once()
            self.assertTrue(any("delete" in command and device in command for command in calls),
                            "Owned delete must still be attempted after shutdown times out")
            self.assertIn("Waiting on SpringBoard", (results / "simulator-bootstatus.log").read_text(),
                          "Bootstrap progress must survive a timeout")
            boot = json.loads((results / "simulator-bootstatus.json").read_text())
            self.assertEqual(boot["timeoutSeconds"], 180)
            if receipt_fails:
                return
            cleanup = json.loads((results / "simulator-cleanup.json").read_text())
            self.assertEqual(cleanup["simulator"], device)
            self.assertEqual(cleanup["success"], not shutdown_fails)
            self.assertEqual([entry["phase"] for entry in cleanup["phases"]], ["shutdown", "delete"])

    def test_boot_timeout_retains_progress_and_primary_error(self):
        self.boot_failure(False)

    def test_shutdown_timeout_still_attempts_owned_delete_without_masking_boot(self):
        self.boot_failure(True)

    def test_cleanup_receipt_error_cannot_mask_boot_or_skip_owned_delete(self):
        self.boot_failure(False, receipt_fails=True)

    def test_broken_stderr_after_cleanup_receipt_error_still_deletes_owned_device(self):
        self.boot_failure(True, receipt_fails=True, stderr_error=BrokenPipeError("synthetic closed stderr pipe"))

    def test_closed_stderr_after_cleanup_receipt_error_still_deletes_owned_device(self):
        self.boot_failure(True, receipt_fails=True, stderr_error=ValueError("I/O operation on closed file"))

    def cleanup_recording_failure(self, failure):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            device = "11111111-1111-4111-8111-111111111111"
            launched = []
            original_open, original_write = Path.open, Path.write_text
            original_popen = subprocess.Popen
            def open_path(path, *args, **kwargs):
                if failure == "log" and path.name in ("simulator-shutdown.log", "simulator-delete.log"):
                    raise OSError("synthetic cleanup log failure")
                return original_open(path, *args, **kwargs)
            def write(path, *args, **kwargs):
                if failure == "receipt" and path.name in ("simulator-shutdown.json", "simulator-delete.json"):
                    raise OSError("synthetic cleanup phase receipt failure")
                return original_write(path, *args, **kwargs)
            def launch(command, **kwargs):
                if command[:2] != ["xcrun", "simctl"]:
                    return original_popen(command, **kwargs)
                launched.append(command)
                return original_popen([sys.executable, "-c", "print('synthetic owned cleanup')"], **kwargs)
            with patch.object(Path, "open", open_path), patch.object(Path, "write_text", write), \
                    patch.object(runner.subprocess, "Popen", side_effect=launch):
                self.assertFalse(runner.cleanup_simulator(device, root), "Incomplete evidence cannot produce a clean gate")
            self.assertEqual(launched, [["xcrun", "simctl", phase, device] for phase in ("shutdown", "delete")],
                             "Both bounded UUID-specific commands must launch despite recording failure")

    def test_cleanup_log_failure_still_executes_both_owned_commands(self):
        self.cleanup_recording_failure("log")

    def test_cleanup_phase_receipt_failure_still_executes_both_owned_commands(self):
        self.cleanup_recording_failure("receipt")



class BootstrapDiagnosticsTests(unittest.TestCase):
    def bootstrap_trial(self, diagnostic_failure=None, boot_fails=True, malformed_report=False):
        device = "11111111-1111-4111-8111-111111111111"
        commands = []
        primary = subprocess.TimeoutExpired(["xcrun", "simctl", "bootstatus", device, "-b"], 180)
        original_phase = runner.run_owned_phase
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            reports = results / "Library/Logs/DiagnosticReports"
            reports.mkdir(parents=True)
            for name, coalition in [("owned", device), ("other", "22222222-2222-4222-8222-222222222222")]:
                report = {"procName": "PosterBoard", "coalitionName": "com.apple.CoreSimulator.SimDevice." + coalition,
                          "captureTime": "2026-10-07 13:30:00 +0000", "faultingThread": 0,
                          "exception": {"type": "EXC_BREAKPOINT", "signal": "SIGTRAP"},
                          "termination": {"namespace": "SIGNAL", "code": 5},
                          "threads": [{"frames": [{"imageIndex": 0, "symbol": "owned-poster-frame", "imageOffset": 16}]}],
                          "usedImages": [{"name": "PosterFoundation"}]}
                (reports / ("PosterBoard-" + name + ".ips")).write_text('{}\n' + json.dumps(report))
            if malformed_report:
                (reports / "PosterBoard-owned.ips").write_text('{}\n' + json.dumps([device]))
            def phase(command, log, receipt, timeout, **kwargs):
                commands.append(command)
                if command[1:3] == ["simctl", "boot"]:
                    return {}
                if "bootstatus" in command:
                    if boot_fails: raise primary
                    return {}
                if diagnostic_failure and command[2:4] == ["list", "devices"]:
                    raise OSError("synthetic state-read failure")
                if command[1:3] == ["simctl", "io"]:
                    source = "from pathlib import Path; Path(" + repr(command[-1]) + ").write_bytes(b'\\x89PNG\\r\\n\\x1a\\n'); print('captured owned fixture')"
                else:
                    source = "print(" + repr("owned " + device) + ")"
                return original_phase([sys.executable, "-c", source], log, receipt, timeout, **kwargs)
            with patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}), patch.object(runner, "run_owned_phase", side_effect=phase), patch.object(Path, "home", return_value=results):
                if boot_fails:
                    with self.assertRaises(Exception) as caught:
                        runner.prepare_simulator(device, results)
                    self.assertIs(caught.exception, primary, "Diagnostic failure must preserve the original bootstrap error")
                else:
                    runner.prepare_simulator(device, results)
            if not boot_fails:
                self.assertEqual(len(commands), 2, "Successful bootstrap must not add diagnostic calls")
                return
            self.assertTrue((results / "simulator-bootstrap-diagnostics.json").is_file(),
                            "A failed bootstrap needs a scoped diagnostic receipt before cleanup")
            diagnostics = json.loads((results / "simulator-bootstrap-diagnostics.json").read_text())
            self.assertEqual(diagnostics["simulator"], device)
            self.assertEqual([item["phase"] for item in diagnostics["phases"]], ["state", "logs", "screenshot"])
            self.assertEqual(commands[2], ["xcrun", "simctl", "list", "devices", device, "--json"])
            self.assertIn('eventMessage CONTAINS[c] "' + device + '"', commands[3])
            self.assertEqual(commands[4][:5], ["xcrun", "simctl", "io", device, "screenshot"])
            self.assertTrue(diagnostics["screenshotCaptured"])
            self.assertEqual(len(diagnostics["posterBoard"]["reports"]), 0 if malformed_report else 1,
                             "Foreign or invalid Simulator crash records must be excluded")
            if malformed_report:
                self.assertTrue(diagnostics["posterBoard"]["observationErrors"])
            else:
                signature = diagnostics["posterBoard"]["reports"][0]
                self.assertEqual(signature["exception"], {"type": "EXC_BREAKPOINT", "signal": "SIGTRAP"})
                self.assertEqual(signature["firstFrames"], [{"image": "PosterFoundation", "symbol": "owned-poster-frame", "imageOffset": 16}])
            self.assertEqual(diagnostics["phases"][0]["success"], not bool(diagnostic_failure))
            for name in ["logs", "screenshot"]:
                receipt = json.loads((results / ("simulator-diagnostic-" + name + ".json")).read_text())
                self.assertEqual(receipt["timeoutSeconds"], 10)
                self.assertEqual(receipt["exitCode"], 0)

    def test_boot_failure_records_owned_state_logs_and_actual_capture(self):
        self.bootstrap_trial()

    def test_state_read_failure_still_captures_without_replacing_boot_error(self):
        self.bootstrap_trial(diagnostic_failure=True)

    def test_successful_boot_does_not_run_failure_diagnostics(self):
        self.bootstrap_trial(boot_fails=False)

    def test_invalid_crash_report_does_not_replace_boot_error(self):
        self.bootstrap_trial(malformed_report=True)

    def test_unexpected_diagnostic_and_stderr_errors_keep_primary_boot_error(self):
        with tempfile.TemporaryDirectory() as directory:
            primary = subprocess.TimeoutExpired(["xcrun", "simctl", "bootstatus", "owned", "-b"], 180)
            for stderr_error in [OSError("diagnostic stderr failure"), ValueError("I/O operation on closed file")]:
                with self.subTest(stderr_error=type(stderr_error).__name__), patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}), \
                        patch.object(runner, "run_owned_phase", side_effect=[{}, primary]), \
                        patch.object(runner, "capture_simulator_bootstrap_failure", side_effect=RuntimeError("diagnostic failure")), \
                        patch.object(runner, "print", side_effect=stderr_error, create=True):
                    with self.assertRaises(Exception) as caught:
                        runner.prepare_simulator("11111111-1111-4111-8111-111111111111", Path(directory))
                    self.assertIs(caught.exception, primary)

    def test_crash_directory_scan_is_bounded_and_marked_incomplete(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            reports = home / "Library/Logs/DiagnosticReports"
            reports.mkdir(parents=True)
            for index in range(250):
                path = reports / ("PosterBoard-old-" + str(index) + ".ips")
                path.write_text('{}')
                os.utime(path, (0, 0))
            with patch.object(Path, "home", return_value=home):
                evidence = runner.owned_posterboard_signatures("11111111-1111-4111-8111-111111111111")
            self.assertTrue(evidence.get("metadataScanIncomplete", False), "A truncated directory scan cannot imply crash absence")
            self.assertLessEqual(evidence["scannedDirectoryEntries"], 200)
            self.assertEqual(evidence["reports"], [])


class PostBootstrapDiagnosticsTests(unittest.TestCase):
    def trial(self, failure_phase=None, diagnostic_error=None):
        device = '11111111-1111-4111-8111-111111111111'
        primary = subprocess.TimeoutExpired(['xcodebuild', 'test'] if failure_phase == 'ui-test' else ['xcrun', 'simctl', 'bootstatus', device, '-b'], 1200 if failure_phase == 'ui-test' else 180)
        with tempfile.TemporaryDirectory() as directory:
            results = (Path(directory) / 'results').resolve()
            container = Path(directory) / 'Devices/owned/data/Containers/Data/Application/app'
            events = []
            def capture_failure(*args, **kwargs):
                events.append('capture')
                if diagnostic_error:
                    raise diagnostic_error
                return {}
            def cleanup_owned(*args, **kwargs):
                events.append('cleanup')
                return True
            def command_output(command, timeout=60):
                if command[1:4] == ['simctl', 'list', 'runtimes']:
                    return json.dumps({'runtimes': [{'identifier': 'ios27', 'version': '27.0'}]})
                if command[1:3] == ['simctl', 'create']:
                    return device
                if command[1:3] == ['simctl', 'get_app_container']:
                    return str(container)
                if command[1:5] == ['xcresulttool', 'get', 'test-results', 'summary']:
                    return json.dumps({'totalTestCount': 10, 'passedTests': 10, 'failedTests': 0, 'skippedTests': 0})
                return ''
            def phase(command, *args, **kwargs):
                if (failure_phase == 'ui-test' and command[-1] == 'test') or (failure_phase == 'bootstrap' and 'bootstatus' in command):
                    raise primary
                return {}
            arguments = ['verify_offline_replay.py', '--group', 'replay', '--seed-artifact', directory,
                         '--seed-manifest-sha256', '0' * 64, '--result-directory', str(results)]
            with ExitStack() as stack:
                stack.enter_context(patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}))
                stack.enter_context(patch.object(sys, 'argv', arguments))
                observer = stack.enter_context(patch.object(runner, "OwnedSimulatorBootLog"))
                observer.return_value.finalize.return_value = {"collectorCleaned": True}
                stack.enter_context(patch.object(runner, 'record_toolchain', return_value={}))
                stack.enter_context(patch.object(runner, 'private_artifact', return_value={'manifest': {}}))
                stack.enter_context(patch.object(runner, 'run_artifact'))
                stack.enter_context(patch.object(runner, 'stage_sources'))
                stack.enter_context(patch.object(runner, 'current_commit', return_value='fixture'))
                stack.enter_context(patch.object(runner, 'install_fixture'))
                stack.enter_context(patch.object(runner, 'select_ui_destination', return_value=('ios27', 'iphone')))
                stack.enter_context(patch.object(runner, 'output', side_effect=command_output))
                stack.enter_context(patch.object(runner, 'run_owned_phase', side_effect=phase))
                capture = stack.enter_context(patch.object(runner, 'capture_simulator_bootstrap_failure', side_effect=capture_failure))
                cleanup = stack.enter_context(patch.object(runner, 'cleanup_simulator', side_effect=cleanup_owned))
                if failure_phase:
                    with self.assertRaises(Exception) as caught:
                        runner.main()
                    self.assertIs(caught.exception, primary, 'Optional UI diagnostics must preserve the original command failure')
                else:
                    runner.main()
            cleanup.assert_called_once_with(device, results)
            self.assertEqual(events, ['capture', 'cleanup'] if failure_phase else ['cleanup'],
                             'Owned failure evidence must be attempted before cleanup, including capture errors')
            if failure_phase == 'ui-test':
                capture.assert_called_once_with(device, results, failure_phase='ui-test')
            elif failure_phase == 'bootstrap':
                capture.assert_called_once_with(device, results)
            else:
                capture.assert_not_called()

    def test_ui_timeout_captures_owned_screen_before_cleanup(self):
        self.trial(failure_phase='ui-test')

    def test_optional_ui_capture_error_cannot_mask_timeout_or_skip_cleanup(self):
        self.trial(failure_phase='ui-test', diagnostic_error=RuntimeError('synthetic optional capture failure'))

    def test_boot_failure_is_not_captured_twice_by_outer_boundary(self):
        self.trial(failure_phase='bootstrap')

    def test_successful_ui_does_not_add_failure_capture(self):
        self.trial()


if __name__ == "__main__": unittest.main()
