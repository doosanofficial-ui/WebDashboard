#!/usr/bin/env python3
"""Seed and test Replay UI on a new disposable Simulator; never contacts a physical device."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

from verify_ios_lifecycle import output, stage_sources, select_runtime_and_type, verify_summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result-directory", type=Path, required=True)
    parser.add_argument("--only-test", choices=["background-export-lifecycle", "active-slider-drag", "ui-clarity", "single-instant", "large-text", "recorded-history", "recorded-route", "native-save-reentry"],
                        help="Run one new native lifecycle test; default executes all seventeen UI regressions")
    args = parser.parse_args()
    results = args.result_directory.resolve()
    results.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    simulator = None
    with tempfile.TemporaryDirectory(prefix="telemetry-offline-ui-") as directory:
        workspace = Path(directory)
        staged = workspace / "source"
        stage_sources(root, staged)
        try:
            catalog = json.loads(output(["xcrun", "simctl", "list", "runtimes", "--json"]))
            runtime, device_type = select_runtime_and_type(catalog)
            selected = next(r for r in catalog["runtimes"] if r["identifier"] == runtime)
            preferred = next((t["identifier"] for t in selected.get("supportedDeviceTypes", [])
                              if t.get("identifier", "").endswith(".iPhone-17")), None)
            device_type = preferred or device_type
            simulator = str(uuid.UUID(output(["xcrun", "simctl", "create", "OfflineReplay-" + uuid.uuid4().hex,
                                              device_type, runtime]).strip())).upper()
            (results / "environment.json").write_text(json.dumps({"runtime": runtime, "device_type": device_type,
                "simulator": simulator, "scope": "Simulator fixture only; no vehicle/GPS acquisition"}, indent=2))
            output(["xcrun", "simctl", "boot", simulator])
            output(["xcrun", "simctl", "bootstatus", simulator, "-b"], timeout=180)
            output(["xcodegen", "generate", "--spec", str(staged / "project.yml")], timeout=120)
            derived = workspace / "derived"
            base = ["xcodebuild", "-project", str(staged / "Telemetry.xcodeproj"), "-scheme", "Telemetry",
                    "-destination", "platform=iOS Simulator,id=" + simulator,
                    "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO",
                    "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never"]
            with (results / "build.log").open("w") as log:
                subprocess.run(base + ["build"], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
            output(["xcrun", "simctl", "install", simulator,
                    str(derived / "Build/Products/Debug-iphonesimulator/Telemetry.app")], timeout=120)
            container = Path(output(["xcrun", "simctl", "get_app_container", simulator,
                                     "local.webdashboard.Telemetry", "data"]).strip())
            seed = workspace / "Seed"
            (seed / "Sources/Seed").mkdir(parents=True)
            (seed / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Seed", platforms: [.macOS(.v13)],
 dependencies: [.package(path: "../source/TelemetryCore")],
 targets: [.executableTarget(name: "Seed", dependencies: [.product(name: "TelemetryCore", package: "TelemetryCore")])])
''')
            shutil.copyfile(root / "scripts/tests/offline_replay_seed.swift", seed / "Sources/Seed/main.swift")
            with (results / "seed.log").open("w") as log:
                subprocess.run(["swift", "run", "--package-path", str(seed), "Seed",
                                str(container / "Library/Application Support/Telemetry")],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
            bundle = results / "ReplayUI.xcresult"
            focused_methods = {"background-export-lifecycle": "testNativeExportBackgroundReturnCancelAndReentry",
                               "active-slider-drag": "testPlayingLongSliderDragPreservesCapturedUserTarget",
                               "recorded-history": "testRecordedSignalHistoryContainsOnlySelectedTimePrefix",
                               "recorded-route": "testRecordedGPSRouteContainsOnlySelectedTimePrefix"}
            selected_tests = ["-only-testing:TelemetryUITests/OfflineReplayUITests/testNativeExportBackgroundReturnCancelAndReentry", "-only-testing:TelemetryUITests/OfflineReplayUITests/testNativeJSONCSVSaveConfirmsCompletion"] if args.only_test == "native-save-reentry" else ["-only-testing:TelemetryUITests/UIClarityUITests/testRecordedTimeAccessibilityAtLargeTextAndLandscape"] if args.only_test == "large-text" else ["-only-testing:TelemetryUITests/UIClarityUITests/testSingleInstantRecordingExplainsUnavailableTimeNavigation"] if args.only_test == "single-instant" else ["-only-testing:TelemetryUITests/UIClarityUITests"] if args.only_test == "ui-clarity" else ["-only-testing:TelemetryUITests/OfflineReplayUITests/" + focused_methods[args.only_test]] if args.only_test else [
                "-only-testing:TelemetryUITests/OfflineReplayUITests",
                "-only-testing:TelemetryUITests/TelemetryUITests/testMeasurementExportControlIsVisible",
                "-only-testing:TelemetryUITests/TelemetryUITests/testMeasurementCSVExportControlIsVisible",
                "-only-testing:TelemetryUITests/UIClarityUITests"]
            expected_count = 2 if args.only_test == "native-save-reentry" else 5 if args.only_test == "ui-clarity" else 1 if args.only_test else 17
            command = base + ["-resultBundlePath", str(bundle)] + selected_tests + ["test"]
            (results / "command.json").write_text(json.dumps(command, indent=2))
            with (results / "test.log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=1200)
            summary = json.loads(output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)]))
            (results / "summary.json").write_text(json.dumps(summary, indent=2))
            native = results / "native-exports"
            native.mkdir()
            own_storage = container.parents[3] / "Containers/Shared/AppGroup"
            for path in own_storage.rglob("telemetry-measurements-*.*"):
                if path.suffix in (".json", ".csv"):
                    shutil.copy2(path, native / path.name)
            output(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                    "--output-path", str(results / "screenshots")], timeout=120)
            verify_summary(summary, expected_count)
            print(f"OFFLINE REPLAY UI PASS: {expected_count} executed tests, zero failures/skips; Simulator fixture, not hardware evidence")
        finally:
            if simulator:
                subprocess.run(["xcrun", "simctl", "shutdown", simulator], capture_output=True, timeout=60)
                subprocess.run(["xcrun", "simctl", "delete", simulator], check=True, capture_output=True, timeout=60)


if __name__ == "__main__":
    main()
