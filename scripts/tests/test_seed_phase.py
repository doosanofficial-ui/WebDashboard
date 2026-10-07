import json
import os
import errno
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as runner

@unittest.skipUnless(os.name == "posix", "Seed runner owns POSIX subprocess groups on macOS")
class SeedPhaseTests(unittest.TestCase):
    def run_phase(self, code, timeout=5):
        root=Path(self.directory.name)
        command=[sys.executable,"-c",code]
        runner.run_seed_phase(command, root/"seed.log", root/"receipt.json", timeout)
        return json.loads((root/"receipt.json").read_text()), (root/"seed.log").read_text()

    def setUp(self):
        self.directory=tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def test_expired_deadline_does_not_launch_seed(self):
        root=Path(self.directory.name)
        marker=root/"should-not-exist"
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_phase("from pathlib import Path; Path("+repr(str(marker))+").touch()",timeout=0)
        self.assertFalse(marker.exists())
        receipt=json.loads((root/"receipt.json").read_text())
        self.assertTrue(receipt["timedOut"])
        self.assertFalse(receipt["launched"])

    def test_timeout_kills_term_ignoring_descendant_after_leader_exits(self):
        code="""import subprocess, sys, time
child=subprocess.Popen([sys.executable,'-c',
    'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print("ready",flush=True); time.sleep(30)'],stdout=subprocess.PIPE,text=True)
assert child.stdout.readline().strip()=='ready'
print('owned descendant ready',flush=True)
time.sleep(30)
"""
        root=Path(self.directory.name)
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                self.run_phase(code,timeout=0.5)
            receipt=json.loads((root/"receipt.json").read_text())
            self.assertTrue(receipt["timedOut"])
            self.assertTrue(receipt["groupTermSent"])
            self.assertTrue(receipt["groupKillSent"], "Leader exit must not leave its TERM-ignoring descendant")
            self.assertNotEqual(receipt["exitCode"],0)
        finally:
            # The failing pre-fix implementation may leave this test's own new group alive.
            receipt=json.loads((root/"receipt.json").read_text())
            try: os.killpg(receipt["processGroup"],9)
            except ProcessLookupError: pass

    def test_launch_missing_file_preserves_unlaunched_receipt(self):
        root = Path(self.directory.name)
        receipt = root/'receipt.json'
        with self.assertRaises(FileNotFoundError):
            runner.run_seed_phase([str(root/'missing-executable')], root/'seed.log', receipt, 5)
        self.assertTrue(receipt.exists(), 'Launch failures must preserve a receipt')
        value = json.loads(receipt.read_text())
        self.assertFalse(value['launched'])
        self.assertIsNone(value['exitCode'])
        self.assertEqual(value['launchError']['errno'], 2)
        self.assertFalse(value['groupTermSent'])

    def test_launch_enoexec_preserves_unlaunched_receipt(self):
        root = Path(self.directory.name)
        binary = root/'not-an-executable'
        binary.write_text('invalid executable bytes')
        binary.chmod(0o700)
        with self.assertRaises(OSError):
            runner.run_seed_phase([str(binary)], root/'seed.log', root/'receipt.json', 5)
        self.assertTrue((root/'receipt.json').exists(), 'ENOEXEC must preserve a receipt')
        value = json.loads((root/'receipt.json').read_text())
        self.assertFalse(value['launched'])
        self.assertIsNone(value['exitCode'])
        self.assertEqual(value['launchError']['errno'], 8)

    def test_success_records_command_elapsed_and_output(self):
        receipt, log=self.run_phase("print('synthetic Seed completed')")
        self.assertEqual(receipt["exitCode"],0)
        self.assertFalse(receipt["timedOut"])
        self.assertGreaterEqual(receipt["elapsedSeconds"],0)
        self.assertEqual(receipt["processGroup"],receipt["pid"])
        self.assertEqual(receipt["command"][0],sys.executable)
        self.assertIn("synthetic Seed completed",log)

    def test_progress_receipt_identifies_owned_group_and_final_log_bytes(self):
        receipt, log = self.run_phase("print('progress visible',flush=True)")
        self.assertIn('progress', receipt, 'Timeout diagnosis requires process and log progress evidence')
        self.assertGreater(len(receipt['progress']), 0)
        self.assertTrue(all(sample['ownedProcessGroup'] == receipt['processGroup'] for sample in receipt['progress']))
        self.assertEqual(receipt['progress'][-1]['logBytes'], len(log.encode()))
        self.assertIn('cpuCount', receipt['resources'])

    def test_nonzero_exit_preserves_failure_and_receipt(self):
        with self.assertRaises(subprocess.CalledProcessError) as error:
            self.run_phase("import sys; print('compile rejected'); sys.exit(7)")
        self.assertEqual(error.exception.returncode,7)
        receipt=json.loads((Path(self.directory.name)/"receipt.json").read_text())
        self.assertEqual(receipt["exitCode"],7)
        self.assertFalse(receipt["timedOut"])

    def group_probe_failure(self, kill_denied=False):
        root = Path(self.directory.name)
        original_killpg = os.killpg
        def signal_group(process_group, number):
            if number == 0:
                raise PermissionError(errno.EPERM, "synthetic owned group probe failure")
            if kill_denied and number == signal.SIGKILL:
                raise PermissionError(errno.EPERM, "synthetic owned group kill failure")
            return original_killpg(process_group, number)
        with patch.object(runner.os, "killpg", side_effect=signal_group):
            with self.assertRaises(Exception) as caught:
                self.run_phase("import time; time.sleep(30)", timeout=0.1)
        self.assertIsInstance(caught.exception, subprocess.TimeoutExpired,
                              "Cleanup observation must not replace the original bounded phase failure")
        self.assertEqual(caught.exception.timeout, 0.1)
        receipt = json.loads((root / "receipt.json").read_text())
        self.assertTrue(receipt["timedOut"])
        self.assertTrue(receipt["groupTermSent"])
        self.assertIsNotNone(receipt["exitCode"], "The newly owned leader must still be reaped")
        self.assertIsNone(receipt["groupStillExistsAfterLeaderWait"],
                          "EPERM is unknown, never proof that descendants are absent")
        expected = [{
            "operation": "probe", "type": "PermissionError", "errno": errno.EPERM,
            "message": "[Errno 1] synthetic owned group probe failure"}]
        if kill_denied:
            expected.append({"operation": "kill", "type": "PermissionError", "errno": errno.EPERM,
                             "message": "[Errno 1] synthetic owned group kill failure"})
            self.assertFalse(receipt["groupKillSent"], "Denied cleanup must never be recorded as successful")
        self.assertEqual(receipt["groupCleanupErrors"], expected)

    def test_group_probe_permission_error_cannot_replace_owned_timeout(self):
        self.group_probe_failure()

    def test_unknown_group_and_kill_denial_keep_original_timeout(self):
        self.group_probe_failure(kill_denied=True)

    def test_timeout_terminates_only_new_owned_group_and_reaps_child(self):
        code="""import signal, subprocess, sys, time
child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])
def finish(signum, frame):
    child.wait(timeout=2)
    print('owned child reaped',flush=True)
    sys.exit(0)
signal.signal(signal.SIGTERM,finish)
print('owned child started',flush=True)
time.sleep(30)
"""
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_phase(code,timeout=0.5)
        root=Path(self.directory.name)
        receipt=json.loads((root/"receipt.json").read_text())
        self.assertTrue(receipt["timedOut"])
        self.assertTrue(receipt["groupTermSent"])
        self.assertFalse(receipt["groupKillSent"])
        self.assertEqual(receipt["exitCode"],0)
        self.assertIn("owned child reaped",(root/"seed.log").read_text())

    def interrupted_phase(self, error):
        root = Path(self.directory.name)
        receipt = root / "receipt.json"
        original = __import__("verify_replay_seed").owned_progress
        calls = 0
        def progress(*args):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise error
            return original(*args)
        try:
            with patch("verify_replay_seed.owned_progress", side_effect=progress):
                with self.assertRaises(type(error)):
                    self.run_phase("import time; time.sleep(30)")
            value = json.loads(receipt.read_text())
            self.assertTrue(value["groupTermSent"], "Interrupted recorder must stop its owned group")
            self.assertIsNotNone(value["exitCode"], "Interrupted child must be reaped")
            self.assertFalse(value["timedOut"])
            with self.assertRaises(ProcessLookupError):
                os.kill(value["pid"], 0)
        finally:
            if receipt.exists():
                value = json.loads(receipt.read_text())
                if value.get("processGroup"):
                    try: os.killpg(value["processGroup"], 9)
                    except ProcessLookupError: pass

    def test_keyboard_interrupt_reaps_the_new_owned_process(self):
        self.interrupted_phase(KeyboardInterrupt())

    def test_post_launch_observation_error_reaps_the_new_owned_process(self):
        self.interrupted_phase(OSError("synthetic observation failure"))


if __name__ == "__main__": unittest.main()
