#!/usr/bin/env python3
"""Seed and test Replay UI on a new disposable Simulator; never contacts a physical device."""
import argparse
import json
import datetime
import os
import platform
import signal
import time
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

from verify_ios_lifecycle import output, stage_sources, select_runtime_and_type, verify_summary, record_toolchain, run_test_command
from verify_replay_seed import private_artifact, run_artifact, install_fixture, current_commit


# Explicit, disjoint 11 + 14 + 4 selectors: source coverage is enforced by unit tests.
TEST_GROUPS = {'replay': ['TelemetryUITests/OfflineReplayUITests/testSessionReplayShowsAnalysisAndSynchronizedRecordedTime',
            'TelemetryUITests/OfflineReplayUITests/testRecordedSignalHistoryContainsOnlySelectedTimePrefix',
            'TelemetryUITests/OfflineReplayUITests/testRecordedGPSRouteContainsOnlySelectedTimePrefix',
            'TelemetryUITests/OfflineReplayUITests/testPlayingLongSliderDragPreservesCapturedUserTarget',
            'TelemetryUITests/OfflineReplayUITests/testNativeExportBackgroundReturnCancelAndReentry',
            'TelemetryUITests/OfflineReplayUITests/testRecordedPlaybackPauseSpeedAndAutomaticEnd',
            'TelemetryUITests/OfflineReplayUITests/testRecordedTimeSeekingAcrossTabsAndEditorReturn',
            'TelemetryUITests/OfflineReplayUITests/testNativeExportCancelReentryAndReplayAcrossTabs',
            'TelemetryUITests/OfflineReplayUITests/testNativeJSONCSVSaveConfirmsCompletion',
            'TelemetryUITests/OfflineReplayUITests/testSetupPresentsLocalWorkflowWithoutServerOrCredential',
            'TelemetryUITests/OfflineReplayUITests/testSeededSessionPickerSnapshotAndReadOnlyControls'],
 'layout': ['TelemetryUITests/DashboardEditingUITests/testSelectedCardKeepsConfigurationAvailableOnDemand',
            'TelemetryUITests/DashboardEditingUITests/testMoveReleaseUndoRedoAndReentryPreserveNeighbor',
            'TelemetryUITests/DashboardEditingUITests/testResizeReleaseUndoPreserveNeighbor',
            'TelemetryUITests/DashboardEditingUITests/testOverlappingResizeKeepsSelectedHandleUsableForNextResize',
            'TelemetryUITests/DashboardEditingUITests/testLandscapeMoveUsesCurrentMeasuredGeometry',
            'TelemetryUITests/UIClarityUITests/testSyntheticDemoNeverClaimsLiveVehicleAcquisition',
            'TelemetryUITests/UIClarityUITests/testReplayUnknownFreshnessDoesNotBecomeProvenStale',
            'TelemetryUITests/UIClarityUITests/testSelectedSOCProfileIsVisibleBeforeGenericUnavailableSignals',
            'TelemetryUITests/UIClarityUITests/testRecordedTimeAccessibilityAtLargeTextAndLandscape',
            'TelemetryUITests/UIClarityUITests/testSingleInstantRecordingExplainsUnavailableTimeNavigation',
            'TelemetryUITests/TelemetryUITests/testMeasurementExportControlIsVisible',
            'TelemetryUITests/TelemetryUITests/testMeasurementCSVExportControlIsVisible',
            'TelemetryUITests/SmallViewportUIRegression/testSmallViewportLiveAndEditorReachability',
            'TelemetryUITests/SmallViewportStatusUIRegression/testStatusAndEditingHelpRemainAccessibleAtMaximumText']}


TEST_GROUPS["help"] = [
    "TelemetryUITests/LocalizationHelpUITests/testCaptureEnglishGuideScreens",
    "TelemetryUITests/LocalizationHelpUITests/testCaptureKoreanGuideScreens",
    "TelemetryUITests/LocalizationHelpUITests/testLanguageSwitchPersistsAndHelpPreservesReplay",
    "TelemetryUITests/LocalizationHelpUITests/testKoreanHelpAtMaximumTextAndLandscape",
    "TelemetryUITests/LocalizationHelpUITests/testEveryGuideAtMaximumTextShowsWholeNumberedImageAndClosesZoomInBothLanguages"]


# These are re-executions of two layout tests, not two additional unique tests.
SE_VIEWPORT_TESTS = [
    'TelemetryUITests/SmallViewportUIRegression/testSmallViewportLiveAndEditorReachability',
    'TelemetryUITests/SmallViewportStatusUIRegression/testStatusAndEditingHelpRemainAccessibleAtMaximumText']
SE_DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation'


def select_ui_destination(catalog, se_viewport=False):
    if se_viewport:
        filtered = {"runtimes": [dict(runtime, supportedDeviceTypes=[
            device for device in runtime.get("supportedDeviceTypes", [])
            if device.get("identifier") == SE_DEVICE_TYPE])
            for runtime in catalog.get("runtimes", [])]}
        try:
            return select_runtime_and_type(filtered)
        except ValueError as error:
            raise ValueError("BLOCKED: iPhone SE (3rd generation) on iOS 27.x is required; no fallback") from error
    runtime, device_type = select_runtime_and_type(catalog)
    selected = next(entry for entry in catalog["runtimes"] if entry["identifier"] == runtime)
    preferred = next((device["identifier"] for device in selected.get("supportedDeviceTypes", [])
                      if device.get("identifier", "").endswith(".iPhone-17")), None)
    return runtime, preferred or device_type


