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

from verify_ios_lifecycle import output, stage_sources, select_runtime_and_type, verify_summary, record_toolchain
from verify_replay_seed import private_artifact, run_artifact, install_fixture, current_commit


# Explicit, disjoint 11 + 14 + 4 + 1 selectors; the slow maximum-text test has its own budget.
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
    "TelemetryUITests/LocalizationHelpUITests/testKoreanHelpAtMaximumTextAndLandscape"]
TEST_GROUPS["help-max"] = [
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
    print(f"OFFLINE REPLAY FULL GATE PASS: 30 tests across {len(TEST_GROUPS)} groups, zero failures/skips")


def run_owned_phase(command, log, receipt, timeout, best_effort_recording=False):
    """Record one bounded phase and stop only its newly owned POSIX process group."""
    if os.name != "posix":
        raise ValueError("Owned phase requires POSIX process groups")
    from verify_replay_seed import resource_snapshot, owned_progress
    began = time.monotonic()
    evidence = {"command": command, "startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "timeoutSeconds": timeout, "timedOut": False,
                "groupTermSent": False, "groupKillSent": False, "launched": False,
                "resources": resource_snapshot(), "progress": []}
    child = None
    def recording_error(error):
        evidence.setdefault("recordingErrors", []).append(str(error))
        print("Phase evidence could not be recorded: " + str(error), file=sys.stderr)
    def save():
        try:
            receipt.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
        except OSError as error:
            if not best_effort_recording:
                raise
            recording_error(error)
    def record_progress():
        try:
            evidence["progress"].append(owned_progress(child.pid, log, began))
        except OSError as error:
            if not best_effort_recording:
                raise
            recording_error(error)
    def stop_owned_group():
        if child is None:
            return
        try:
            os.killpg(child.pid, signal.SIGTERM)
            evidence["groupTermSent"] = True
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        # Leader exit does not imply that its descendants exited.
        try:
            os.killpg(child.pid, 0)
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
    if timeout <= 0:
        evidence.update(timedOut=True, elapsedSeconds=0, exitCode=None,
                        finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
        save()
        raise subprocess.TimeoutExpired(command, 0)
    try:
        stream = log.open("w", encoding="utf-8")
    except OSError as error:
        if not best_effort_recording:
            raise
        recording_error(error)
        stream = open(os.devnull, "w", encoding="utf-8")
    with stream:
        save()
        try:
            child = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                     stdin=subprocess.DEVNULL, start_new_session=True)
            evidence.update(pid=child.pid, processGroup=child.pid, launched=True)
            save()
            record_progress()
            while True:
                remaining = began + timeout - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    code = child.wait(timeout=min(15, remaining))
                    break
                except subprocess.TimeoutExpired:
                    record_progress()
                    save()
                    if time.monotonic() >= began + timeout:
                        raise subprocess.TimeoutExpired(command, timeout)
            if code:
                raise subprocess.CalledProcessError(code, command)
        except BaseException as error:
            evidence["timedOut"] = isinstance(error, subprocess.TimeoutExpired)
            if child is None and isinstance(error, OSError):
                evidence["launchError"] = {"type": type(error).__name__, "errno": error.errno,
                                           "message": str(error)}
            elif child is not None:
                stop_owned_group()
            raise
        finally:
            primary_failure = sys.exc_info()[0] is not None
            if child is not None:
                try:
                    record_progress()
                except OSError as error:
                    evidence["progressRecordingError"] = str(error)
            evidence.update(exitCode=child.returncode if child is not None else None,
                            elapsedSeconds=time.monotonic()-began,
                            finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
            try:
                save()
            except OSError as error:
                print("Phase receipt could not be recorded: " + str(error), file=sys.stderr)
                if not primary_failure:
                    stop_owned_group()
                    raise

    return evidence

def run_seed_phase(command, log, receipt, timeout):
    """Keep the Seed producer's existing bounded phase interface."""
    return run_owned_phase(command, log, receipt, timeout)


def owned_posterboard_signatures(simulator):
    """Read recent reports only for this created UUID; never expose other reports."""
    directory = Path.home() / "Library/Logs/DiagnosticReports"
    evidence = {"reports": [], "directoryAvailable": directory.is_dir(), "observationErrors": [], "metadataScanIncomplete": False, "scannedDirectoryEntries": 0,
                "scope": "PosterBoard .ips from last five minutes matching created Simulator UUID; scan at most1second/200 entries; at most20 files/2MiB each. Missing reports do not exclude a crash."}
    began = time.monotonic()
    recent = 0
    try:
        with os.scandir(directory) as entries:
            for entry in entries:
                if evidence["scannedDirectoryEntries"] >= 200 or time.monotonic() - began >= 1:
                    evidence["metadataScanIncomplete"] = True
                    break
                evidence["scannedDirectoryEntries"] += 1
                if not entry.name.startswith("PosterBoard") or not entry.name.endswith(".ips"):
                    continue
                if entry.stat().st_mtime < time.time() - 300:
                    continue
                if recent >= 20:
                    evidence["metadataScanIncomplete"] = True
                    break
                recent += 1
                path = Path(entry.path)
                try:
                    with path.open("rb") as stream:
                        raw = stream.read(2 * 1024 * 1024 + 1)
                    if len(raw) > 2 * 1024 * 1024:
                        evidence["observationErrors"].append("Oversized report skipped")
                        continue
                    text = raw.decode("utf-8")
                    if simulator.lower() not in text.lower():
                        continue
                    header, end = json.JSONDecoder().raw_decode(text)
                    body = json.loads(text[end:].strip()) if text[end:].strip() else header
                    if not isinstance(header, dict) or not isinstance(body, dict):
                        raise ValueError("Invalid report mapping")
                    if body.get("procName") != "PosterBoard" or simulator.lower() not in body.get("coalitionName", "").lower():
                        continue
                    images, threads = body.get("usedImages", []), body.get("threads", [])
                    index = body.get("faultingThread")
                    frames = threads[index].get("frames", []) if isinstance(index, int) and 0 <= index < len(threads) else []
                    evidence["reports"].append({"file": path.name, "procName": "PosterBoard",
                        "captureTime": body.get("captureTime", header.get("timestamp")),
                        "coalitionName": body["coalitionName"], "exception": body.get("exception"),
                        "termination": body.get("termination"), "firstFrames": [
                            {"image": images[f["imageIndex"]].get("name") if isinstance(f.get("imageIndex"), int) and 0 <= f["imageIndex"] < len(images) else None,
                             "symbol": f.get("symbol"), "imageOffset": f.get("imageOffset")} for f in frames[:8]]})
                except (OSError, ValueError, UnicodeError, TypeError, AttributeError, KeyError, IndexError, RecursionError) as error:
                    evidence["observationErrors"].append(type(error).__name__)
    except OSError as error:
        evidence["observationErrors"].append(type(error).__name__)
    return evidence


def capture_simulator_bootstrap_failure(simulator, results, failure_phase="bootstrap"):
    """Gather owned failure evidence; retain artifact names and never retry the failed phase."""
    simulator = str(uuid.UUID(simulator)).upper()
    screen = results / "simulator-bootstrap-screen.png"
    commands = [
        ("state", ["xcrun", "simctl", "list", "devices", simulator, "--json"]),
        ("logs", ["/usr/bin/log", "show", "--style", "compact", "--last", "5m", "--info",
                  "--predicate", 'eventMessage CONTAINS[c] "' + simulator + '"']),
        ("screenshot", ["xcrun", "simctl", "io", simulator, "screenshot", "--type=png", str(screen)])]
    evidence = {"simulator": simulator, "failurePhase": failure_phase, "phases": [], "screenshotCaptured": False,
                "scope": "Read-only diagnostics for created UUID after " + failure_phase + " failure; no retry"}
    for phase, command in commands:
        entry = {"phase": phase, "success": False}
        try:
            run_owned_phase(command, results / ("simulator-diagnostic-" + phase + ".log"),
                            results / ("simulator-diagnostic-" + phase + ".json"), 10)
            entry["success"] = True
            if phase == "screenshot" and screen.is_file():
                with screen.open("rb") as stream:
                    evidence["screenshotCaptured"] = stream.read(8) == b"\x89PNG\r\n\x1a\n"
        except (OSError, subprocess.SubprocessError) as error:
            entry.update(errorType=type(error).__name__, error=str(error))
        evidence["phases"].append(entry)
    evidence["posterBoard"] = owned_posterboard_signatures(simulator)
    (results / "simulator-bootstrap-diagnostics.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    return evidence


def prepare_simulator(simulator, results):
    try:
        for phase, timeout in (("boot", 60), ("bootstatus", 180)):
            command = ["xcrun", "simctl", phase, simulator]
            if phase == "bootstatus":
                command.append("-b")
            run_owned_phase(command, results / ("simulator-" + phase + ".log"),
                            results / ("simulator-" + phase + ".json"), timeout)
    except (OSError, subprocess.SubprocessError):
        try:
            capture_simulator_bootstrap_failure(simulator, results)
        except Exception as error:
            # Optional evidence must not replace the bootstrap error, including a broken stderr.
            try:
                print("Bootstrap diagnostics unavailable: " + str(error), file=sys.stderr)
            except Exception:
                pass
        raise


def cleanup_simulator(simulator, results):
    """Attempt both operations on our created UUID; keep the primary failure intact."""
    evidence = {"simulator": simulator, "success": True, "phases": []}
    receipt = results / "simulator-cleanup.json"
    for phase in ("shutdown", "delete"):
        entry = {"phase": phase}
        try:
            recorded = run_owned_phase(["xcrun", "simctl", phase, simulator],
                                       results / ("simulator-" + phase + ".log"),
                                       results / ("simulator-" + phase + ".json"), 60,
                                       best_effort_recording=True)
            entry["success"] = True
            if recorded and recorded.get("recordingErrors"):
                entry["recordingErrors"] = recorded["recordingErrors"]
                evidence["success"] = False
        except (OSError, subprocess.SubprocessError) as error:
            entry.update(success=False, errorType=type(error).__name__, error=str(error))
            evidence["success"] = False
        evidence["phases"].append(entry)
        try:
            receipt.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
        except OSError as error:
            evidence["success"] = False
            print("Cleanup receipt could not be recorded: " + str(error), file=sys.stderr)
    return evidence["success"]


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
        failure_phase = "bootstrap"
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
            prepare_simulator(simulator, results)
            failure_phase = "app-build"
            output(["xcodegen", "generate", "--spec", str(staged / "project.yml")], timeout=120)
            derived = workspace / "derived"
            base = ["xcodebuild", "-project", str(staged / "Telemetry.xcodeproj"), "-scheme", "Telemetry",
                    "-destination", "platform=iOS Simulator,id=" + simulator,
                    "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO",
                    "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never"]
            run_owned_phase(base + ["build"], results / "build.log",
                            results / "build-process.json", 600)
            failure_phase = "app-install"
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
            failure_phase = "ui-test"
            run_owned_phase(command, results / "test.log", results / "test-process.json", 1200)
            failure_phase = "result-read"
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
        except (OSError, subprocess.SubprocessError):
            if simulator and failure_phase != "bootstrap":
                try:
                    capture_simulator_bootstrap_failure(simulator, results, failure_phase=failure_phase)
                except Exception as error:
                    try:
                        print("Simulator diagnostics unavailable: " + str(error), file=sys.stderr)
                    except Exception:
                        pass
            raise
        finally:
            if simulator:
                primary_failure = sys.exc_info()[0] is not None
                cleaned = cleanup_simulator(simulator, results)
                if not cleaned and not primary_failure:
                    raise RuntimeError("Owned Simulator cleanup failed; see simulator-cleanup.json")
        gate = "SE VIEWPORT RE-EXECUTION" if args.se_viewport else "OFFLINE REPLAY UI"
        print(f"{gate} PASS: {expected_count} executed tests, zero failures/skips; Simulator fixture, not hardware evidence")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--verify-groups":
        verify_group_results(Path(sys.argv[2]))
    else:
        main()
