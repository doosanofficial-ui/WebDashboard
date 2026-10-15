"""Darwin filesystem regressions on fresh disposable fixtures only."""
import getpass
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import darwin_file_metadata as metadata
import synthetic_data_preservation as preservation


@unittest.skipUnless(sys.platform == "darwin", "Requires actual Darwin ACL/xattr support")
class SyntheticMetadataTests(unittest.TestCase):
    def setUp(self):
        self.workspace = preservation.SyntheticWorkspace()
        self.addCleanup(self.workspace.cleanup)
        self.data = self.workspace.root / "fixture-data"
        self.evidence = self.workspace.root / "evidence"
        self.directory = self.data / "nested"
        self.directory.mkdir(parents=True)
        self.file = self.directory / "original.bin"
        self.file.write_bytes(b"original synthetic bytes\x00\xff")
        self.paths = (self.data, self.directory, self.file)

    def transaction(self, **kwargs):
        return preservation.PreservedSyntheticData(
            self.data, self.evidence, workspace=self.workspace,
            quiesce=kwargs.pop("quiesce", lambda phase: True), **kwargs)

    def recover(self):
        return preservation.recover(self.data, self.evidence, workspace=self.workspace,
                                    quiesce=lambda phase: True)

    def cli(self, *arguments):
        return subprocess.run(arguments, check=True, capture_output=True, text=True).stdout

    def xattr(self, path, name, hex_value):
        self.cli("/usr/bin/xattr", "-wx", name, hex_value, str(path))

    def seed(self):
        for index, path in enumerate(self.paths):
            self.xattr(path, "org.webdashboard.synthetic.binary", "00ff010203")
            self.xattr(path, "org.webdashboard.synthetic.empty", "")
            self.cli("/bin/chmod", "+a", "user:" + getpass.getuser()
                     + " allow readattr,readextattr,readsecurity", str(path))
            self.cli("/bin/chmod", "+a", "everyone allow readattr", str(path))
            path.chmod(0o750 if path.is_dir() else 0o640)
            os.utime(path, ns=(1700000000000000000, 1700000000123456000 + index * 1000))
        return {path.relative_to(self.data).as_posix(): metadata.snapshot(path) for path in self.paths}

    def mutate_metadata(self):
        for path in self.paths:
            self.xattr(path, "org.webdashboard.synthetic.binary", "deadbeef")
            self.cli("/usr/bin/xattr", "-d", "org.webdashboard.synthetic.empty", str(path))
            self.xattr(path, "org.webdashboard.synthetic.trial-only", "22")
            self.cli("/bin/chmod", "-N", str(path))
            self.cli("/bin/chmod", "+a", "everyone allow readextattr", str(path))
            path.chmod(0o700 if path.is_dir() else 0o600)
        self.file.write_bytes(b"trial synthetic bytes")
        (self.data / "introduced").write_bytes(b"originally absent")

    def receipt(self):
        return json.loads((self.evidence / "transaction.json").read_text())

    def inventory(self, root=None, **kwargs):
        return preservation.inventory(root or self.data, workspace=self.workspace, **kwargs)

    def independent_metadata(self, path):
        # Independent OS tools verify ACL entry order and exact xattr contents.
        acl = self.cli("/bin/ls", "-lde", str(path)).splitlines()[1:]
        names = self.cli("/usr/bin/xattr", str(path)).splitlines()
        attrs = {name: "".join(self.cli("/usr/bin/xattr", "-px", name, str(path)).split())
                 for name in names}
        info = path.stat()
        return acl, attrs, info.st_mode & 0o7777, info.st_mtime_ns, info.st_uid, info.st_gid, info.st_flags

    def test_complete_root_directory_file_metadata_roundtrip(self):
        self.seed()
        expected = [self.independent_metadata(path) for path in self.paths]
        root_inode = self.data.stat().st_ino
        with self.transaction():
            self.mutate_metadata()
        self.assertEqual([self.independent_metadata(path) for path in self.paths], expected)
        self.assertEqual(self.file.read_bytes(), b"original synthetic bytes\x00\xff")
        self.assertFalse((self.data / "introduced").exists())
        self.assertEqual(self.data.stat().st_ino, root_inode)
        for relative, item in zip((".", "nested", "nested/original.bin"), expected):
            self.assertEqual(self.independent_metadata(self.evidence / "original" / relative), item)
        self.assertEqual(self.receipt()["status"], "RESTORED_VERIFIED")

    def test_original_absent_acl_and_attributes_are_absent_again(self):
        before = self.inventory()
        with self.transaction():
            self.seed()
        self.assertEqual(self.inventory(), before)
        for path in self.paths:
            self.assertEqual(self.cli("/bin/ls", "-lde", str(path)).splitlines()[1:], [])
            self.assertNotIn("org.webdashboard.synthetic", self.cli("/usr/bin/xattr", str(path)))

    def test_backup_metadata_loss_blocks_body_without_changing_original(self):
        self.seed()
        before = self.inventory()
        copy = preservation._copy_tree

        def lose_acl(source, destination, expected):
            copy(source, destination, expected)
            self.cli("/bin/chmod", "-N", str(destination / "nested"))

        with patch.object(preservation, "_copy_tree", side_effect=lose_acl):
            with self.assertRaises(preservation.PreservationError):
                with self.transaction():
                    self.fail("Metadata loss must stop before the body")
        self.assertEqual(self.inventory(), before)
        self.assertEqual(self.receipt()["status"], "BACKUP_FAILED")
        self.assertFalse(self.receipt()["backupVerified"])

    def test_staging_metadata_loss_stops_before_any_trial_moves(self):
        self.seed()
        before = self.inventory()
        copy = preservation._copy_tree

        def lose_attribute(source, destination, expected):
            copy(source, destination, expected)
            if destination.name.startswith("stage-"):
                self.cli("/usr/bin/xattr", "-d", "org.webdashboard.synthetic.empty", str(destination))

        with patch.object(preservation, "_copy_tree", side_effect=lose_attribute):
            with self.assertRaises(preservation.RecoveryRequired):
                with self.transaction():
                    self.mutate_metadata()
                    trial = self.inventory()
        self.assertEqual(self.inventory(), trial)
        self.assertEqual(self.inventory(self.evidence / "original"), before)
        self.assertEqual(self.receipt()["attempts"][0]["moves"], [])
        self.assertEqual(self.receipt()["status"], "RECOVERY_REQUIRED")
        self.recover()
        self.assertEqual(self.inventory(), before)

    def test_acl_and_xattr_read_errors_never_mean_absent(self):
        self.seed()
        before = [self.independent_metadata(path) for path in self.paths]
        for method in ("_acl", "_attributes"):
            with self.subTest(method=method):
                with patch.object(metadata, method, side_effect=metadata.MetadataError("synthetic denied")):
                    with self.assertRaises(preservation.PreservationError):
                        with self.transaction():
                            self.fail("Unreadable metadata is not an empty metadata set")
                self.assertFalse(self.evidence.exists())
                self.assertEqual([self.independent_metadata(path) for path in self.paths], before)

    def test_backup_metadata_tampering_keeps_trial_data_untouched(self):
        self.seed()
        with self.assertRaises(preservation.RecoveryRequired):
            with self.transaction():
                self.mutate_metadata()
                trial = self.inventory()
                self.xattr(self.evidence / "original", "org.webdashboard.synthetic.binary", "77")
        self.assertEqual(self.inventory(), trial)
        self.assertEqual(self.receipt()["status"], "RECOVERY_REQUIRED")
        self.assertEqual(self.receipt()["attempts"], [])

    def test_root_metadata_failure_retains_backup_and_trial_for_recovery(self):
        self.seed()
        before = self.inventory()
        apply = metadata.apply

        def fail_at_root(path, expected):
            if path == self.data:
                raise metadata.MetadataError("synthetic root restore failure")
            return apply(path, expected)

        with patch.object(metadata, "apply", side_effect=fail_at_root):
            with self.assertRaises(preservation.RecoveryRequired):
                with self.transaction():
                    self.mutate_metadata()
                    trial = self.inventory()
        receipt = self.receipt()
        quarantine = self.evidence / receipt["attempts"][0]["trial"]
        self.assertEqual(self.inventory(quarantine), trial)
        self.assertEqual(self.inventory(self.evidence / "original"), before)
        self.assertEqual(receipt["status"], "RECOVERY_REQUIRED")
        self.assertFalse(receipt["attempts"][0]["verified"])
        self.recover()
        self.assertEqual(self.inventory(), before)
        self.assertEqual(self.inventory(quarantine), trial)

    def test_final_inventory_detects_root_attribute_write_after_restore(self):
        self.seed()
        before = self.inventory()
        apply = metadata.apply

        def concurrent_metadata_write(path, expected):
            apply(path, expected)
            if path == self.data:
                self.xattr(path, "org.webdashboard.synthetic.race", "99")

        with patch.object(metadata, "apply", side_effect=concurrent_metadata_write):
            with self.assertRaises(preservation.RecoveryRequired):
                with self.transaction():
                    self.mutate_metadata()
        self.assertEqual(self.receipt()["status"], "RECOVERY_REQUIRED")
        self.recover()
        self.assertEqual(self.inventory(), before)

    def test_outside_workspace_is_rejected_before_stat_or_resolve(self):
        # Deliberately fictitious path; no user/native path is inspected.
        with patch.object(Path, "lstat", side_effect=AssertionError("Outside path was probed")):
            with patch.object(Path, "resolve", side_effect=AssertionError("Outside path was resolved")):
                with self.assertRaises(preservation.PreservationError):
                    preservation.PreservedSyntheticData(
                        Path("/not-inspected/fictitious-data"), self.evidence,
                        workspace=self.workspace, quiesce=lambda phase: True)

    def test_workspace_symlink_cannot_retarget_the_fixture(self):
        link = self.workspace.root / "link"
        link.symlink_to(self.data, target_is_directory=True)
        with self.assertRaises(preservation.PreservationError):
            preservation.PreservedSyntheticData(link / "nested", self.evidence,
                                                workspace=self.workspace, quiesce=lambda phase: True)

    def test_unsupported_file_flags_stop_before_body(self):
        snapshot = metadata.snapshot

        def flagged(path):
            result = snapshot(path)
            result["flags"] = 2
            return result

        with patch.object(metadata, "snapshot", side_effect=flagged):
            with self.assertRaises(preservation.PreservationError):
                with self.transaction():
                    self.fail("Unsupported flags must stop before the body")
        self.assertFalse(self.evidence.exists())

    def test_receipt_cannot_certify_native_or_cache_boundaries(self):
        self.seed()
        with self.transaction():
            self.mutate_metadata()
        receipt = self.receipt()
        self.assertEqual(receipt["schema"], 2)
        self.assertTrue(receipt["syntheticOnly"])
        self.assertFalse(receipt["nativeRestorationCertified"])
        self.assertIn("actualWriterQuiescence", receipt["uncertifiedDimensions"])
        self.assertIn("effectivePreferencesCache", receipt["uncertifiedDimensions"])

    def test_tampered_scope_receipt_cannot_be_promoted_by_recovery(self):
        with self.transaction():
            self.file.write_bytes(b"synthetic trial")
        path = self.evidence / "transaction.json"
        receipt = self.receipt()
        receipt["nativeRestorationCertified"] = True
        path.write_text(json.dumps(receipt))
        before = self.inventory()
        with self.assertRaises(preservation.RecoveryRequired):
            self.recover()
        self.assertEqual(self.inventory(), before)
        self.assertEqual(self.receipt()["status"], "RECOVERY_REQUIRED")


if __name__ == "__main__":
    unittest.main(verbosity=2)
