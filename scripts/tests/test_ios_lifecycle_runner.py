import os
import importlib.util
from pathlib import Path
import unittest
import tempfile
import sys
import subprocess
import re

SPEC = importlib.util.spec_from_file_location("ios_lifecycle_runner", Path(__file__).resolve().parents[1] / "verify_ios_lifecycle.py")
runner = importlib.util.module_from_spec(SPEC)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
SPEC.loader.exec_module(runner)

class LifecycleRunnerTests(unittest.TestCase):
    def test_ascii_staging_preserves_sources_and_excludes_generated_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "workspace\u00a0name"
            source = root / "mobile-ios"
            source.mkdir(parents=True)
            (source / "project.yml").write_text("version: fixture")
            (source / "Fixture.xcodeproj").mkdir()
            (source / ".build").mkdir()
            destination = Path(directory) / "ascii-stage"
            runner.stage_sources(root, destination)
            self.assertEqual((destination / "project.yml").read_text(), "version: fixture")
            self.assertFalse((destination / "Fixture.xcodeproj").exists())
            self.assertFalse((destination / ".build").exists())
            self.assertTrue((source / "Fixture.xcodeproj").is_dir())

    def test_staging_cannot_overwrite_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "mobile-ios").mkdir()
            with self.assertRaises(FileExistsError):
                runner.stage_sources(root, root)
    def test_selects_pinned_ios27_even_when_ios28_is_available(self):
        data = {"runtimes": [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0", "version": "18.0", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "iphone", "productFamily": "iPhone"}]},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "ipad", "productFamily": "iPad"}, {"identifier": "iphone-new", "productFamily": "iPhone"}]},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-28-0", "version": "28.0", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "phone", "productFamily": "iPhone"}]}]}
        self.assertEqual(runner.select_runtime_and_type(data), ("com.apple.CoreSimulator.SimRuntime.iOS-27-0", "iphone-new"))

    def test_ios26_cannot_be_a_fallback(self):
        with self.assertRaises(ValueError):
            runner.select_runtime_and_type({"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-2", "version": "26.2", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "phone", "productFamily": "iPhone"}]}]})

    def test_toolchain_rejects_wrong_xcode_or_sdk_and_records_build(self):
        evidence = runner.verify_toolchain("Xcode 27.0\nBuild version 27A266a\n", "27.0", "27.0")
        self.assertEqual(evidence["xcode_build"], "27A266a")
        for xcode, ios, simulator in [("Xcode 26.2\nBuild version 17C52", "27.0", "27.0"), ("Xcode 27.0\nBuild version 27A266a", "26.2", "27.0"), ("Xcode 27.0\nBuild version 27A266a", "27.0", "28.0")]:
            with self.subTest(xcode=xcode, ios=ios, simulator=simulator), self.assertRaises(ValueError):
                runner.verify_toolchain(xcode, ios, simulator)

    def test_numeric_ios27_patch_versions_are_allowed_and_preserved(self):
        self.assertEqual(runner.verify_toolchain("Xcode 27.0.1\nBuild version 27A999", "27.0.2", "27.1")["xcode_version"], "27.0.1")
        data = {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0-1", "version": "27.0.1", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "phone", "productFamily": "iPhone"}]}]}
        self.assertEqual(runner.select_runtime_and_type(data)[0], data["runtimes"][0]["identifier"])
        for version in ("26.9", "28.0", "270.0", "27.beta", "27.0beta"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                runner.verify_toolchain(f"Xcode {version}\nBuild version fixture", "27.0", "27.0")

    def test_test_command_nonzero_cannot_be_green_with_passing_counters(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                runner.run_test_command([sys.executable, "-c", "print('23 passed, 0 failed'); raise SystemExit(65)"], log, 10)
            self.assertEqual(failure.exception.returncode, 65)
            self.assertIn("23 passed", log.read_text())
            runner.run_test_command([sys.executable, "-c", "print('success')"], log, 10)
            self.assertIn("success", log.read_text())

    def test_missing_compatible_runtime_is_a_blocker_not_pass(self):
        with self.assertRaises(ValueError):
            runner.select_runtime_and_type({"runtimes": []})

    def test_does_not_choose_an_ipad_only_runtime(self):
        with self.assertRaises(ValueError):
            runner.select_runtime_and_type({"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "ipad", "productFamily": "iPad"}]}]})

    def test_summary_requires_expected_executed_tests(self):
        runner.verify_summary({"totalTestCount": 7, "passedTests": 7, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}, 7)
        for count in [0, 6, 8]:
            with self.subTest(count=count), self.assertRaises(ValueError):
                runner.verify_summary({"totalTestCount": count, "passedTests": count, "failedTests": 0, "skippedTests": 0}, 7)

    def test_skips_failures_and_expected_failures_are_not_pass(self):
        for field in ["failedTests", "skippedTests", "expectedFailures"]:
            summary = {"totalTestCount": 7, "passedTests": 7, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
            summary[field] = 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                runner.verify_summary(summary, 7)

    def test_malformed_or_missing_counters_fail_closed(self):
        for summary in [{}, {"totalTestCount": "7", "passedTests": 7, "failedTests": 0, "skippedTests": 0}, {"totalTestCount": 7, "passedTests": 7, "failedTests": False, "skippedTests": 0}]:
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                runner.verify_summary(summary, 7)

    def test_default_gate_matches_all_declared_hosted_tests(self):
        root = Path(__file__).resolve().parents[2]
        declarations = []
        for path in sorted((root / "mobile-ios/LifecycleTests").glob("*.swift")):
            declarations.extend(re.findall(r"^\s+func (test\w+)\(", path.read_text(), re.MULTILINE))
        self.assertIn("sources: [LifecycleTests]", (root / "mobile-ios/lifecycle-tests.yml").read_text())
        self.assertEqual(len(declarations), 92)
        self.assertEqual(runner.EXPECTED_TEST_COUNT, len(declarations))
        self.assertIn("testCancelledComputedManySignalSeekCannotPublish", declarations)
        self.assertIn("testStopAfterComputedManySignalSeekDiscardsResultAndAllOwnedState", declarations)

    def test_expanded_gate_rejects_old_green_or_partial_counts(self):
        expected = runner.EXPECTED_TEST_COUNT
        runner.verify_summary({"totalTestCount": runner.EXPECTED_TEST_COUNT, "passedTests": runner.EXPECTED_TEST_COUNT, "failedTests": 0,
                               "skippedTests": 0, "expectedFailures": 0}, expected)
        for count in [0, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 93]:
            with self.subTest(count=count), self.assertRaises(ValueError):
                runner.verify_summary({"totalTestCount": count, "passedTests": count,
                                       "failedTests": 0, "skippedTests": 0}, expected)

    def test_expanded_gate_never_accepts_skips_or_expected_failures(self):
        for field in ["failedTests", "skippedTests", "expectedFailures"]:
            summary = {"totalTestCount": runner.EXPECTED_TEST_COUNT, "passedTests": runner.EXPECTED_TEST_COUNT, "failedTests": 0,
                       "skippedTests": 0, "expectedFailures": 0}
            summary[field] = 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                runner.verify_summary(summary, runner.EXPECTED_TEST_COUNT)



class HostedCleanupControlFlowTests(unittest.TestCase):
    """Execute main's real control flow with only external host/device boundaries replaced.

    The fixture's owned/unrelated markers are ordinary files, not Simulators.
    No Xcode, simctl, product host, or existing device can execute here.
    """
    def trial(self, body=None, shutdown=None, delete=None, receipt_error=False, workspace_error=False, stderr_error=False,
              reader_capture=False, reader_output=b"fixture partial output", reader_stderr=None, metadata_error=False):
        from contextlib import ExitStack, redirect_stdout, redirect_stderr
        from unittest.mock import patch
        import io
        import json
        import shutil

        device = "11111111-1111-4111-8111-111111111111"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            results = root / "results"
            owned = root / device
            other = root / "22222222-2222-4222-8222-222222222222"
            other.write_text("preserve unrelated fixture")
            private = root / "private-source"
            private.mkdir()
            events, calls = [], []
            boot_error = subprocess.TimeoutExpired(["xcrun", "simctl", "bootstatus", device, "-b"], 180)
            shutdown_error = subprocess.TimeoutExpired(["xcrun", "simctl", "shutdown", device], 60)
            reader_error = subprocess.TimeoutExpired(["fixture-reader"], 60, output=reader_output, stderr=reader_stderr)
            original_write = Path.write_text
            original_open = Path.open
            original_output = runner.output
            class Workspace:
                name = str(private)
                def cleanup(self):
                    events.append("workspace")
                    shutil.rmtree(private)
                    if workspace_error:
                        raise OSError("synthetic private workspace cleanup failure")
            def stage(source_root, destination):
                destination.mkdir(parents=True)
                (destination / "fixture.txt").write_text("synthetic host boundary")
            def output(command, timeout=60):
                if command[1:4] == ["simctl", "list", "runtimes"]:
                    return json.dumps({"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True,
                        "supportedDeviceTypes": [{"identifier": "fixture-phone", "productFamily": "iPhone"}]}]})
                if command[1:3] == ["simctl", "create"]:
                    if body == "create":
                        raise OSError("synthetic create failure")
                    owned.write_text("owned fixture")
                    return device
                if command[1:3] == ["simctl", "boot"]:
                    self.assertEqual(command[-1], device)
                    return ""
                if command[1:3] == ["simctl", "bootstatus"]:
                    self.assertEqual(command[-2], device)
                    self.assertEqual(timeout, 180)
                    if body == "boot":
                        raise boot_error
                    return ""
                if command[0] == "xcodegen":
                    return ""
                if command[1:5] == ["xcresulttool", "get", "test-results", "summary"]:
                    self.assertEqual(timeout, 60)
                    if reader_capture:
                        return original_output(command, timeout=timeout)
                    if body == "reader":
                        raise reader_error
                    return json.dumps({"totalTestCount": runner.EXPECTED_TEST_COUNT, "passedTests": runner.EXPECTED_TEST_COUNT, "failedTests": 0, "skippedTests": 0})
                raise AssertionError("Unexpected external command: " + repr(command))
            def run(command, **kwargs):
                if command[0] == "xcodebuild":
                    self.assertEqual(kwargs['timeout'], 900)
                    self.assertIs(kwargs['text'], True)
                    self.assertEqual(kwargs['stderr'], subprocess.STDOUT)
                    self.assertNotIn('start_new_session', kwargs)
                    kwargs["stdout"].write("Synthetic runner control-flow fixture; not XCTest execution\n")
                    return subprocess.CompletedProcess(command, 65 if body == "xcode" else 0)
                self.assertIn(command[2], ("shutdown", "delete"))
                self.assertEqual(command, ["xcrun", "simctl", command[2], device])
                self.assertEqual(kwargs["timeout"], 60)
                self.assertTrue(kwargs["capture_output"])
                calls.append({"command": command, "timeout": kwargs["timeout"], "check": kwargs.get("check", False)})
                phase = command[2]
                events.append(phase)
                fault = shutdown if phase == "shutdown" else delete
                if fault == "timeout":
                    raise shutdown_error if phase == "shutdown" else subprocess.TimeoutExpired(command, 60)
                if fault == "error":
                    raise OSError("synthetic " + phase + " launch failure")
                code = 7 if fault == "nonzero" else 0
                if code and kwargs.get("check", False):
                    raise subprocess.CalledProcessError(code, command)
                if phase == "delete" and not code:
                    owned.unlink()
                return subprocess.CompletedProcess(command, code)
            def write(path, *args, **kwargs):
                if receipt_error and path.name == "simulator-cleanup.json":
                    raise OSError("synthetic cleanup receipt failure")
                return original_write(path, *args, **kwargs)
            def open_path(path, *args, **kwargs):
                if metadata_error and path.name == "result-read-observation.json" and args and args[0] == "x":
                    raise OSError("synthetic reader metadata receipt failure")
                return original_open(path, *args, **kwargs)
            class BrokenStderr(io.StringIO):
                def write(self, value):
                    raise BrokenPipeError("synthetic stderr diagnostic failure")
            stdout = io.StringIO()
            stderr = BrokenStderr() if stderr_error else io.StringIO()
            caught = None
            with ExitStack() as stack:
                stack.enter_context(patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}))
                stack.enter_context(patch.object(sys, "argv", ["verify_ios_lifecycle.py", "--result-directory", str(results)]))
                stack.enter_context(patch.object(runner.platform, "system", return_value="Darwin"))
                stack.enter_context(patch.object(runner.tempfile, "TemporaryDirectory", return_value=Workspace()))
                stack.enter_context(patch.object(runner, "stage_sources", side_effect=stage))
                stack.enter_context(patch.object(runner.export_fixture, "instrument_export_sources", return_value={}))
                stack.enter_context(patch.object(runner, "record_toolchain", return_value={"xcode_version": "27.0"}))
                stack.enter_context(patch.object(runner, "output", side_effect=output))
                stack.enter_context(patch.object(runner.subprocess, "run", side_effect=run))
                reader_process = stack.enter_context(patch.object(runner.subprocess, "check_output",
                    side_effect=reader_error if body == "reader" else None,
                    return_value=json.dumps({"totalTestCount": runner.EXPECTED_TEST_COUNT,
                        "passedTests": runner.EXPECTED_TEST_COUNT, "failedTests": 0, "skippedTests": 0})))
                summary_gate = stack.enter_context(patch.object(runner, "verify_summary", wraps=runner.verify_summary))
                stack.enter_context(patch.object(Path, "open", open_path))
                stack.enter_context(patch.object(Path, "write_text", write))
                stack.enter_context(redirect_stdout(stdout))
                stack.enter_context(redirect_stderr(stderr))
                try:
                    runner.main()
                except Exception as error:
                    caught = error
            receipt = results / "simulator-cleanup.json"
            self.assertEqual(other.read_text(), "preserve unrelated fixture")
            first = results / 'first-failure-observation.json'
            reader_observation = results / 'result-read-observation.json'
            xcode_observation = results / 'hosted-xcode-observation.json'
            return {"error": caught, "bootError": boot_error, "shutdownError": shutdown_error,
                    "readerError": reader_error, "firstFailure": json.loads(first.read_text()) if first.is_file() else None,
                    "readerObservation": json.loads(reader_observation.read_text()) if reader_observation.is_file() else None,
                    "xcodeObservation": json.loads(xcode_observation.read_text()) if xcode_observation.is_file() else None,
                    "readerProcessCall": reader_process.call_args, "summaryGateCalls": summary_gate.call_count,
                    "summaryExists": (results / "summary.json").exists(),
                    "events": events, "calls": calls, "ownedRemoved": not owned.exists(),
                    "workspaceRemoved": not private.exists(), "stdout": stdout.getvalue(), "stderr": stderr.getvalue(),
                    "receipt": json.loads(receipt.read_text()) if receipt.is_file() else None}

    def assert_reader_failed_after_successful_test_command(self, value):
        self.assertIs(value["error"], value["readerError"])
        self.assertEqual(value["error"].timeout, 60)
        self.assertEqual(value["firstFailure"]["phase"], "result-read")
        self.assertTrue(value["xcodeObservation"]["returnedNormally"])
        self.assertEqual(value["xcodeObservation"]["childExitCode"], 0)
        self.assertNotIn("outputMetadata", value["xcodeObservation"])
        self.assertEqual(value["events"], ["shutdown", "delete", "workspace"])
        self.assertEqual(value["summaryGateCalls"], 0)
        self.assertFalse(value["summaryExists"])
        self.assertNotIn("HOSTED XCTEST PASS", value["stdout"])

    def test_reader_timeout_records_lengths_without_promoting_successful_test_command(self):
        value = self.trial(body="reader")
        self.assert_reader_failed_after_successful_test_command(value)
        self.assertTrue(value["ownedRemoved"])
        self.assertTrue(value["workspaceRemoved"])
        observation = value["readerObservation"]
        self.assertEqual(observation.get("outputMetadata"), {
            "outputPresent": True, "outputBytes": 22, "stderrPresent": False, "stderrBytes": None})
        self.assertEqual(observation["timeoutSeconds"], 60)
        self.assertEqual(observation["errorType"], "TimeoutExpired")
        self.assertIsNone(observation["childExitCode"])
        self.assertGreaterEqual(observation["callReturnedMonotonic"], observation["callStartedMonotonic"])

    def test_reader_timeout_survives_cleanup_and_metadata_recording_failures(self):
        for faults in ({"shutdown": "timeout", "delete": "nonzero"},
                       {"metadata_error": True}, {"receipt_error": True},
                       {"workspace_error": True, "stderr_error": True},
                       {"shutdown": "timeout", "delete": "nonzero", "receipt_error": True,
                        "workspace_error": True, "stderr_error": True, "metadata_error": True}):
            with self.subTest(faults=faults):
                value = self.trial(body="reader", **faults)
                self.assert_reader_failed_after_successful_test_command(value)
                if faults.get("metadata_error"):
                    self.assertIsNone(value["readerObservation"])
                else:
                    self.assertEqual(value["readerObservation"].get("outputMetadata"), {
                        "outputPresent": True, "outputBytes": 22, "stderrPresent": False, "stderrBytes": None})

        from unittest.mock import patch
        with patch.object(runner.failure_observation, "captured_output_metadata",
                          side_effect=ValueError("synthetic optional metadata calculation failure")):
            failed = self.trial(body="reader")
            succeeded = self.trial()
        self.assert_reader_failed_after_successful_test_command(failed)
        self.assertNotIn("outputMetadata", failed["readerObservation"])
        self.assertIsNone(succeeded["error"])
        self.assertTrue(succeeded["readerObservation"]["returnedNormally"])
        self.assertEqual(succeeded["summaryGateCalls"], 1)
        self.assertTrue(succeeded["summaryExists"])

    def test_reader_output_contract_preserves_partial_values_and_original_budget(self):
        import json
        for payload, stderr, output_bytes, stderr_bytes in (
                (b"private-reader-output", b"hidden-stderr", 21, 13),
                ("한글", None, 6, None), ("한글" * 3000, None, 18000, None),
                ("\ud800", None, None, None), (object(), None, None, None),
                ("x" * 65537, None, None, None), (None, None, None, None),
                (b"", b"", 0, 0), ("", None, 0, None)):
            with self.subTest(output_bytes=output_bytes, stderr_bytes=stderr_bytes):
                value = self.trial(body="reader", reader_capture=True, reader_output=payload, reader_stderr=stderr)
                self.assert_reader_failed_after_successful_test_command(value)
                self.assertIs(value["error"].output, payload)
                self.assertIs(value["error"].stderr, stderr)
                arguments, kwargs = value["readerProcessCall"]
                self.assertEqual(arguments[0][:6], ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path"])
                self.assertEqual(kwargs, {"text": True, "stderr": subprocess.STDOUT, "timeout": 60})
                self.assertEqual(value["readerObservation"].get("outputMetadata"), {
                    "outputPresent": payload is not None, "outputBytes": output_bytes,
                    "stderrPresent": stderr is not None, "stderrBytes": stderr_bytes})
                recorded = json.dumps(value["readerObservation"], ensure_ascii=False) + value["stdout"] + value["stderr"]
                for private in ("private-reader-output", "hidden-stderr", "한글"):
                    self.assertNotIn(private, recorded)
        value = self.trial(reader_capture=True)
        self.assertIsNone(value["error"])
        self.assertTrue(value["readerObservation"]["returnedNormally"])
        self.assertEqual(value["summaryGateCalls"], 1)
        self.assertTrue(value["summaryExists"])
        self.assertGreater(value["readerObservation"].get("outputMetadata", {}).get("outputBytes", 0), 0)

    def test_shutdown_timeout_still_deletes_owned_uuid_and_preserves_failure(self):
        value = self.trial(shutdown="timeout")
        self.assertEqual(value["events"], ["shutdown", "delete", "workspace"], "Timeout must not skip owned delete or private workspace cleanup")
        self.assertTrue(value["ownedRemoved"])
        self.assertTrue(value["workspaceRemoved"])
        self.assertIs(value["error"], value["shutdownError"])
        self.assertNotIn("HOSTED XCTEST PASS", value["stdout"])
        self.assertFalse(value["receipt"]["success"])
        self.assertEqual([p["phase"] for p in value["receipt"]["phases"]], ["shutdown", "delete"])
        self.assertTrue(value["receipt"]["phases"][0]["timedOut"])
        self.assertEqual(value["receipt"]["phases"][1]["exitCode"], 0)

    def test_boot_failure_survives_shutdown_timeout_and_delete_failure(self):
        value = self.trial(body="boot", shutdown="timeout", delete="nonzero")
        self.assertIs(value["error"], value["bootError"], "Cleanup must preserve the original body failure object")
        self.assertEqual(value["events"], ["shutdown", "delete", "workspace"])
        self.assertFalse(value["receipt"]["success"])
        self.assertEqual(value["receipt"]["phases"][1]["exitCode"], 7)

    def test_delete_failure_after_passing_counters_cannot_print_pass(self):
        value = self.trial(delete="nonzero")
        self.assertIsInstance(value["error"], subprocess.CalledProcessError)
        self.assertEqual(value["error"].returncode, 7)
        self.assertTrue(value["workspaceRemoved"])
        self.assertNotIn("HOSTED XCTEST PASS", value["stdout"])
        self.assertFalse(value["receipt"]["success"])

    def test_existing_unchecked_shutdown_exit_policy_is_preserved(self):
        value = self.trial(shutdown="nonzero")
        self.assertIsNone(value["error"])
        self.assertTrue(value["ownedRemoved"])
        self.assertTrue(value["receipt"]["success"])
        self.assertEqual(value["receipt"]["phases"][0]["exitCode"], 7)
        self.assertFalse(value["calls"][0]["check"])
        self.assertTrue(value["calls"][1]["check"])
        self.assertIn("HOSTED XCTEST PASS", value["stdout"])

    def test_xcodebuild_failure_is_not_masked_by_cleanup_launch_error(self):
        value = self.trial(body="xcode", shutdown="error")
        self.assertIsInstance(value["error"], RuntimeError)
        self.assertIn("xcodebuild exited 65", str(value["error"]))
        self.assertEqual(value["events"], ["shutdown", "delete", "workspace"])
        self.assertFalse(value["receipt"]["success"])

    def test_create_failure_never_selects_a_cleanup_target(self):
        value = self.trial(body="create")
        self.assertIsInstance(value["error"], OSError)
        self.assertIn("create failure", str(value["error"]))
        self.assertEqual(value["events"], ["workspace"])
        self.assertEqual(value["calls"], [])
        self.assertTrue(value["workspaceRemoved"])

    def test_receipt_write_failure_after_passing_body_cannot_pass(self):
        value = self.trial(receipt_error=True)
        self.assertIsInstance(value["error"], OSError)
        self.assertIn("receipt failure", str(value["error"]))
        self.assertEqual(value["events"], ["shutdown", "delete", "workspace"])
        self.assertTrue(value["ownedRemoved"])
        self.assertNotIn("HOSTED XCTEST PASS", value["stdout"])

    def test_receipt_error_cannot_mask_boot_failure(self):
        value = self.trial(body="boot", receipt_error=True)
        self.assertIs(value["error"], value["bootError"])
        self.assertEqual(value["events"], ["shutdown", "delete", "workspace"])
        self.assertTrue(value["ownedRemoved"])

    def test_workspace_error_cannot_mask_the_first_cleanup_timeout(self):
        value = self.trial(shutdown="timeout", workspace_error=True)
        self.assertIs(value["error"], value["shutdownError"])
        self.assertEqual(value["events"], ["shutdown", "delete", "workspace"])
        self.assertFalse(value["receipt"]["workspace"]["success"])
        self.assertFalse(value["receipt"]["success"])

    def test_receipt_diagnostic_error_cannot_mask_boot_timeout(self):
        value = self.trial(body="boot", receipt_error=True, stderr_error=True)
        self.assertIs(value["error"], value["bootError"], "Optional stderr diagnostics must preserve the original body exception")
        self.assertEqual(value["events"], ["shutdown", "delete", "workspace"])

    def test_receipt_diagnostic_error_cannot_mask_first_cleanup_timeout(self):
        value = self.trial(shutdown="timeout", receipt_error=True, stderr_error=True)
        self.assertIs(value["error"], value["shutdownError"], "Optional stderr diagnostics must preserve the first cleanup exception")
        self.assertEqual(value["events"], ["shutdown", "delete", "workspace"])

if __name__ == "__main__":
    unittest.main()
