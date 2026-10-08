#!/usr/bin/env python3
"""Run the real App sources in an isolated iPhone Simulator XCTest host.

Never selects, erases or boots a user's existing simulator. Results are not a
physical iPhone, BLE, GPS, CarPlay or visual-interaction qualification.
"""
import argparse
import json
import platform
import re
import os
import sys
from pathlib import Path
import subprocess
import uuid
import export_dismissal_fixture as export_fixture
import shutil
import tempfile

import failure_observation
from failure_observation import observe_first_failure

EXPECTED_TEST_COUNT = 92


def stage_sources(root, destination):
    shutil.copytree(root / "mobile-ios", destination,
                    ignore=shutil.ignore_patterns("*.xcodeproj", ".build", ".swiftpm", ".DS_Store"))


def is_ios27_version(version):
    """Accept numeric 27.x versions, preserving the actual minor/patch in evidence."""
    return isinstance(version, str) and re.fullmatch(r"27(?:\.[0-9]+)+", version) is not None


def run_test_command(command, log, timeout):
    """A nonzero xcodebuild exit is failure even if result counters look green."""
    with log.open("w", encoding="utf-8") as stream:
        subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                       check=True, timeout=timeout)


def select_runtime_and_type(data):
    candidates = []
    for runtime in data.get("runtimes", []):
        identifier = runtime.get("identifier", "")
        if (not runtime.get("isAvailable") or not identifier.startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
                or not is_ios27_version(runtime.get("version"))
                or identifier.removeprefix("com.apple.CoreSimulator.SimRuntime.iOS-") != runtime["version"].replace(".", "-")):
            continue
        phones = [entry for entry in runtime.get("supportedDeviceTypes", [])
                  if entry.get("productFamily") == "iPhone" and entry.get("identifier")]
        if phones:
            candidates.append((identifier, phones[-1]["identifier"]))
    if not candidates:
        raise ValueError("BLOCKED: iOS 27.x runtime with a supported iPhone is required; no fallback")
    return candidates[0]


def verify_toolchain(versions, ios_sdk, simulator_sdk):
    version = re.search(r"^Xcode (.+)$", versions, re.MULTILINE)
    build = re.search(r"^Build version (.+)$", versions, re.MULTILINE)
    evidence = {"xcode_version": version.group(1) if version else None,
                "xcode_build": build.group(1) if build else None,
                "ios_sdk": ios_sdk.strip(), "simulator_sdk": simulator_sdk.strip()}
    if (not is_ios27_version(evidence["xcode_version"]) or not evidence["xcode_build"]
            or not is_ios27_version(evidence["ios_sdk"]) or not is_ios27_version(evidence["simulator_sdk"])):
        raise ValueError(f"BLOCKED: Xcode/iOS SDK/Simulator SDK 27.x required: {evidence}")
    return evidence


def record_toolchain(results):
    versions = output(["xcodebuild", "-version"])
    ios_sdk = output(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"])
    simulator_sdk = output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])
    raw = {"xcode": versions, "ios_sdk": ios_sdk.strip(), "simulator_sdk": simulator_sdk.strip(),
           "developer_directory_override": os.environ.get("DEVELOPER_DIR"),
           "xcode_select_default": output(["xcode-select", "-p"]).strip()}
    (results / "xcode-version.txt").write_text(versions, encoding="utf-8")
    (results / "toolchain.json").write_text(json.dumps(raw, indent=2), encoding="utf-8")
    print(json.dumps(raw), flush=True)
    return verify_toolchain(versions, ios_sdk, simulator_sdk)


def verify_summary(summary, expected_count):
    for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests"):
        if type(summary.get(key)) is not int:
            raise ValueError(f"Missing/invalid XCTest counter: {key}")
    if summary["totalTestCount"] != expected_count or summary["passedTests"] != expected_count:
        raise ValueError(f"Expected exactly {expected_count} executed/passed hosted tests: {summary}")
    if summary["failedTests"] or summary["skippedTests"] or summary.get("expectedFailures", 0):
        raise ValueError(f"Hosted tests contain failures/skips/expected failures: {summary}")


