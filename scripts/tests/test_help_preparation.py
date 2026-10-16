"""Source-only Help contract tests; fixtures have no PNGs or native data."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_help_assets as assets
import verify_help_preparation as preparation
import verify_help_memory_contract as memory_checks
from unittest.mock import patch

ROOT = Path(os.environ.get("HELP_PREPARATION_REPO", Path(__file__).resolve().parents[2]))


class HelpPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="help-source-preparation-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        names = assets.expected_screen_inputs(ROOT) | {
            preparation.HELP_SOURCE, preparation.LANGUAGE_SOURCE,
            "mobile-ios/UITests/LocalizationHelpUITests.swift",
            "scripts/verify_offline_replay.py",
            "mobile-ios/App/Resources/HelpScreenshots/manifest.json",
        }
        for name in names:
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, destination)
        self.source_fixture()

    def source_fixture(self, *, stale=False):
        # This temporary source-only fixture never inherits the bundled asset's
        # freshness. It contains no PNGs and cannot certify a native capture.
        path = self.root / "mobile-ios/App/Resources/HelpScreenshots/manifest.json"
        manifest = json.loads(path.read_text())
        manifest["screenInputs"] = assets.source_input_hashes(self.root)
        manifest["unitFixtureScope"] = "synthetic source audit only; no capture certificate"
        path.write_text(json.dumps(manifest))
        if stale:
            source = self.root / "mobile-ios/App/DashboardView.swift"
            source.write_text(source.read_text() + "\n// deliberate temporary source drift\n")
        self.before = self.inventory()

    def inventory(self):
        return {str(path.relative_to(self.root)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in self.root.rglob("*") if path.is_file()}

    def test_plan_uses_actual_capture_order_and_all_twenty_eight_targets(self):
        report = preparation.build_plan(self.root)
        rows = report["captureTargets"]
        self.assertEqual(len(rows), 28)
        self.assertEqual(len({row["imageName"] for row in rows}), 28)
        expected = [("live", 1), ("live", 2), ("live", 3), ("editor", 1), ("editor", 2),
                    ("setup", 1), ("setup", 2), ("sessions", 1), ("sessions", 2),
                    ("sessions", 3), ("replay", 1), ("replay", 2), ("signals", 2), ("signals", 1)]
        for language in ("en", "ko"):
            self.assertEqual([(row["guideID"], row["stepNumber"]) for row in rows
                              if row["language"] == language], expected)
        self.assertEqual({row["imageName"]: row["targetID"] for row in rows},
                         assets.expected_capture_targets((self.root / preparation.HELP_SOURCE).read_text()))
        self.assertEqual(self.inventory(), self.before)

    def test_clean_source_inventory_is_still_only_preparation(self):
        self.source_fixture()
        report = preparation.build_plan(self.root)
        self.assertTrue(report["sourceAudit"]["sourceInputsMatch"])
        self.assertEqual(report["sourceAudit"]["missingSourceInputs"], [])
        self.assertEqual(report["sourceAudit"]["staleSourceInputs"], [])
        self.assertFalse(report["nativeExecutionAllowed"])
        self.assertFalse(report["fullAssetVerificationPerformed"])
        self.assertEqual(self.inventory(), self.before)

    def test_new_nested_source_requires_a_new_inventory_entry(self):
        self.source_fixture()
        relative = "mobile-ios/App/SyntheticPreparationFixture/Additional.swift"
        source = self.root / relative
        self.assertFalse(source.exists())
        source.parent.mkdir(parents=True)
        source.write_text("// temporary new capture input\n")
        before = self.inventory()
        audit = preparation.build_plan(self.root)["sourceAudit"]
        self.assertEqual(audit["missingSourceInputs"], [relative])
        self.assertEqual(audit["staleSourceInputs"], [])
        self.assertFalse(audit["sourceInputsMatch"])
        self.assertEqual(self.inventory(), before)

    def test_source_drift_never_becomes_native_execution_or_asset_success(self):
        self.source_fixture(stale=True)
        report = preparation.build_plan(self.root)
        self.assertEqual(report["sourceAudit"]["missingSourceInputs"], [])
        self.assertEqual(report["sourceAudit"]["staleSourceInputs"], ["mobile-ios/App/DashboardView.swift"])
        self.assertFalse(report["nativeExecutionAllowed"])
        self.assertFalse(report["nativeRestorationCertified"])
        self.assertFalse(report["assetFilesModified"])
        self.assertFalse(report["fullAssetVerificationPerformed"])
        self.assertFalse(report["productProposalApplied"])
        self.assertEqual(list(self.root.rglob("*.png")), [])

    def test_capture_selectors_and_persistence_regression_are_distinct(self):
        report = preparation.build_plan(self.root)
        self.assertEqual(len(report["captureSelectors"]), 2)
        self.assertEqual(len(report["regressionSelectors"]), 4)
        self.assertTrue(any("Persists" in name for name in report["regressionSelectors"]))
        self.assertFalse(any("Persists" in name for name in report["captureSelectors"]))
        self.assertEqual(report["preferenceReview"]["initialOverrideScope"], "initial-display-only")
        self.assertTrue(report["preferenceReview"]["explicitSelectionPersists"])
        self.assertFalse(report["preferenceReview"]["actualWriterCacheBoundaryImplemented"])

    def test_changed_capture_body_requires_review_instead_of_guessing_state(self):
        path = self.root / preparation.CAPTURE_SOURCE
        path.write_text(path.read_text().replace("continueAfterFailure=false", "continueAfterFailure=true", 1))
        with self.assertRaisesRegex(preparation.PreparationError, "Capture body changed"):
            preparation.build_plan(self.root)

    def test_duplicate_missing_and_wrong_anchor_capture_calls_are_rejected(self):
        body = preparation.capture_body((self.root / preparation.CAPTURE_SOURCE).read_text())
        expected = assets.expected_capture_targets((self.root / preparation.HELP_SOURCE).read_text())
        line = '        capture(app,"live",language,1,app.buttons["toggle-recording"])'
        bad = (body + "\n" + line, body.replace(line, ""),
               body.replace('capture(app,"live",language,1,app.buttons["toggle-recording"])',
                            'capture(app,"live",language,1,app.buttons["wrong-anchor"])'))
        for source in bad:
            with self.subTest(source=source[-80:]):
                with self.assertRaises(preparation.PreparationError):
                    preparation.capture_contract(source, expected)

    def test_unknown_dynamic_capture_target_is_rejected(self):
        body = preparation.capture_body((self.root / preparation.CAPTURE_SOURCE).read_text())
        body = body.replace('capture(app,"sessions",language,1,picker)',
                            'capture(app,"sessions",language,1,unknownTarget)')
        expected = assets.expected_capture_targets((self.root / preparation.HELP_SOURCE).read_text())
        with self.assertRaisesRegex(preparation.PreparationError, "Unknown capture target"):
            preparation.capture_contract(body, expected)

    def test_copy_proposal_is_data_only_for_two_guides_and_does_not_change_targets(self):
        original = (self.root / preparation.HELP_SOURCE).read_text()
        candidate = preparation.proposed_help_source(original)
        self.assertIn('case "live":', candidate)
        self.assertIn('case "setup":', candidate)
        self.assertIn("before recording or GPS is started", candidate)
        self.assertIn("프로필을 가져오기 전", candidate)
        self.assertIn('if let note = guide.screenshotStateNote', candidate)
        self.assertEqual(assets.expected_capture_targets(original), assets.expected_capture_targets(candidate))
        original_steps = [line for line in original.splitlines() if '.init(id:' in line]
        candidate_steps = [line for line in candidate.splitlines() if '.init(id:' in line]
        self.assertEqual(candidate_steps, original_steps)
        self.assertEqual(self.inventory(), self.before)

    def test_copy_proposal_refuses_an_unreviewed_product_source(self):
        original = (self.root / preparation.HELP_SOURCE).read_text()
        with self.assertRaisesRegex(preparation.PreparationError, "Help source changed"):
            preparation.proposed_help_source(original + "\n// unreviewed source\n")

    def test_language_harness_refuses_unreviewed_or_qualified_real_preferences(self):
        source = (self.root / preparation.LANGUAGE_SOURCE).read_text()
        prefix = preparation.language_store_source(source)
        self.assertIn("final class AppLanguageStore", prefix)
        self.assertNotIn("enum AppLocalization", prefix)
        with self.assertRaisesRegex(preparation.PreparationError, "Language store source changed"):
            preparation.language_store_source(source.replace("defaults.set(", "Foundation.UserDefaults.standard.set("))

    def test_failed_host_check_retains_the_actual_stdout_failure(self):
        result = subprocess.CompletedProcess(["synthetic-no-process"], 7, '{"failed":1,"cause":"memory fixture"}', "")
        with patch.object(subprocess, "run", return_value=result):
            with self.assertRaisesRegex(preparation.PreparationError, 'exit 7.*memory fixture'):
                memory_checks.checked(["synthetic-no-process"])

    def test_host_driver_stops_before_process_launch_for_unreviewed_preferences(self):
        path = self.root / preparation.LANGUAGE_SOURCE
        path.write_text(path.read_text().replace("defaults.set(", "Foundation.UserDefaults.standard.set("))
        with patch.object(subprocess, "run", side_effect=AssertionError("Unreviewed code must not execute")):
            with self.assertRaises(preparation.PreparationError):
                memory_checks.run(self.root)

    def test_proposed_patch_is_exactly_the_reviewed_candidate(self):
        patch = preparation.proposal_patch((self.root / preparation.HELP_SOURCE).read_text())
        committed = Path(preparation.__file__).parent / "fixtures/help-safe-preparation/example-state-note.patch"
        self.assertEqual(committed.read_text(), patch)
        self.assertTrue(patch.startswith("--- a/mobile-ios/App/AppHelpView.swift\n"))

    def test_cli_is_read_only_and_zero_for_a_clean_source_fixture(self):
        self.source_fixture()
        result = subprocess.run([sys.executable, "-B", "-O", str(Path(preparation.__file__)),
                                 "--root", str(self.root)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["sourceAudit"]["sourceInputsMatch"])
        self.assertFalse(report["nativeExecutionAllowed"])
        self.assertFalse(report["fullAssetVerificationPerformed"])
        self.assertEqual(self.inventory(), self.before)

    def test_cli_is_read_only_and_remains_nonzero_for_provenance_drift(self):
        self.source_fixture(stale=True)
        result = subprocess.run([sys.executable, "-B", "-O", str(Path(preparation.__file__)),
                                 "--root", str(self.root)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(len(report["captureTargets"]), 28)
        self.assertFalse(report["nativeExecutionAllowed"])
        self.assertEqual(self.inventory(), self.before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
