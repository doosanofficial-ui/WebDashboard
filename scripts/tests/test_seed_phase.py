import json
import os
import errno
import signal
import threading
from contextlib import ExitStack, nullcontext
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as runner

class OwnedGroupModel:
    """OS-free group lifecycle; this is not evidence of native process exit."""
    def __init__(self, descendant=False, interrupted=None, probe_error=None, kill_error=None):
        self.pid = 700001
        self.returncode = None
        self.leader_running = True
        self.descendant_running = descendant
        self.interrupted = interrupted
        self.probe_error = probe_error
        self.kill_error = kill_error
        self.signals = []
        self.launches = 0
        self.progress_calls = 0
        self.waiter_entered = threading.Event()
        self.release_waiter = threading.Event()
        self.owner_thread = threading.get_ident()
        self.waiter = None
        self.phase_error = None

    def launch(self, command, **options):
        assert options['start_new_session'] is True
        assert self.launches == 0, 'The phase may create only its own one group'
        self.launches += 1
        self.command = command
        return self

    def wait(self, timeout):
        if threading.get_ident() != self.owner_thread:
            self.waiter = threading.current_thread()
            self.waiter_entered.set()
            assert self.release_waiter.wait(2), 'Model waiter must be released'
            if self.interrupted is None:
                raise subprocess.TimeoutExpired(self.command, timeout)
        assert not self.leader_running, 'Cleanup must stop its leader before reap'
        self.returncode = -signal.SIGTERM
        return self.returncode

    def signal_group(self, group, number):
        assert self.launches == 1 and group == self.pid, 'Never signal an external group'
        self.signals.append((group, number))
        if number == signal.SIGTERM:
            self.leader_running = False
            if self.interrupted is not None:
                self.release_waiter.set()
        elif number == 0:
            if self.probe_error:
                raise self.probe_error
            if not self.leader_running and not self.descendant_running:
                raise ProcessLookupError(errno.ESRCH, 'Model owned group ended')
        elif number == signal.SIGKILL:
            if self.kill_error:
                raise self.kill_error
            self.leader_running = self.descendant_running = False
        else:
            raise AssertionError('Unexpected group operation')

    def progress(self, pid, log, began):
        assert pid == self.pid
        self.progress_calls += 1
        if self.progress_calls == 1:
            assert self.waiter_entered.wait(2), 'Completion waiter must enter before observation'
            if self.interrupted is not None:
                raise self.interrupted
            self.release_waiter.set()
        return {'ownedProcessGroup': self.pid, 'logBytes': 0}

    def failure_snapshot(self, error, code, source, observed=None, **options):
        if self.phase_error is None:
            self.phase_error = error
        return {'type': type(error).__name__, 'source': source}

    def __enter__(self):
        self.patches = ExitStack()
        self.patches.enter_context(patch.object(runner.subprocess, 'Popen', side_effect=self.launch))
        self.patches.enter_context(patch.object(runner.os, 'killpg', side_effect=self.signal_group))
        self.pid_lookups = self.patches.enter_context(patch.object(
            runner.os, 'kill', side_effect=AssertionError('No retired PID lookup or signal')))
        self.patches.enter_context(patch('verify_replay_seed.owned_progress', side_effect=self.progress))
        self.patches.enter_context(patch.object(runner, 'phase_resource_snapshot', return_value={'cpuCount': 1}))
        self.patches.enter_context(patch.object(runner.failure_observation, 'failure_snapshot',
                                               side_effect=self.failure_snapshot))
        self.patches.enter_context(patch.object(runner.time, 'monotonic', return_value=100.0))
        return self

    def __exit__(self, kind, error, traceback):
        # Release only a test thread. No cleanup by cached PID/PGID is permitted.
        self.release_waiter.set()
        try:
            if self.waiter is not None:
                self.waiter.join(timeout=2)
                assert not self.waiter.is_alive(), 'Model completion thread must stop'
        finally:
            self.patches.close()


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
        with OwnedGroupModel(descendant=True) as model:
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                self.run_phase('synthetic TERM-ignoring descendant', timeout=0.5)
            receipt = json.loads((Path(self.directory.name) / 'receipt.json').read_text())
            self.assertTrue(receipt['timedOut'])
            self.assertTrue(receipt['groupTermSent'])
            self.assertTrue(receipt['groupKillSent'], 'Leader exit must not abandon its descendant')
            self.assertNotEqual(receipt['exitCode'], 0)
            self.assertEqual(caught.exception.timeout, 0.5)
            self.assertIs(caught.exception, model.phase_error)
            self.assertEqual(model.launches, 1)
            self.assertFalse(model.leader_running)
            self.assertFalse(model.descendant_running)
            self.assertEqual(model.signals, [(model.pid, signal.SIGTERM),
                                             (model.pid, 0), (model.pid, signal.SIGKILL)])
            self.assertTrue(receipt['completionWaiterStopped'])
            model.pid_lookups.assert_not_called()


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
        probe = PermissionError(errno.EPERM, 'synthetic owned group probe failure')
        kill = PermissionError(errno.EPERM, 'synthetic owned group kill failure') if kill_denied else None
        with OwnedGroupModel(descendant=True, probe_error=probe, kill_error=kill) as model:
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                self.run_phase('synthetic owned group', timeout=0.1)
            self.assertEqual(caught.exception.timeout, 0.1)
            self.assertIs(caught.exception, model.phase_error)
            receipt = json.loads((Path(self.directory.name) / 'receipt.json').read_text())
            self.assertTrue(receipt['timedOut'])
            self.assertTrue(receipt['groupTermSent'])
            self.assertIsNotNone(receipt['exitCode'], 'The model leader must still be reaped')
            self.assertIsNone(receipt['groupStillExistsAfterLeaderWait'], 'EPERM must remain unknown')
            expected = [{'operation': 'probe', 'type': 'PermissionError', 'errno': errno.EPERM,
                         'message': str(probe)}]
            if kill_denied:
                expected.append({'operation': 'kill', 'type': 'PermissionError', 'errno': errno.EPERM,
                                 'message': str(kill)})
            self.assertEqual(receipt['groupCleanupErrors'], expected)
            self.assertEqual(receipt['groupKillSent'], not kill_denied)
            self.assertEqual(model.descendant_running, kill_denied)
            self.assertEqual(model.signals, [(model.pid, signal.SIGTERM),
                                             (model.pid, 0), (model.pid, signal.SIGKILL)])
            self.assertTrue(receipt['completionWaiterStopped'])
            model.pid_lookups.assert_not_called()


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
        with OwnedGroupModel(interrupted=error) as model:
            with self.assertRaises(type(error)) as caught:
                self.run_phase('synthetic interrupted phase')
            value = json.loads((Path(self.directory.name) / 'receipt.json').read_text())
            self.assertTrue(value['groupTermSent'], 'Interrupted recorder must stop its owned group')
            self.assertIsNotNone(value['exitCode'], 'Interrupted model leader must be reaped')
            self.assertFalse(value['timedOut'])
            self.assertIs(caught.exception, error, 'Cleanup must preserve the original exception object')
            self.assertIs(model.phase_error, error)
            self.assertFalse(model.leader_running)
            self.assertFalse(value['groupKillSent'], 'An absent group must not be signalled again')
            self.assertEqual(model.signals, [(model.pid, signal.SIGTERM), (model.pid, 0)])
            self.assertTrue(value['completionWaiterStopped'])
            model.pid_lookups.assert_not_called()


    def test_keyboard_interrupt_reaps_the_new_owned_process(self):
        self.interrupted_phase(KeyboardInterrupt())

    def test_post_launch_observation_error_reaps_the_new_owned_process(self):
        self.interrupted_phase(OSError("synthetic observation failure"))