def verify_group_results(root):
    executed = []
    for group, tests in TEST_GROUPS.items():
        selection = json.loads((root / group / "selection.json").read_text())
        if selection != {"group": group, "tests": tests}:
            raise ValueError(f"Unexpected/missing group selectors: {group}")
        verify_summary(json.loads((root / group / "summary.json").read_text()), len(tests))
        executed.extend(tests)
    if len(executed) != 30 or len(set(executed)) != 30:
        raise ValueError("Expected exactly 30 disjoint UI tests")
    print("OFFLINE REPLAY FULL GATE PASS: 30 tests across three groups, zero failures/skips")


def run_seed_phase(command, log, receipt, timeout):
    """Record one Seed phase and bound only its newly owned POSIX process group."""
    if os.name != "posix":
        raise ValueError("Seed phase requires POSIX process groups")
    from verify_replay_seed import resource_snapshot, owned_progress
    began = time.monotonic()
    evidence = {"command": command, "startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "timeoutSeconds": timeout, "timedOut": False,
                "groupTermSent": False, "groupKillSent": False, "launched": False,
                "resources": resource_snapshot(), "progress": []}
    def save():
        receipt.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    if timeout <= 0:
        evidence.update(timedOut=True, elapsedSeconds=0, exitCode=None,
                        finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
        save()
        raise subprocess.TimeoutExpired(command, 0)
    with log.open("w", encoding="utf-8") as stream:
        child = None
        save()
        try:
            child = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                     stdin=subprocess.DEVNULL, start_new_session=True)
            evidence.update(pid=child.pid, processGroup=child.pid, launched=True)
            save()
            evidence["progress"].append(owned_progress(child.pid, log, began))
            while True:
                remaining = began + timeout - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    code = child.wait(timeout=min(15, remaining))
                    break
                except subprocess.TimeoutExpired:
                    evidence["progress"].append(owned_progress(child.pid, log, began))
                    save()
                    if time.monotonic() >= began + timeout:
                        raise subprocess.TimeoutExpired(command, timeout)
        except OSError as error:
            if child is None:
                evidence["launchError"] = {"type": type(error).__name__, "errno": error.errno,
                                           "message": str(error)}
            raise
        except subprocess.TimeoutExpired:
            evidence["timedOut"] = True
            try:
                os.killpg(child.pid, signal.SIGTERM)
                evidence["groupTermSent"] = True
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
            # Leader exit does not imply that its compiler descendants exited.
            try:
                os.killpg(child.pid, 0)  # Probe only the group created above.
            except ProcessLookupError:
                evidence["groupStillExistsAfterLeaderWait"] = False
            else:
                evidence["groupStillExistsAfterLeaderWait"] = True
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                    evidence["groupKillSent"] = True
                except ProcessLookupError:
                    pass
            child.wait(timeout=10)
            raise
        finally:
            if child is not None:
                evidence["progress"].append(owned_progress(child.pid, log, began))
            evidence.update(exitCode=child.returncode if child is not None else None,
                            elapsedSeconds=time.monotonic()-began,
                            finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
            save()
        if code:
            raise subprocess.CalledProcessError(code, command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result-directory", type=Path, required=True)
    parser.add_argument("--seed-artifact", type=Path, required=True,
                        help="Qualified executable for this exact commit; no shard rebuild fallback")
    parser.add_argument("--seed-manifest-sha256", required=True,
                        help="Trusted producer job output, supplied separately from the downloaded artifact")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--se-viewport", action="store_true",
                           help="Re-execute the two viewport tests on iPhone SE (3rd generation), iOS 27.x only")
    selection.add_argument("--group", choices=TEST_GROUPS, help="Disjoint portion of the full 30-test CI gate")
    selection.add_argument("--only-test", choices=["background-export-lifecycle", "active-slider-drag", "ui-clarity", "single-instant", "large-text", "recorded-history", "recorded-route", "native-save-reentry", "help-capture"],
                        help="Run one new native lifecycle test; default executes all twenty-five UI regressions")
    args = parser.parse_args()
    results = args.result_directory.resolve()
    results.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    toolchain = record_toolchain(results)
    simulator = None
    with tempfile.TemporaryDirectory(prefix="telemetry-offline-ui-") as directory:
        workspace = Path(directory)
        seed_artifact = private_artifact(root, args.seed_artifact.resolve(), workspace / "seed-artifact",
                                          toolchain, platform.machine(), current_commit(root),
                                          args.seed_manifest_sha256)
        fixture = workspace / "fixture"
        fixture.mkdir(mode=0o700)
        run_artifact(seed_artifact, fixture, results)
        (results / "seed-admission.json").write_text(json.dumps(seed_artifact["manifest"], indent=2))
        print("SEED ADMISSION AND FIXTURE PASS: trusted producer digest/private bytes; before Simulator", flush=True)
        staged = workspace / "source"
        stage_sources(root, staged)
        try:
            catalog = json.loads(output(["xcrun", "simctl", "list", "runtimes", "--json"]))
            runtime, device_type = select_ui_destination(catalog, args.se_viewport)
            selected = next(r for r in catalog["runtimes"] if r["identifier"] == runtime)
            simulator = str(uuid.UUID(output(["xcrun", "simctl", "create", "OfflineReplay-" + uuid.uuid4().hex,
                                              device_type, runtime]).strip())).upper()
            (results / "environment.json").write_text(json.dumps({**toolchain, "runtime": runtime, "runtime_version": selected["version"],
                "runtime_build": selected.get("buildversion"), "device_type": device_type,
                "simulator": simulator, "scope": "Simulator fixture only; no vehicle/GPS acquisition"}, indent=2))
            print((results / "environment.json").read_text(), flush=True)
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
            install_fixture(fixture, container / "Library/Application Support/Telemetry")
            bundle = results / "ReplayUI.xcresult"
            focused_methods = {"background-export-lifecycle": "testNativeExportBackgroundReturnCancelAndReentry",
                               "active-slider-drag": "testPlayingLongSliderDragPreservesCapturedUserTarget",
                               "recorded-history": "testRecordedSignalHistoryContainsOnlySelectedTimePrefix",
                               "recorded-route": "testRecordedGPSRouteContainsOnlySelectedTimePrefix"}
            selected_tests = ["-only-testing:" + test for test in TEST_GROUPS["help"][:2]] if args.only_test == "help-capture" else ["-only-testing:TelemetryUITests/OfflineReplayUITests/testNativeExportBackgroundReturnCancelAndReentry", "-only-testing:TelemetryUITests/OfflineReplayUITests/testNativeJSONCSVSaveConfirmsCompletion"] if args.only_test == "native-save-reentry" else ["-only-testing:TelemetryUITests/UIClarityUITests/testRecordedTimeAccessibilityAtLargeTextAndLandscape"] if args.only_test == "large-text" else ["-only-testing:TelemetryUITests/UIClarityUITests/testSingleInstantRecordingExplainsUnavailableTimeNavigation"] if args.only_test == "single-instant" else ["-only-testing:TelemetryUITests/UIClarityUITests"] if args.only_test == "ui-clarity" else ["-only-testing:TelemetryUITests/OfflineReplayUITests/" + focused_methods[args.only_test]] if args.only_test else [
                "-only-testing:TelemetryUITests/OfflineReplayUITests",
                "-only-testing:TelemetryUITests/TelemetryUITests/testMeasurementExportControlIsVisible",
                "-only-testing:TelemetryUITests/TelemetryUITests/testMeasurementCSVExportControlIsVisible",
                "-only-testing:TelemetryUITests/UIClarityUITests",
                "-only-testing:TelemetryUITests/DashboardEditingUITests",
                "-only-testing:TelemetryUITests/SmallViewportUIRegression",
                "-only-testing:TelemetryUITests/SmallViewportStatusUIRegression",
                "-only-testing:TelemetryUITests/LocalizationHelpUITests"]
            expected_count = 2 if args.only_test == "native-save-reentry" else 5 if args.only_test == "ui-clarity" else 1 if args.only_test else 30
            if args.only_test == "help-capture":
                selected_tests = ["-only-testing:" + test for test in TEST_GROUPS["help"][:2]]
                expected_count = 2
            if args.group:
                selected_tests = ["-only-testing:" + test for test in TEST_GROUPS[args.group]]
                expected_count = len(TEST_GROUPS[args.group])
                (results / "selection.json").write_text(json.dumps({"group": args.group, "tests": TEST_GROUPS[args.group]}, indent=2))
            if args.se_viewport:
                selected_tests = ["-only-testing:" + test for test in SE_VIEWPORT_TESTS]
                expected_count = len(SE_VIEWPORT_TESTS)
                (results / "selection.json").write_text(json.dumps({
                    "reexecution": "se-viewport", "repeatOf": "layout",
                    "requiredDeviceType": SE_DEVICE_TYPE, "tests": SE_VIEWPORT_TESTS}, indent=2))
            command = base + ["-resultBundlePath", str(bundle)] + selected_tests + ["test"]
            (results / "command.json").write_text(json.dumps(command, indent=2))
            run_test_command(command, results / "test.log", timeout=1200)
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
            gate = "SE VIEWPORT RE-EXECUTION" if args.se_viewport else "OFFLINE REPLAY UI"
            print(f"{gate} PASS: {expected_count} executed tests, zero failures/skips; Simulator fixture, not hardware evidence")
        finally:
            if simulator:
                subprocess.run(["xcrun", "simctl", "shutdown", simulator], capture_output=True, timeout=60)
                subprocess.run(["xcrun", "simctl", "delete", simulator], check=True, capture_output=True, timeout=60)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--verify-groups":
        verify_group_results(Path(sys.argv[2]))
    else:
        main()
