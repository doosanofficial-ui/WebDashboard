import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_help_assets as assets
import collect_help_source_inputs as collector


class HelpSourceCollectionTests(unittest.TestCase):
    def test_generator_and_verifier_share_recursive_source_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            examples = {"mobile-ios/App/Screen.swift": b"screen\n",
                        "mobile-ios/App/CarPlay/Projection.swift": b"projection\r\n",
                        "mobile-ios/App/Resources/Nested/schema.json": b"{}\n",
                        "mobile-ios/App/Resources/ko.lproj/Localizable.strings": b'"A"="B";\n'}
            for name, content in {**examples, "mobile-ios/App/AppHelpView.swift": b"excluded",
                                  "mobile-ios/App/Resources/HelpScreenshots/marker.json": b"excluded"}.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            expected = {name: hashlib.sha256(value.replace(b"\r\n", b"\n")).hexdigest()
                        for name, value in examples.items()}
            self.assertEqual(collector.collect(root), expected)
            self.assertEqual(assets.source_input_hashes(root), expected)
            self.assertEqual(set(assets.expected_screen_inputs(root)), set(examples))

    def test_historical_completion_adds_omissions_without_refreshing_stale_hashes(self):
        old_hash, nested_hash = "a" * 64, "b" * 64
        recorded = {"mobile-ios/App/Screen.swift": old_hash}
        snapshot = {"baseHead": "c" * 40, "files": {
            "mobile-ios/App/Screen.swift": old_hash,
            "mobile-ios/App/CarPlay/Projection.swift": nested_hash}}
        manifest = {"sourceBaseCommit": "c" * 40, "screenInputs": recorded,
                    "screens": {"old": {"sha256": "d" * 64}}, "captureSummary": {"passed": 2}}
        before = json.dumps(manifest, sort_keys=True)
        completed = collector.complete_historical_inputs(manifest, snapshot, set(snapshot["files"]))
        self.assertEqual(completed, {**recorded, "mobile-ios/App/CarPlay/Projection.swift": nested_hash})
        self.assertEqual(completed["mobile-ios/App/Screen.swift"], old_hash)
        self.assertEqual(json.dumps(manifest, sort_keys=True), before)

    def test_unproven_conflicting_or_malformed_history_is_rejected(self):
        manifest = {"sourceBaseCommit": "a" * 40, "screenInputs": {"one.swift": "b" * 64}}
        good = {"baseHead": "a" * 40, "files": {"one.swift": "b" * 64, "nested/two.swift": "c" * 64}}
        bad = [dict(good, baseHead="d" * 40),
               {**good, "files": {"one.swift": "b" * 64}},
               {**good, "files": {**good["files"], "one.swift": "e" * 64}},
               {**good, "files": {**good["files"], "nested/two.swift": "invalid"}}]
        for snapshot in bad:
            with self.subTest(snapshot=snapshot), self.assertRaises(ValueError):
                collector.complete_historical_inputs(manifest, snapshot, set(good["files"]))
        with self.assertRaises(ValueError):
            collector.complete_historical_inputs(manifest, good, {"nested/two.swift"})
        with self.assertRaises(ValueError):
            collector.complete_historical_inputs({**manifest, "sourceBaseCommit": None},
                                                 {**good, "baseHead": None}, set(good["files"]))

    def test_cli_inventory_is_not_a_capture_certificate_and_never_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "mobile-ios/App/CarPlay/Projection.swift"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"projection\n")
            before = source.read_bytes()
            result = subprocess.run([sys.executable, "-B", "-O", str(Path(collector.__file__)),
                                     "--root", str(root)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertFalse(report["captureCertified"])
            self.assertEqual(set(report["sourceInputs"]), {"mobile-ios/App/CarPlay/Projection.swift"})
            self.assertEqual(source.read_bytes(), before)

    def test_real_capture_source_snapshot_binds_root_staged_copy_and_test_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root, staged = Path(directory) / "repo", Path(directory) / "staged-mobile-ios"
            source = root / "mobile-ios/App/CarPlay/Projection.swift"
            source.parent.mkdir(parents=True)
            source.write_text("projection\n")
            test = root / "mobile-ios/UITests/LocalizationHelpUITests.swift"
            test.parent.mkdir()
            test.write_text("capture-test\n")
            shutil.copytree(root / "mobile-ios", staged)
            before = collector.begin_capture(root, staged, "a" * 40)
            after = collector.finish_capture(root, staged, before, "a" * 40)
            self.assertTrue(after["sourceStableDuringRun"])
            self.assertFalse(after["captureCertified"])
            for change in ("root", "staged", "test", "commit", "extra"):
                with self.subTest(change=change):
                    if change == "root": source.write_text("changed")
                    elif change == "staged": (staged / "App/CarPlay/Projection.swift").write_text("changed")
                    elif change == "test": (staged / "UITests/LocalizationHelpUITests.swift").write_text("changed")
                    elif change == "extra": (staged / "App/NewSource.swift").write_text("new")
                    with self.assertRaises(ValueError):
                        collector.finish_capture(root, staged, before, "b" * 40 if change == "commit" else "a" * 40)
                    source.write_text("projection\n")
                    (staged / "App/CarPlay/Projection.swift").write_text("projection\n")
                    (staged / "UITests/LocalizationHelpUITests.swift").write_text("capture-test\n")
                    (staged / "App/NewSource.swift").unlink(missing_ok=True)

    def producer_probe(self, selection, *, valid_stage=False, groups=None):
        import verify_offline_replay as runner
        from contextlib import ExitStack
        class NativeBoundaryReached(RuntimeError):
            pass
        with tempfile.TemporaryDirectory() as directory:
            result = Path(directory) / "results"
            def stage_sources(root, destination):
                if valid_stage:
                    names = set(collector.collect(root)) | {"mobile-ios/UITests/LocalizationHelpUITests.swift"}
                    for name in names:
                        target = destination / Path(name).relative_to("mobile-ios")
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(root / name, target)
                else:
                    source = destination / "App/Injected.swift"
                    source.parent.mkdir(parents=True)
                    source.write_text("unreviewed staged source")
            arguments = ["verify_offline_replay.py", "--result-directory", str(result),
                         "--seed-artifact", directory, "--seed-manifest-sha256", "a" * 64] + selection
            with ExitStack() as stack:
                stack.enter_context(patch.object(sys, "argv", arguments))
                if groups:
                    stack.enter_context(patch.dict(runner.TEST_GROUPS, groups))
                for name, value in (("record_toolchain", {}), ("private_artifact", {"manifest": {}}),
                                    ("run_artifact", None), ("current_commit", "b" * 40),
                                    ("observe_first_failure", None)):
                    stack.enter_context(patch.object(runner, name, return_value=value))
                stack.enter_context(patch.object(runner, "stage_sources", side_effect=stage_sources))
                instrument = stack.enter_context(patch.object(runner.export_fixture, "instrument_export_sources", return_value={}))
                begin = stack.enter_context(patch.object(runner.help_sources, "begin_capture", wraps=collector.begin_capture))
                finish = stack.enter_context(patch.object(runner.help_sources, "finish_capture", wraps=collector.finish_capture))
                native = stack.enter_context(patch.object(runner, "output", side_effect=NativeBoundaryReached("mocked bootstrap boundary")))
                try:
                    runner.main()
                except (ValueError, NativeBoundaryReached) as error:
                    failure = error
                else:
                    self.fail("Producer must stop at the source gate or mocked bootstrap")
                receipt = result / "help-source-inputs-before.json"
                return {"failureType": type(failure).__name__, "message": str(failure),
                        "beginCalls": begin.call_count, "finishCalls": finish.call_count,
                        "instrumentCalls": instrument.call_count, "mockedNativeCalls": native.call_count,
                        "sourceReceipt": json.loads(receipt.read_text()) if receipt.exists() else None}

    def test_capture_producer_rejects_staged_drift_before_simulator_commands(self):
        groups = {"mixed-capture": ["TelemetryUITests/OfflineReplayUITests/testNativeExportCancelReentryAndReplayAcrossTabs",
                                    "TelemetryUITests/LocalizationHelpUITests/testCaptureEnglishGuideScreens"]}
        for selection in ([], ["--only-test", "help-capture"], ["--group", "help"], ["--group", "mixed-capture"]):
            with self.subTest(selection=selection):
                result = self.producer_probe(selection, groups=groups)
                self.assertEqual(result["failureType"], "ValueError", result)
                self.assertIn("Staged Help source", result["message"])
                self.assertEqual(result["beginCalls"], 1)
                self.assertEqual(result["finishCalls"], 0)
                self.assertEqual(result["instrumentCalls"], 0)
                self.assertEqual(result["mockedNativeCalls"], 0)

    def test_non_capture_final_selection_retains_only_its_export_audit(self):
        groups = {"help": ["TelemetryUITests/LocalizationHelpUITests/testLanguageSwitchPersistsAndHelpPreservesReplay"]}
        for selection, audit in ((["--group", "replay"], True), (["--only-test", "native-export-dismissal"], True),
                                 (["--group", "help-max-en"], False), (["--se-viewport"], False),
                                 (["--group", "help"], False)):
            with self.subTest(selection=selection):
                result = self.producer_probe(selection, groups=groups)
                self.assertEqual(result["failureType"], "NativeBoundaryReached", result)
                self.assertEqual(result["beginCalls"], 0)
                self.assertEqual(result["finishCalls"], 0)
                self.assertEqual(result["instrumentCalls"], int(audit))
                self.assertEqual(result["mockedNativeCalls"], 1)
                self.assertIsNone(result["sourceReceipt"])

    def test_default_and_dedicated_clean_sources_record_before_bootstrap(self):
        import verify_offline_replay as runner
        for selection in ([], ["--only-test", "help-capture"], ["--group", "help"]):
            with self.subTest(selection=selection):
                result = self.producer_probe(selection, valid_stage=True)
                self.assertEqual(result["failureType"], "NativeBoundaryReached", result)
                self.assertEqual(result["beginCalls"], 1)
                self.assertEqual(result["finishCalls"], 0)
                self.assertEqual(result["instrumentCalls"], 0)
                self.assertEqual(result["mockedNativeCalls"], 1)
                self.assertIsNotNone(result["sourceReceipt"])
                self.assertFalse(result["sourceReceipt"]["captureCertified"])
                self.assertEqual(result["sourceReceipt"]["sourceInputs"], collector.collect(Path(runner.__file__).resolve().parents[1]))