@unittest.skipUnless(os.name == "posix", "Seed fixture models POSIX group cleanup")
class SeedPhaseFixtureRegressionTests(unittest.TestCase):
    def assert_original_fixture_failure(self, interrupted=False):
        case = SeedPhaseTests('test_timeout_kills_term_ignoring_descendant_after_leader_exits')
        class OriginalFixtureAssertion(AssertionError):
            pass

        case.failureException = OriginalFixtureAssertion
        case.setUp()
        self.addCleanup(case.doCleanups)
        original = OSError('synthetic interrupted phase') if interrupted else None

        def failed_receipt(code, timeout=5):
            value = {'timedOut': not interrupted, 'groupTermSent': True,
                     'groupKillSent': True, 'exitCode': -15, 'pid': 700001,
                     'processGroup': 700001}
            value['groupTermSent' if interrupted else 'timedOut'] = False
            (Path(case.directory.name) / 'receipt.json').write_text(json.dumps(value))
            if interrupted:
                raise original
            raise subprocess.TimeoutExpired(['synthetic-owned-fixture'], timeout)

        case.run_phase = failed_receipt
        denied = PermissionError(errno.EPERM, 'synthetic forbidden late group signal')
        with patch(__name__ + '.OwnedGroupModel', return_value=nullcontext()), \
             patch.object(os, 'killpg', side_effect=denied) as groups, \
             patch.object(os, 'kill', side_effect=AssertionError('No retired PID lookup')) as pids, \
             patch.object(subprocess, 'Popen', side_effect=AssertionError('No real child')) as launches:
            caught = None
            try:
                if interrupted:
                    case.interrupted_phase(original)
                else:
                    case.test_timeout_kills_term_ignoring_descendant_after_leader_exits()
            except BaseException as error:
                caught = error
            self.assertIsInstance(caught, OriginalFixtureAssertion,
                                  'The fixture assertion must survive without a late cleanup error')
            groups.assert_not_called()
            pids.assert_not_called()
            launches.assert_not_called()

    def test_timeout_fixture_assertion_is_not_masked_by_late_group_signal(self):
        self.assert_original_fixture_failure()

    def test_interrupted_fixture_assertion_is_not_masked_by_late_group_signal(self):
        self.assert_original_fixture_failure(interrupted=True)


if __name__ == "__main__": unittest.main()
