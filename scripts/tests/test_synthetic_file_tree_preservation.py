"""Only synthetic files in TemporaryDirectory; never contacts a Simulator."""
import importlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


@unittest.skipUnless(sys.platform == "darwin", "Requires actual Darwin ACL/xattr support")
class SyntheticFileTreeTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(importlib.util.find_spec("synthetic_data_preservation"),
                             "Verified full-data backup and restoration are missing")
        self.m = importlib.import_module("synthetic_data_preservation")
        self.workspace = self.m.SyntheticWorkspace()
        self.addCleanup(self.workspace.cleanup)
        self.base = self.workspace.root
        self.data = self.base / "synthetic-app-data"
        self.data.mkdir()
        self.evidence = self.base / "evidence"
        self.put("Library/Application Support/Telemetry/dashboard.json", b'original dashboard')
        self.put("Library/Application Support/Telemetry/outbox.sqlite3-wal", b'original WAL')
        self.put("Library/Preferences/local.webdashboard.Telemetry.plist",
                 plistlib.dumps({"telemetry.appLanguage": "en", "clientID": "synthetic-only"}))
        self.put("Library/Preferences/ByHost/example.plist", b'other preferences')
        self.put("Documents/keep.txt", b'keep this')
        self.put(".hidden", b'keep hidden')
        (self.data / "tmp/empty").mkdir(parents=True)
        self.before = self.inventory(self.data)
        self.phases = []

    def inventory(self, root, **kwargs):
        return self.m.inventory(root, workspace=self.workspace, **kwargs)

    def put(self, relative, content):
        target = self.data / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        return target

    def quiesce(self, phase):
        self.phases.append(phase)
        return True  # No app or preferences service exists in this synthetic fixture.

    def transaction(self, quiesce=None):
        return self.m.PreservedSyntheticData(self.data, self.evidence,
                                       workspace=self.workspace, quiesce=quiesce or self.quiesce)

    def mutate(self):
        self.put("Library/Application Support/Telemetry/dashboard.json", b'synthetic dashboard')
        self.put("Library/Application Support/Telemetry/measurements.sqlite3", b'synthetic DB')
        self.put("Library/Application Support/Telemetry/measurements.sqlite3-shm", b'synthetic SHM')
        self.put("Library/Preferences/local.webdashboard.Telemetry.plist",
                 plistlib.dumps({"telemetry.appLanguage": "ko", "clientID": "changed"}))
        (self.data / "Documents/keep.txt").unlink()
        self.put("new-root/new.txt", b'new trial file')

    def receipt(self):
        return json.loads((self.evidence / "transaction.json").read_text())

    def test_success_restores_all_files_preferences_and_absence(self):
        with self.transaction():
            self.assertEqual(self.inventory(self.evidence / "original"), self.before)
            self.mutate()
            trial = self.inventory(self.data)
        self.assertEqual(self.inventory(self.data), self.before)
        self.assertEqual(self.inventory(self.evidence / "original"), self.before)
        # Check the original defect directly, independently of inventory().
        preferences = plistlib.loads((self.data / "Library/Preferences/local.webdashboard.Telemetry.plist").read_bytes())
        self.assertEqual(preferences, {"telemetry.appLanguage": "en", "clientID": "synthetic-only"})
        self.assertEqual((self.data / "Documents/keep.txt").read_bytes(), b'keep this')
        self.assertFalse((self.data / "Library/Application Support/Telemetry/measurements.sqlite3").exists())
        trial_path = self.evidence / self.receipt()["attempts"][0]["trial"]
        self.assertEqual(self.inventory(trial_path), trial)
        self.assertEqual(self.phases, ["before-backup", "before-restore"])
        self.assertEqual(self.receipt()["status"], "RESTORED_VERIFIED")

    def test_exception_timeout_keyboard_interrupt_and_system_exit_restore(self):
        for index, error in enumerate((RuntimeError("test failed"), TimeoutError("timeout"),
                                       KeyboardInterrupt(), SystemExit(7))):
            with self.subTest(error=type(error).__name__):
                self.evidence = self.base / ("evidence-" + str(index))
                with self.assertRaises(type(error)):
                    with self.transaction():
                        self.mutate()
                        raise error
                self.assertEqual(self.inventory(self.data), self.before)
                self.assertEqual(self.receipt()["status"], "RESTORED_VERIFIED")
                self.assertEqual(self.receipt()["operationError"]["type"], type(error).__name__)

    def test_missing_preferences_are_absent_again_after_test_creates_them(self):
        pref = self.data / "Library/Preferences/local.webdashboard.Telemetry.plist"
        pref.unlink()
        before = self.inventory(self.data)
        with self.transaction():
            pref.write_bytes(plistlib.dumps({"telemetry.appLanguage": "ko"}))
        self.assertEqual(self.inventory(self.data), before)
        self.assertFalse(pref.exists())

    def test_corrupt_backup_blocks_action_before_any_data_write(self):
        copy = self.m._copy_tree
        def corrupt(source, destination, *args, **kwargs):
            result = copy(source, destination, *args, **kwargs)
            (Path(destination) / ".hidden").write_bytes(b'corrupt copy')
            return result
        entered = False
        with patch.object(self.m, "_copy_tree", side_effect=corrupt):
            with self.assertRaises(self.m.PreservationError):
                with self.transaction():
                    entered = True
        self.assertFalse(entered)
        self.assertEqual(self.inventory(self.data), self.before)
        self.assertFalse(self.receipt()["backupVerified"])

    def test_source_drift_during_backup_blocks_action(self):
        copy = self.m._copy_tree
        def concurrent_write(source, destination, *args, **kwargs):
            result = copy(source, destination, *args, **kwargs)
            self.put(".hidden", b'concurrent change')
            return result
        with patch.object(self.m, "_copy_tree", side_effect=concurrent_write):
            with self.assertRaises(self.m.PreservationError):
                with self.transaction():
                    self.fail("Unstable original must never enter test action")
        self.assertEqual((self.data / ".hidden").read_bytes(), b'concurrent change')

    def test_copy_failure_blocks_action_and_preserves_original(self):
        with patch.object(self.m, "_copy_tree", side_effect=OSError("synthetic disk full")):
            with self.assertRaises(self.m.PreservationError):
                with self.transaction():
                    self.fail("Backup failed")
        self.assertEqual(self.inventory(self.data), self.before)

    def test_unquiesced_data_blocks_backup(self):
        with self.assertRaises(self.m.PreservationError):
            with self.transaction(quiesce=lambda phase: False):
                self.fail("Writers are not stopped")
        self.assertEqual(self.inventory(self.data), self.before)

    def test_restore_requires_quiescence_and_can_resume_later(self):
        with self.assertRaises(self.m.RecoveryRequired):
            with self.transaction(quiesce=lambda phase: phase == "before-backup"):
                self.mutate()
        self.assertEqual(self.receipt()["status"], "RECOVERY_REQUIRED")
        self.m.recover(self.data, self.evidence, workspace=self.workspace, quiesce=self.quiesce)
        self.assertEqual(self.inventory(self.data), self.before)

    def test_backup_tampering_is_not_reported_as_restored(self):
        with self.assertRaises(self.m.RecoveryRequired):
            with self.transaction():
                self.mutate()
                (self.evidence / "original/.hidden").write_bytes(b'corrupt backup')
        self.assertEqual(self.receipt()["status"], "RECOVERY_REQUIRED")
        self.assertEqual((self.data / ".hidden").read_bytes(), b'keep hidden')
        self.assertTrue((self.data / "new-root/new.txt").exists())

    def test_failure_midway_through_restore_preserves_evidence_and_resumes(self):
        replace = self.m.os.replace
        placements = []
        def failing_restore(source, destination):
            if Path(source).parent.name.startswith("stage-") and Path(destination).parent == self.data:
                placements.append(str(destination))
                if len(placements) == 2:
                    raise OSError("synthetic restore interruption")
            return replace(source, destination)
        with patch.object(self.m.os, "replace", side_effect=failing_restore):
            with self.assertRaises(self.m.RecoveryRequired):
                with self.transaction():
                    self.mutate()
                    raise TimeoutError("native phase timeout (synthetic)")
        self.assertEqual(self.receipt()["operationError"]["type"], "TimeoutError")
        self.assertEqual(self.inventory(self.evidence / "original"), self.before)
        trial = self.evidence / self.receipt()["attempts"][0]["trial"]
        self.assertEqual((trial / "new-root/new.txt").read_bytes(), b'new trial file')
        self.m.recover(self.data, self.evidence, workspace=self.workspace, quiesce=self.quiesce)
        self.assertEqual(self.inventory(self.data), self.before)
        self.assertEqual(self.receipt()["status"], "RESTORED_VERIFIED")

    def test_restore_verification_detects_write_and_later_recovers(self):
        replace = self.m.os.replace
        def damage_restored_file(source, destination):
            result = replace(source, destination)
            if Path(source).parent.name.startswith("stage-") and Path(destination) == self.data / ".hidden":
                Path(destination).write_bytes(b'damaged after restore')
            return result
        with patch.object(self.m.os, "replace", side_effect=damage_restored_file):
            with self.assertRaises(self.m.RecoveryRequired):
                with self.transaction():
                    self.mutate()
        self.assertEqual(self.receipt()["status"], "RECOVERY_REQUIRED")
        self.m.recover(self.data, self.evidence, workspace=self.workspace, quiesce=self.quiesce)
        self.assertEqual(self.inventory(self.data), self.before)

    def test_symlinks_hardlinks_and_special_files_fail_closed(self):
        outside = self.base / "outside.txt"
        outside.write_bytes(b'outside must stay untouched')
        entries = ("symlink", "hardlink", "fifo")
        for kind in entries:
            with self.subTest(kind=kind):
                entry = self.data / kind
                if kind == "symlink": entry.symlink_to(outside)
                elif kind == "hardlink": os.link(outside, entry)
                else: os.mkfifo(entry)
                try:
                    with self.assertRaises(self.m.PreservationError):
                        with self.transaction():
                            self.fail("Unsupported entries must not be followed")
                finally:
                    entry.unlink()
                self.assertEqual(outside.read_bytes(), b'outside must stay untouched')

    def test_overlapping_or_reused_evidence_is_rejected(self):
        for evidence in (self.data / "nested-backup", self.data, self.base):
            with self.subTest(evidence=str(evidence)):
                with self.assertRaises(self.m.PreservationError):
                    with self.m.PreservedSyntheticData(self.data, evidence, workspace=self.workspace, quiesce=self.quiesce):
                        self.fail("Evidence must be new and outside the data tree")
        self.assertEqual(self.inventory(self.data), self.before)

    def test_file_mode_and_mtime_are_restored(self):
        original = self.data / ".hidden"
        original.chmod(0o640)
        os.utime(original, ns=(1700000000000000000, 1700000000123456000))
        before = self.inventory(self.data)
        with self.transaction():
            original.chmod(0o600)
            original.write_bytes(b'changed')
        self.assertEqual(self.inventory(self.data), before)

    def test_root_mode_is_restored_without_replacing_inode(self):
        self.data.chmod(0o750)
        original_inode = self.data.stat().st_ino
        with self.transaction():
            self.data.chmod(0o700)
        self.assertEqual(self.data.stat().st_mode & 0o777, 0o750)
        self.assertEqual(self.data.stat().st_ino, original_inode)
        self.assertEqual(self.receipt()["status"], "RESTORED_VERIFIED")

    def test_read_only_root_blocks_trial_before_body(self):
        self.data.chmod(0o550)
        entered = False
        try:
            with self.assertRaises(self.m.PreservationError):
                with self.transaction():
                    entered = True
            self.assertFalse(entered, "A read-only root cannot safely host the trial")
        finally:
            self.data.chmod(0o750)

    def test_explicit_recovery_quarantines_links_after_writer_block(self):
        outside = self.base / "recovery-outside.txt"
        outside.write_bytes(b'outside recovery bytes')
        with self.assertRaises(self.m.RecoveryRequired):
            with self.transaction(quiesce=lambda phase: phase == "before-backup"):
                (self.data / "new-symlink").symlink_to(outside)
                os.link(outside, self.data / "new-hardlink")
                os.mkfifo(self.data / "new-fifo")
                self.mutate()
        self.m.recover(self.data, self.evidence, workspace=self.workspace, quiesce=self.quiesce)
        self.assertEqual(self.inventory(self.data), self.before)
        self.assertEqual(outside.read_bytes(), b'outside recovery bytes')
        self.assertEqual(self.receipt()["status"], "RESTORED_VERIFIED")

    def test_trial_links_and_fifo_are_quarantined_without_following(self):
        outside = self.base / "outside-trial.txt"
        outside.write_bytes(b'external bytes remain unchanged')
        original = outside.stat()
        original_data = self.data
        for kind in ("symlink", "hardlink", "fifo"):
            with self.subTest(kind=kind):
                self.data = self.base / ("trial-data-" + kind)
                self.m._copy_tree(original_data, self.data, self.before)
                self.evidence = self.base / ("trial-entry-" + kind)
                with self.transaction():
                    entry = self.data / "introduced"
                    if kind == "symlink": entry.symlink_to(outside)
                    elif kind == "hardlink": os.link(outside, entry)
                    else: os.mkfifo(entry)
                    self.mutate()
                    trial_inode = entry.lstat().st_ino
                self.assertEqual(self.inventory(self.data), self.before)
                self.assertFalse((self.data / "introduced").exists())
                trial = self.evidence / self.receipt()["attempts"][0]["trial"]
                self.assertEqual((trial / "introduced").lstat().st_ino, trial_inode)
                if kind == "symlink":
                    self.assertEqual(os.readlink(trial / "introduced"), str(outside))
                self.assertEqual(outside.read_bytes(), b'external bytes remain unchanged')
                self.assertEqual(outside.stat().st_ino, original.st_ino)
                self.assertEqual(outside.stat().st_mtime_ns, original.st_mtime_ns)
                self.assertEqual(self.receipt()["status"], "RESTORED_VERIFIED")

    def test_real_signal_interruptions_restore_only_temporary_files(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig.name):
                evidence = self.base / sig.name
                code = """
import os, signal, sys
from pathlib import Path
from synthetic_data_preservation import SyntheticWorkspace, PreservedSyntheticData as PreservedAppData, SignalInterrupted
data, evidence, number = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
try:
    with PreservedAppData(data, evidence, workspace=SyntheticWorkspace.resume(data.parent), quiesce=lambda phase: True):
        (data / '.hidden').write_bytes(b'interrupted synthetic test')
        os.kill(os.getpid(), number)
except SignalInterrupted:
    sys.exit(29)
sys.exit(1)
"""
                result = subprocess.run([sys.executable, "-B", "-c", code, str(self.data),
                                         str(evidence), str(int(sig))], cwd=Path(self.m.__file__).parent,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 29, result.stderr)
                self.assertEqual(self.inventory(self.data), self.before)

    def test_signals_during_restore_are_deferred_until_verified(self):
        replace = self.m.os.replace
        sent = []
        def interrupt_restore(source, destination):
            if Path(source).parent.name.startswith("stage-") and not sent:
                sent.append(True)
                os.kill(os.getpid(), signal.SIGTERM)
                os.kill(os.getpid(), signal.SIGINT)
            return replace(source, destination)
        with patch.object(self.m.os, "replace", side_effect=interrupt_restore):
            with self.assertRaises(self.m.SignalInterrupted):
                with self.transaction():
                    self.mutate()
        self.assertEqual(self.inventory(self.data), self.before)
        self.assertEqual(self.receipt()["status"], "RESTORED_VERIFIED")

    def test_sigkill_leaves_durable_backup_for_explicit_recovery(self):
        code = """
import os, signal, sys
from pathlib import Path
from synthetic_data_preservation import SyntheticWorkspace, PreservedSyntheticData as PreservedAppData
data, evidence = Path(sys.argv[1]), Path(sys.argv[2])
with PreservedAppData(data, evidence, workspace=SyntheticWorkspace.resume(data.parent), quiesce=lambda phase: True):
    (data / '.hidden').write_bytes(b'synthetic state before SIGKILL')
    os.kill(os.getpid(), signal.SIGKILL)
"""
        result = subprocess.run([sys.executable, "-B", "-c", code, str(self.data),
                                 str(self.evidence)], cwd=Path(self.m.__file__).parent,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)
        self.assertEqual(self.receipt()["status"], "BACKUP_VERIFIED")
        self.m.recover(self.data, self.evidence, workspace=self.workspace, quiesce=self.quiesce)
        self.assertEqual(self.inventory(self.data), self.before)

    def test_abrupt_process_exit_mid_restore_can_resume_from_disk(self):
        code = """
import os, sys
from pathlib import Path
from synthetic_data_preservation import SyntheticWorkspace, PreservedSyntheticData as PreservedAppData
data, evidence = Path(sys.argv[1]), Path(sys.argv[2])
original_replace = os.replace
count = 0
def exit_during_quarantine(source, destination):
    global count
    original_replace(source, destination)
    if Path(destination).parent.name.startswith('trial-'):
        count += 1
        if count == 2:
            os._exit(45)
os.replace = exit_during_quarantine
with PreservedAppData(data, evidence, workspace=SyntheticWorkspace.resume(data.parent), quiesce=lambda phase: True):
    (data / '.hidden').write_bytes(b'crash trial retained')
"""
        result = subprocess.run([sys.executable, "-B", "-c", code, str(self.data),
                                 str(self.evidence)], cwd=Path(self.m.__file__).parent,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 45, result.stderr)
        self.assertEqual(self.receipt()["status"], "RESTORING")
        first_trial = self.evidence / self.receipt()["attempts"][0]["trial"]
        self.assertEqual((first_trial / ".hidden").read_bytes(), b'crash trial retained')
        self.m.recover(self.data, self.evidence, workspace=self.workspace, quiesce=self.quiesce)
        self.assertEqual(self.inventory(self.data), self.before)

    def test_recovery_refuses_changed_manifest_and_wrong_root(self):
        with self.transaction():
            self.mutate()
        original_manifest = (self.evidence / "before.json").read_bytes()
        (self.evidence / "before.json").write_bytes(b'{}')
        with self.assertRaises(self.m.RecoveryRequired):
            self.m.recover(self.data, self.evidence, workspace=self.workspace, quiesce=self.quiesce)
        self.assertEqual(self.inventory(self.data), self.before)
        (self.evidence / "before.json").write_bytes(original_manifest)
        unrelated = self.base / "unrelated"
        unrelated.mkdir()
        (unrelated / "keep").write_bytes(b'untouched')
        with self.assertRaises(self.m.RecoveryRequired):
            self.m.recover(unrelated, self.evidence, workspace=self.workspace, quiesce=self.quiesce)
        self.assertEqual((unrelated / "keep").read_bytes(), b'untouched')


if __name__ == "__main__":
    unittest.main(verbosity=2)
