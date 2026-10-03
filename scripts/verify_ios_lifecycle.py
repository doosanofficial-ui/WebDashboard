#!/usr/bin/env python3
"""Run the real App sources in an isolated iPhone Simulator XCTest host.

Never selects, erases or boots a user's existing simulator. Results are not a
physical iPhone, BLE, GPS, CarPlay or visual-interaction qualification.
"""
import argparse
import json
import platform
from pathlib import Path
import subprocess
import uuid
import shutil
import tempfile

EXPECTED_TEST_COUNT = 70


def stage_sources(root, destination):
    shutil.copytree(root / "mobile-ios", destination,
                    ignore=shutil.ignore_patterns("*.xcodeproj", ".build", ".swiftpm", ".DS_Store"))


def select_runtime_and_type(data):
    candidates = []
    for runtime in data.get("runtimes", []):
        identifier = runtime.get("identifier", "")
        if not runtime.get("isAvailable") or ".SimRuntime.iOS-" not in identifier:
            continue
        phones = [entry for entry in runtime.get("supportedDeviceTypes", [])
                  if entry.get("productFamily") == "iPhone" and entry.get("identifier")]
        if phones:
            version = tuple(int(part) for part in runtime["version"].split("."))
            candidates.append((version, identifier, phones[-1]["identifier"]))
    if not candidates:
        raise ValueError("BLOCKED: no available iOS runtime with a supported iPhone device type")
    _, runtime, device_type = max(candidates)
    return runtime, device_type


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
        versions = output(["xcodebuild", "-version"])
        (results / "xcode-version.txt").write_text(versions, encoding="utf-8")
        print(versions, flush=True)
        catalog = json.loads(output(["xcrun", "simctl", "list", "runtimes", "--json"]))
        runtime, device_type = select_runtime_and_type(catalog)
        identifier = output(["xcrun", "simctl", "create", "TelemetryLifecycle-" + uuid.uuid4().hex,
                             device_type, runtime]).strip()
        simulator = str(uuid.UUID(identifier)).upper()
        evidence = {"runtime": runtime, "device_type": device_type,
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
    main()
