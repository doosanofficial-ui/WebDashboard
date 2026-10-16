import copy
from datetime import datetime, timedelta
import plistlib
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_preference_restoration as preferences


def observation():
    snapshot = {"present": True, "values": {"telemetry.appLanguage": "en", "clientID": "synthetic"}}
    return {"scope": "synthetic-preference-restoration", "domain": "synthetic.telemetry.preferences",
            "phaseOrder": ["original", "quiesce-before-backup", "trial", "quiesce-before-restore",
                           "restored", "relaunch", "post-lifecycle"],
            "original": {**copy.deepcopy(snapshot), "effectiveLanguage": "en"},
            "restored": copy.deepcopy(snapshot), "postLifecycle": {**copy.deepcopy(snapshot),
                "effectiveLanguage": "en", "freshStore": True},
            "barriers": {phase: {"acknowledged": True, "pendingWrites": 0}
                         for phase in ("beforeBackup", "beforeRestore")},
            "launchArguments": [], "fileInventoryMatches": True}


class PreferenceRestorationContractTests(unittest.TestCase):
    def test_equal_bytes_with_a_retained_stale_store_are_not_restored(self):
        data = observation()
        data["postLifecycle"].update(effectiveLanguage="ko", freshStore=False)
        result = preferences.evaluate(data, expected_domain="synthetic.telemetry.preferences")
        self.assertFalse(result["syntheticContractSatisfied"])
        self.assertIn("fresh-effective-state-required", result["issues"])
        self.assertIn("effective-language-mismatch", result["issues"])
        self.assertFalse(result["nativeRestorationCertified"])

    def assess(self, data):
        return preferences.evaluate(data, expected_domain="synthetic.telemetry.preferences")

    def test_complete_synthetic_evidence_never_certifies_native_execution(self):
        result = self.assess(observation())
        self.assertTrue(result["syntheticContractSatisfied"])
        self.assertFalse(result["nativeRestorationCertified"])
        self.assertFalse(result["nativeExecutionAllowed"])
        self.assertFalse(result["realWriterCacheBoundaryVerified"])

    def test_missing_acknowledgement_pending_and_invalid_writer_counts_block(self):
        for phase in ("beforeBackup", "beforeRestore"):
            for value in (None, [], {}, {"acknowledged": False, "pendingWrites": 0},
                          {"acknowledged": True, "pendingWrites": 1},
                          {"acknowledged": True, "pendingWrites": False}):
                data = observation()
                data["barriers"][phase] = value
                with self.subTest(phase=phase, value=value):
                    self.assertIn("writer-boundary-unconfirmed-" + phase, self.assess(data)["issues"])

    def test_language_overrides_cannot_mask_an_incorrect_persistent_domain(self):
        for flag in ("--app-language", "-AppleLanguages", "-AppleLocale", "-telemetry.appLanguage",
                     "--app-language=en"):
            data = observation()
            data["launchArguments"] = [flag, "en"]
            data["restored"]["values"]["telemetry.appLanguage"] = "ko"
            self.assertIn("language-override-masks-restoration", self.assess(data)["issues"])
            self.assertIn("restored-domain-drift", self.assess(data)["issues"])

    def test_domain_presence_full_values_and_plist_types_are_preserved(self):
        data = observation()
        for key in ("original", "restored", "postLifecycle"):
            data[key].update(present=False, values={})
        self.assertTrue(self.assess(data)["syntheticContractSatisfied"])
        data["postLifecycle"].update(present=True, values={})
        self.assertIn("post-lifecycle-domain-drift", self.assess(data)["issues"])
        data = observation()
        data["postLifecycle"]["values"]["new-unaccounted-key"] = "synthetic"
        self.assertIn("post-lifecycle-domain-drift", self.assess(data)["issues"])
        data = observation()
        data["original"]["values"]["number"] = 1
        data["restored"]["values"]["number"] = True
        self.assertIn("restored-domain-drift", self.assess(data)["issues"])

    def test_phase_domain_scope_and_inventory_fail_closed(self):
        for mutation, issue in ((lambda d: d["phaseOrder"].reverse(), "missing-duplicated-or-out-of-order-phase"),
                                (lambda d: d["phaseOrder"].append("post-lifecycle"), "missing-duplicated-or-out-of-order-phase"),
                                (lambda d: d.update(domain="foreign.domain"), "wrong-preference-domain"),
                                (lambda d: d.update(scope="native"), "unsupported-observation-scope"),
                                (lambda d: d.update(fileInventoryMatches=False), "file-inventory-not-restored")):
            data = observation()
            mutation(data)
            self.assertIn(issue, self.assess(data)["issues"])

    @unittest.skipUnless(sys.platform == "darwin", "Requires Darwin synthetic metadata restoration")
    def test_late_writer_after_a_real_synthetic_file_restore_is_rejected(self):
        import synthetic_data_preservation as preservation
        workspace = preservation.SyntheticWorkspace()
        self.addCleanup(workspace.cleanup)
        root = workspace.root / "data"
        root.mkdir()
        path = root / "synthetic.preferences.plist"
        data = observation()
        original = data["original"]["values"]
        path.write_bytes(plistlib.dumps(original))
        before = preservation.inventory(root, workspace=workspace)
        pending = {**original, "telemetry.appLanguage": "ko"}
        with preservation.PreservedSyntheticData(root, workspace.root / "evidence",
                                                  workspace=workspace, quiesce=lambda phase: True):
            path.write_bytes(plistlib.dumps(pending))
        self.assertEqual(plistlib.loads(path.read_bytes()), original)
        self.assertEqual(preservation.inventory(root, workspace=workspace), before)
        # Deliberately release our own synthetic writer only after verified restore.
        path.write_bytes(plistlib.dumps(pending))
        data["postLifecycle"].update(values=plistlib.loads(path.read_bytes()), effectiveLanguage="ko")
        data["fileInventoryMatches"] = preservation.inventory(root, workspace=workspace) == before
        result = self.assess(data)
        self.assertIn("post-lifecycle-domain-drift", result["issues"])
        self.assertIn("file-inventory-not-restored", result["issues"])

    def test_equal_plist_values_ignore_container_aliasing_and_dictionary_order(self):
        shared = [{"languages": ["en", "ko"], "count": 1, "enabled": True}]
        aliased = {"first": shared, "second": shared}
        independent = {"second": [{"enabled": True, "count": 1, "languages": ["en", "ko"]}],
                       "first": [{"languages": ["en", "ko"], "enabled": True, "count": 1}]}
        for original, restored in ((aliased, independent), (independent, aliased)):
            with self.subTest(originalSharesList=original["first"] is original["second"]):
                data = observation()
                data["original"]["values"].update(original)
                data["restored"]["values"].update(restored)
                data["postLifecycle"]["values"].update(copy.deepcopy(restored))
                result = self.assess(data)
                self.assertTrue(result["syntheticContractSatisfied"], result)
                self.assertFalse(result["nativeRestorationCertified"])

    def test_nested_plist_type_array_order_and_value_mismatches_are_rejected(self):
        values = {"nested": [True, 1, 1.5, "en", b"synthetic", {"date": datetime(2026, 10, 17)}]}
        mutations = (lambda v: v["nested"].__setitem__(0, 1),
                     lambda v: v["nested"].__setitem__(1, 1.0),
                     lambda v: v["nested"].reverse(),
                     lambda v: v["nested"].__setitem__(3, "ko"),
                     lambda v: v["nested"].__setitem__(4, b"different"),
                     lambda v: v["nested"][5].__setitem__("date", datetime(2026, 10, 17) + timedelta(seconds=1)),
                     lambda v: v.pop("nested"), lambda v: v.update(extra="unaccounted"))
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                data = observation()
                for phase in ("original", "restored", "postLifecycle"):
                    data[phase]["values"].update(copy.deepcopy(values))
                mutate(data["restored"]["values"])
                data["postLifecycle"]["values"] = copy.deepcopy(data["restored"]["values"])
                result = self.assess(data)
                self.assertFalse(result["syntheticContractSatisfied"])
                self.assertIn("restored-domain-drift", result["issues"])
                self.assertIn("post-lifecycle-domain-drift", result["issues"])
                self.assertFalse(result["nativeRestorationCertified"])

    def test_invalid_or_cyclic_plist_values_fail_closed(self):
        cycle = []
        cycle.append(cycle)
        for invalid in (object(), {1: "non-string-key"}, cycle):
            data = observation()
            for phase in ("original", "restored", "postLifecycle"):
                data[phase]["values"]["invalid"] = invalid
            result = self.assess(data)
            self.assertFalse(result["syntheticContractSatisfied"])
            self.assertTrue(any(issue.startswith("invalid-domain-observation:") for issue in result["issues"]))
            self.assertFalse(result["nativeRestorationCertified"])
