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
import shutil
import tempfile

EXPECTED_TEST_COUNT = 83


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
    try:
        staged = Path(workspace.name) / "source"
        stage_sources(root, staged)
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
        output(["xcrun", "simctl", "boot", simulator])
        output(["xcrun", "simctl", "bootstatus", simulator, "-b"], timeout=180)
        output(["xcodegen", "generate", "--spec", str(staged / "lifecycle-tests.yml")], timeout=120)
        bundle = results / "Lifecycle.xcresult"
        command = ["xcodebuild", "-project", str(staged / "Telemetry.xcodeproj"),
                   "-scheme", "TelemetryLifecycle", "-configuration", "Debug",
                   "-destination", "platform=iOS Simulator,id=" + simulator,
                   "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-resultBundlePath", str(bundle),
                   "-derivedDataPath", str(Path(workspace.name) / "derived"),
                   "CODE_SIGNING_ALLOWED=NO", "test"]
        (results / "command.json").write_text(json.dumps(command, indent=2), encoding="utf-8")
        log = results / "xcodebuild.log"
        with log.open("w", encoding="utf-8") as stream:
            run = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, text=True, timeout=900)
        print(log.read_text(encoding="utf-8", errors="replace")[-22000:], flush=True)
        if run.returncode:
            raise RuntimeError(f"xcodebuild exited {run.returncode}; see {log}")
        summary = json.loads(output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)]))
        (results / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
        verify_summary(summary, EXPECTED_TEST_COUNT)
        print(f"HOSTED XCTEST PASS: {EXPECTED_TEST_COUNT} tests, zero failures/skips; real App/SQLite, Simulator only", flush=True)
    finally:
        if simulator is not None:
            # Only the UUID returned by this run's create command is touched.
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], capture_output=True, timeout=60)
            subprocess.run(["xcrun", "simctl", "delete", simulator], check=True, capture_output=True, timeout=60)
        workspace.cleanup()


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