def output(command, timeout=60):
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT, timeout=timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result-directory", type=Path, required=True,
                        help="New directory; never overwrite previous evidence")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.exit(2, "BLOCKED: native hosted verification requires macOS, Xcode and an iOS Simulator runtime\n")
    root = Path(__file__).resolve().parents[1]
    results = args.result_directory.resolve()
    results.mkdir(parents=True, exist_ok=False)
    simulator = None
    workspace = tempfile.TemporaryDirectory(prefix="telemetry-lifecycle-source-")
    failure_phase = "setup"
    try:
        staged = Path(workspace.name) / "source"
        stage_sources(root, staged)
        (results / "export-audit-source.json").write_text(json.dumps(export_fixture.instrument_export_sources(root, staged), indent=2))
        toolchain = record_toolchain(results)
        catalog = json.loads(output(["xcrun", "simctl", "list", "runtimes", "--json"]))
        runtime, device_type = select_runtime_and_type(catalog)
        identifier = output(["xcrun", "simctl", "create", "TelemetryLifecycle-" + uuid.uuid4().hex,
                             device_type, runtime]).strip()
        simulator = str(uuid.UUID(identifier)).upper()
        selected = next(r for r in catalog["runtimes"] if r["identifier"] == runtime)
        evidence = {**toolchain, "runtime": runtime, "runtime_version": selected["version"],
                    "runtime_build": selected.get("buildversion"), "device_type": device_type,
                    "simulator": simulator, "host_bundle": "local.webdashboard.Telemetry.LifecycleHost"}
        (results / "environment.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
        print(json.dumps(evidence), flush=True)
        failure_phase = "hosted-boot"
        failure_observation.observe_call(lambda: output(["xcrun", "simctl", "boot", simulator]),
                                         results, failure_phase, 60)
        failure_phase = "hosted-bootstatus"
        failure_observation.observe_call(lambda: output(["xcrun", "simctl", "bootstatus", simulator, "-b"], timeout=180),
                                         results, failure_phase, 180)
        output(["xcodegen", "generate", "--spec", str(staged / "lifecycle-tests.yml")], timeout=120)
        bundle = results / "Lifecycle.xcresult"
        command = ["xcodebuild", "-project", str(staged / "Telemetry.xcodeproj"),
                   "-scheme", "TelemetryLifecycle", "-configuration", "Debug",
                   "-testLanguage", "en", "-testRegion", "US",
                   "-destination", "platform=iOS Simulator,id=" + simulator,
                   "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-resultBundlePath", str(bundle),
                   "-derivedDataPath", str(Path(workspace.name) / "derived"),
                   "CODE_SIGNING_ALLOWED=NO", export_fixture.SWIFT_CONDITION, "test"]
        (results / "command.json").write_text(json.dumps(command, indent=2), encoding="utf-8")
        log = results / "xcodebuild.log"
        failure_phase = "hosted-xcode"
        with log.open("w", encoding="utf-8") as stream:
            run = failure_observation.observe_call(
                lambda: subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, text=True, timeout=900),
                results, failure_phase, 900)
        print(log.read_text(encoding="utf-8", errors="replace")[-22000:], flush=True)
        if run.returncode:
            raise RuntimeError(f"xcodebuild exited {run.returncode}; see {log}")
        failure_phase = "result-read"
        summary = json.loads(failure_observation.observe_call(
            lambda: output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)]),
            results, failure_phase, 60))
        (results / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
        verify_summary(summary, EXPECTED_TEST_COUNT)
    except BaseException as original_error:
        try:
            observe_first_failure(original_error, results, simulator, failure_phase)
        except Exception:
            pass
        raise
    finally:
        primary_failure = sys.exc_info()[0] is not None
        cleanup_error = None
        cleanup_failure_snapshot = None
        cleanup_failure_phase = "cleanup"
        cleanup = {"simulator": simulator, "success": True, "phases": []}
        try:
            if simulator is not None:
                # Only this run's created UUID; retain the existing return-code policy.
                for phase in ("shutdown", "delete"):
                    command = ["xcrun", "simctl", phase, simulator]
                    entry = {"phase": phase, "command": command, "timeoutSeconds": 60,
                             "checkReturnCode": phase == "delete", "timedOut": False}
                    try:
                        result = failure_observation.observe_call(
                            lambda: subprocess.run(command, check=phase == "delete", capture_output=True, timeout=60),
                            results, 'hosted-' + phase, 60)
                        entry.update(accepted=True, commandSucceeded=result.returncode == 0, exitCode=result.returncode)
                    except Exception as error:
                        entry.update(accepted=False, commandSucceeded=False,
                                     exitCode=getattr(error, "returncode", None),
                                     timedOut=isinstance(error, subprocess.TimeoutExpired),
                                     errorType=type(error).__name__, error=str(error))
                        cleanup["success"] = False
                        if cleanup_error is None:
                            cleanup_error = error
                            cleanup_failure_phase = 'hosted-' + phase
                            try:
                                cleanup_failure_snapshot = failure_observation.recorded_failure(results, cleanup_failure_phase, error)
                            except Exception:
                                pass
                    cleanup["phases"].append(entry)
        finally:
            try:
                workspace.cleanup()
                cleanup["workspace"] = {"success": True}
            except Exception as error:
                cleanup["workspace"] = {"success": False, "errorType": type(error).__name__, "error": str(error)}
                cleanup["success"] = False
                if cleanup_error is None:
                    cleanup_error = error
            try:
                (results / "simulator-cleanup.json").write_text(json.dumps(cleanup, indent=2), encoding="utf-8")
            except OSError as error:
                if cleanup_error is None:
                    cleanup_error = error
                try:
                    print("Cleanup receipt could not be recorded: " + str(error), file=sys.stderr)
                except Exception:
                    pass  # Optional diagnostics cannot replace the original failure.
            if cleanup_error is not None and not primary_failure:
                try:
                    observe_first_failure(cleanup_error, results, simulator, cleanup_failure_phase,
                                          snapshot=cleanup_failure_snapshot)
                except Exception:
                    pass
                raise cleanup_error
        # A pending body exception propagates unchanged after all cleanup attempts.
    print(f"HOSTED XCTEST PASS: {EXPECTED_TEST_COUNT} tests, zero failures/skips; real App/SQLite, Simulator only", flush=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["--check-toolchain"]:
        toolchain = verify_toolchain(output(["xcodebuild", "-version"]),
            output(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"]),
            output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]))
        catalog = json.loads(output(["xcrun", "simctl", "list", "runtimes", "--json"]))
        runtime, device_type = select_runtime_and_type(catalog)
        selected = next(r for r in catalog["runtimes"] if r["identifier"] == runtime)
        print(json.dumps({**toolchain, "runtime": runtime, "runtime_version": selected["version"],
                          "runtime_build": selected.get("buildversion"), "device_type": device_type}, indent=2))
    else:
        main()
