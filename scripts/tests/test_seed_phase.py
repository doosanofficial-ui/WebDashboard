import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

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

    def test_success_records_command_elapsed_and_output(self):
        receipt, log=self.run_phase("print('synthetic Seed completed')")
        self.assertEqual(receipt["exitCode"],0)
        self.assertFalse(receipt["timedOut"])
        self.assertGreaterEqual(receipt["elapsedSeconds"],0)
        self.assertEqual(receipt["processGroup"],receipt["pid"])
        self.assertEqual(receipt["command"][0],sys.executable)
        self.assertIn("synthetic Seed completed",log)

    def test_nonzero_exit_preserves_failure_and_receipt(self):
        with self.assertRaises(subprocess.CalledProcessError) as error:
            self.run_phase("import sys; print('compile rejected'); sys.exit(7)")
        self.assertEqual(error.exception.returncode,7)
        receipt=json.loads((Path(self.directory.name)/"receipt.json").read_text())
        self.assertEqual(receipt["exitCode"],7)
        self.assertFalse(receipt["timedOut"])

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

if __name__ == "__main__": unittest.main()
