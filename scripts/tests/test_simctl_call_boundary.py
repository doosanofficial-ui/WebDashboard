import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import failure_observation as observation
import verify_offline_replay as replay

DEVICE = '11111111-1111-4111-8111-111111111111'


class SimctlCallBoundaryTests(unittest.TestCase):
    def helper(self):
        helper = getattr(observation, 'simctl_output', None)
        self.assertTrue(callable(helper), 'Container call must record its own process/communicate boundary')
        return helper

    def trial(self, source, timeout=2, snapshot_error=False):
        helper = self.helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command = ['xcrun', 'simctl', 'get_app_container', DEVICE,
                       'local.webdashboard.Telemetry', 'data']
            real_popen = subprocess.Popen
            def launch(argv, **kwargs):
                self.assertEqual(argv, command)
                self.assertEqual(kwargs, {'stdout': subprocess.PIPE,
                                         'stderr': subprocess.STDOUT, 'text': True})
                return real_popen([sys.executable, '-c', source], **kwargs)
            events = []
            def snapshot(pid, device):
                events.append((pid, device, 'sample'))
                if snapshot_error:
                    raise RuntimeError('PRIVATE_TOKEN')
                return {'pid': pid, 'simulator': device, 'executable': 'framework-simctl'}
            with patch.object(observation.subprocess, 'Popen', side_effect=launch), \
                 patch.object(observation, 'owned_boundary', side_effect=snapshot):
                try:
                    value = helper(command, root, 'app-container', timeout)
                    error = None
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as caught:
                    value, error = None, caught
            receipt = json.loads((root / 'app-container-observation.json').read_text())
            receipt['sampleCountForTest'] = len(events)
            self.assertNotIn('PRIVATE', json.dumps(receipt))
            self.assertNotIn('/private/container', json.dumps(receipt))
            self.assertEqual(receipt['simulator'], DEVICE)
            self.assertEqual(receipt['timeoutSeconds'], timeout)
            self.assertGreater(receipt['pid'], 0)
            self.assertLessEqual(receipt['launchRequestedMonotonic'], receipt['launchReturnedMonotonic'])
            self.assertLessEqual(receipt['launchReturnedMonotonic'], receipt['communicateStartedMonotonic'])
            self.assertIsNone(receipt['kernelExitTimestamp'])
            if isinstance(error, subprocess.TimeoutExpired):
                self.assertTrue(events)
            else:
                self.assertEqual(events, [], 'Timely/known exit must not launch optional native sampling')
            return value, error, receipt

    def test_original_success_output_returned_without_recording_container_path(self):
        value, error, receipt = self.trial("print('/private/container')")
        self.assertIsNone(error)
        self.assertEqual(value, '/private/container\n')
        self.assertEqual(receipt['childExitCode'], 0)
        self.assertTrue(receipt['returnedNormally'])

    def test_original_nonzero_output_code_and_pre_stop_snapshot(self):
        _, error, receipt = self.trial("print('PRIVATE_TOKEN');raise SystemExit(2)")
        self.assertEqual(error.returncode, 2)
        self.assertEqual(error.output, 'PRIVATE_TOKEN\n')
        self.assertEqual(receipt['firstFailure']['childExitCodeBeforeStop'], 2)
        self.assertLessEqual(receipt['firstFailure']['observedMonotonic'], receipt['callReturnedMonotonic'])
        self.assertEqual(receipt['sampleCountForTest'], 0, 'Reaped PID must not be sampled again')

    def test_original_timeout_bytes_and_unknown_exit_survive_optional_snapshot_fault(self):
        _, error, receipt = self.trial("import time;print('PRIVATE_TOKEN',flush=True);time.sleep(2)", .12, True)
        self.assertEqual(error.timeout, .12)
        self.assertIsInstance(error.output, bytes)
        self.assertIn(b'PRIVATE_TOKEN', error.output)
        self.assertIsNone(receipt['firstFailure']['childExitCodeBeforeStop'])
        self.assertLessEqual(receipt['firstFailure']['observedMonotonic'], receipt['killRequestedMonotonic'])
        self.assertIsNotNone(receipt['childExitCode'])

    def test_bootstatus_timeout_records_cached_identity_without_native_sampling(self):
        self.assertTrue(callable(getattr(observation, 'owned_boundary', None)), 'Native PID path observation is missing')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command = ['xcrun', 'simctl', 'bootstatus', DEVICE, '-b']
            real_popen = subprocess.Popen
            def launch(argv, **kwargs):
                return real_popen([sys.executable, '-c', 'import time;time.sleep(2)'], **kwargs)
            with patch.object(replay.subprocess, 'Popen', side_effect=launch), \
                 patch('verify_replay_seed.owned_progress', return_value={}), \
                 patch.object(observation, 'owned_boundary', side_effect=AssertionError('Timeout native sampling')) as native:
                with self.assertRaises(subprocess.TimeoutExpired):
                    replay.run_owned_phase(command, root/'boot.log', root/'boot.json', .12)
            receipt = json.loads((root/'boot.json').read_text())
            self.assertEqual(receipt['firstFailure']['ownedBoundary']['simulator'], DEVICE)
            native.assert_not_called()
            boundary = receipt['firstFailure']['ownedBoundary']
            self.assertEqual(boundary['pid'], receipt['pid'])
            self.assertEqual(boundary['skipped'], 'Owned cleanup takes priority after Timeout')
            self.assertNotIn('executable', boundary)
            self.assertLessEqual(receipt['firstFailure']['observedMonotonic'], receipt['phaseStartedMonotonic'] + receipt['groupStopRequestedElapsedSeconds'])

    def test_snapshot_and_receipt_fault_cannot_mask_timeout_or_skip_reap(self):
        helper = self.helper()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            real_popen = subprocess.Popen
            children = []
            def launch(argv, **kwargs):
                child = real_popen([sys.executable, '-c', 'import time;time.sleep(2)'], **kwargs)
                children.append(child)
                return child
            with patch.object(observation.subprocess, 'Popen', side_effect=launch), \
                 patch.object(observation, 'failure_snapshot', side_effect=RuntimeError('PRIVATE_TOKEN')), \
                 patch.object(Path, 'open', side_effect=OSError('PRIVATE_TOKEN')):
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    helper(['xcrun', 'simctl', 'get_app_container', DEVICE,
                            'local.webdashboard.Telemetry', 'data'], root, 'app-container', .12)
            self.assertEqual(caught.exception.timeout, .12)
            self.assertEqual(len(children), 1)
            self.assertIsNotNone(children[0].poll())

    def test_listapps_discards_other_apps_and_all_private_fields(self):
        import plistlib
        raw = plistlib.dumps({'local.webdashboard.Telemetry': {'PRIVATE_TOKEN': '/private/container'},
                             'private.other.app': {'CFBundleName': 'PRIVATE_NAME'}}).decode()
        value = observation.parse_probe('owned-app-registration', raw, DEVICE)
        self.assertIs(value.get('registered'), True, 'Exact Telemetry registration response is missing')
        self.assertNotIn('PRIVATE', json.dumps(value))
        self.assertNotIn('private.other', json.dumps(value))

    def test_native_snapshot_is_not_a_local_device_probe(self):
        self.assertTrue(callable(getattr(observation, 'owned_boundary', None)))
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}), \
             patch.object(Path, 'open', side_effect=AssertionError('No local file reads')):
            value = observation.owned_boundary(os.getpid(), DEVICE)
        self.assertIn('skipped', value)

    def test_native_pid_path_allowlist_drops_private_executables(self):
        from unittest.mock import Mock
        self.assertTrue(callable(getattr(observation, 'owned_boundary', None)))
        for path, expected in [('/usr/bin/xcrun', '/usr/bin/xcrun'),
                ('/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl',
                 '/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl'),
                ('/private/PRIVATE_TOKEN', None)]:
            def resolve(pid, buffer, length):
                self.assertEqual(pid, 123)
                buffer.value = path.encode()
                return len(path)
            library = Mock()
            library.proc_pidpath.side_effect = resolve
            with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}), \
                 patch.object(observation.sys, 'platform', 'darwin'), \
                 patch('ctypes.CDLL', return_value=library), \
                 patch.object(Path, 'open', side_effect=AssertionError('No disk reads')):
                value = observation.owned_boundary(123, DEVICE)
            self.assertEqual(value['executable'], expected)
            self.assertNotIn('PRIVATE', json.dumps(value))
            self.assertIsNone(value['kernelExecTimestamp'])

    def test_popen_exception_object_preserved_even_if_receipt_fails(self):
        helper = self.helper()
        primary = OSError('PRIVATE_TOKEN')
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(observation.subprocess, 'Popen', side_effect=primary), \
             patch.object(Path, 'open', side_effect=OSError('record failure')):
            with self.assertRaises(OSError) as caught:
                helper(['xcrun', 'simctl', 'get_app_container', DEVICE,
                        'local.webdashboard.Telemetry', 'data'], Path(directory), 'app-container', 60)
        self.assertIs(caught.exception, primary)

    def test_absent_or_malformed_registry_does_not_claim_registration(self):
        import plistlib
        value = observation.parse_probe('owned-app-registration', plistlib.dumps({}).decode(), DEVICE)
        self.assertIs(value.get('registered'), False)
        with self.assertRaises(ValueError):
            observation.parse_probe('owned-app-registration', plistlib.dumps(['PRIVATE_TOKEN']).decode(), DEVICE)

    def test_reaped_pid_is_never_resampled(self):
        helper = getattr(observation, 'child_boundary', None)
        self.assertTrue(callable(helper), 'PID reuse guard is missing')
        with subprocess.Popen([sys.executable, '-c', 'pass']) as child:
            child.wait()
            with patch.object(observation, 'owned_boundary', side_effect=AssertionError('Reaped PID')):
                value = helper(child, DEVICE)
            self.assertIn('skipped', value)
            self.assertIsNone(value['kernelExecTimestamp'])

    def test_busy_or_unavailable_reap_lock_skips_native_pid_query(self):
        import threading
        from types import SimpleNamespace
        helper = getattr(observation, 'child_boundary', None)
        self.assertTrue(callable(helper), 'PID reuse guard is missing')
        lock = threading.Lock()
        lock.acquire()
        try:
            for child in [SimpleNamespace(pid=123, returncode=None, _waitpid_lock=lock),
                          SimpleNamespace(pid=123, returncode=None)]:
                with patch.object(observation, 'owned_boundary', side_effect=AssertionError('Unsafe PID')):
                    value = helper(child, DEVICE)
                self.assertIn('skipped', value)
        finally:
            lock.release()

    def test_reap_lock_fault_remains_optional(self):
        from types import SimpleNamespace
        from unittest.mock import Mock
        helper = getattr(observation, 'child_boundary', None)
        self.assertTrue(callable(helper))
        lock = Mock()
        lock.acquire.side_effect = RuntimeError('PRIVATE_TOKEN')
        value = helper(SimpleNamespace(pid=123, returncode=None, _waitpid_lock=lock), DEVICE)
        self.assertEqual(value.get('errorType'), 'RuntimeError')
        self.assertNotIn('PRIVATE', json.dumps(value))

    def test_slow_native_sampler_cannot_hide_timely_bootstatus_completion(self):
        import select
        self.assertTrue(callable(getattr(observation, 'owned_boundary', None)))
        # Cold Python spawn/initialization is not the behavior this test measures.
        # This is a Python fixture budget, not the real simctl bootstatus180 budget.
        fixture_timeout = 2
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child = subprocess.Popen([sys.executable, '-c',
                "import sys,time;print('ready',flush=True);sys.stdin.readline();time.sleep(.01)"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, start_new_session=True)
            try:
                self.assertTrue(select.select([child.stdout], [], [], 10)[0], 'Fixture readiness timeout')
                self.assertEqual(child.stdout.readline(), 'ready\n')
                returned = []
                def launch(argv, **kwargs):
                    self.assertEqual(argv, ['xcrun', 'simctl', 'bootstatus', DEVICE, '-b'])
                    self.assertTrue(kwargs['start_new_session'])
                    self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
                    self.assertIs(kwargs['stderr'], subprocess.STDOUT)
                    returned.append(child.pid)
                    child.stdin.write('release\n')
                    child.stdin.flush()
                    return child
                def slow_sample(*args):
                    time.sleep(fixture_timeout + .25)
                    return {'simulator': DEVICE}
                with patch.object(replay.subprocess, 'Popen', side_effect=launch), \
                     patch('verify_replay_seed.owned_progress', return_value={}), \
                     patch.object(observation, 'owned_boundary', side_effect=slow_sample) as sample:
                    value = replay.run_owned_phase(['xcrun', 'simctl', 'bootstatus', DEVICE, '-b'],
                                                  root/'boot.log', root/'boot.json', fixture_timeout)
                self.assertEqual(returned, [child.pid])
                self.assertEqual(value['exitCode'], 0)
                self.assertFalse(value['timedOut'])
                self.assertLessEqual(value['processCompletionObservedElapsedSeconds'], fixture_timeout)
                sample.assert_not_called()
            finally:
                # No descendants: never signal a known-exit/reusable PID or PGID.
                try:
                    if child.returncode is None:
                        child.kill()
                finally:
                    try:
                        child.wait(timeout=10)
                    finally:
                        try:
                            child.stdin.close()
                        finally:
                            child.stdout.close()


if __name__ == '__main__':
    unittest.main()
