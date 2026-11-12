"""Exercise the real result-read assignment without booting a Simulator."""
import ast
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as replay

GREEN = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0,
         "skippedTests": 0, "expectedFailures": 0, "result": "Passed"}


def read_from_actual_caller(results):
    tree = ast.parse(Path(replay.__file__).read_text())
    main = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'main')
    assignment = next(node for node in ast.walk(main) if isinstance(node, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id == 'summary' for target in node.targets))
    module = ast.fix_missing_locations(ast.Module(body=[copy.deepcopy(assignment)], type_ignores=[]))
    scope = dict(vars(replay), bundle=results / 'Saved.xcresult', results=results)
    exec(compile(module, str(replay.__file__), 'exec'), scope)
    return scope['summary']


@unittest.skipUnless(os.name == 'posix', 'Reader owns POSIX process groups')
class ReplayResultReaderTests(unittest.TestCase):
    def native_substitute(self, results, payload, exit_code=0, program=None):
        """Only replace unavailable Apple command; retain real child/pipe/file/wait behavior."""
        original = subprocess.Popen
        expected = ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                    '--path', str(results / 'Saved.xcresult')]
        def launch(command, *args, **kwargs):
            self.assertEqual(command, expected)
            return original([sys.executable, '-B', '-c',
                             program or 'import sys; print(' + repr(payload) + ', flush=True); sys.exit(' + str(exit_code) + ')'],
                            *args, **kwargs)
        return mock.patch.object(replay.subprocess, 'Popen', side_effect=launch)

    def test_actual_caller_preserves_output_and_successful_owned_process_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            with self.native_substitute(results, json.dumps(GREEN)):
                self.assertEqual(read_from_actual_caller(results), GREEN)
            log = results / 'result-read-command.log'
            self.assertTrue(log.is_file(), 'Successful result-read output was discarded')
            self.assertEqual(json.loads(log.read_text()), GREEN)
            receipt = json.loads((results / 'result-read-process.json').read_text())
            self.assertEqual(receipt['timeoutSeconds'], 60)
            self.assertEqual(receipt['exitCode'], 0)
            self.assertFalse(receipt['timedOut'])
            self.assertFalse(receipt['groupExistsAfterCleanup'])
            self.assertTrue(receipt['completionWaiterStopped'])
            self.assertGreater(receipt['pid'], 0)
            self.assertIn('processCompletionObservedElapsedSeconds', receipt)

    def test_nonzero_reader_remains_failure_despite_green_output(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            with self.native_substitute(results, json.dumps(GREEN), 65):
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    read_from_actual_caller(results)
            self.assertEqual(caught.exception.returncode, 65)
            self.assertTrue((results / 'result-read-command.log').is_file(), 'Failed reader output was discarded')
            self.assertEqual(json.loads((results / 'result-read-command.log').read_text()), GREEN)
            receipt = json.loads((results / 'result-read-process.json').read_text())
            self.assertEqual(receipt['exitCode'], 65)
            self.assertFalse(receipt['groupExistsAfterCleanup'])

    def test_exited_leader_cannot_leave_a_descendant_writing_the_result(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            program = ('import os,sys,time; child=os.fork(); '
                       'time.sleep(2) if child==0 else None; '
                       'os._exit(0) if child==0 else None; '
                       'print(' + repr(json.dumps(GREEN)) + ', flush=True)')
            with self.native_substitute(results, '', program=program):
                self.assertEqual(read_from_actual_caller(results), GREEN)
            path = results / 'result-read-process.json'
            self.assertTrue(path.is_file(), 'Descendant ownership was not recorded')
            receipt = json.loads(path.read_text())
            self.assertTrue(receipt['groupTermSent'])
            self.assertFalse(receipt['groupExistsAfterCleanup'])
            with self.assertRaises(ProcessLookupError):
                os.killpg(receipt['processGroup'], 0)

    def test_virtual_61_second_reader_cannot_inherit_lifecycle_180_second_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            original_error = None
            def reader(command, log, receipt, timeout, **options):
                nonlocal original_error
                log.write_text(json.dumps(GREEN))
                if timeout < 61:
                    original_error = subprocess.TimeoutExpired(command, timeout)
                    raise original_error
                return {'launched': True, 'groupExistsAfterCleanup': False}
            with mock.patch.object(replay, 'run_owned_phase', side_effect=reader), \
                    self.native_substitute(results, json.dumps(GREEN)):
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    read_from_actual_caller(results)
            self.assertIs(caught.exception, original_error)
            self.assertEqual(caught.exception.timeout, 60)

    def test_unconfirmed_group_cannot_supply_a_successful_summary(self):
        for remaining in [True, None, 0]:
            with self.subTest(remaining=remaining), tempfile.TemporaryDirectory() as directory:
                results = Path(directory)
                def reader(command, log, receipt, timeout, **options):
                    log.write_text(json.dumps(GREEN))
                    return {'launched': True, 'groupExistsAfterCleanup': remaining}
                with mock.patch.object(replay, 'run_owned_phase', side_effect=reader), \
                        self.native_substitute(results, json.dumps(GREEN)):
                    with self.assertRaisesRegex(ValueError, 'cleanup'):
                        read_from_actual_caller(results)

    def test_existing_evidence_is_not_overwritten_or_relaunched(self):
        for filename in ['result-read-command.log', 'result-read-process.json']:
            with self.subTest(filename=filename), tempfile.TemporaryDirectory() as directory:
                results = Path(directory)
                path = results / filename
                path.write_text('preserved')
                with self.native_substitute(results, json.dumps(GREEN)) as launch:
                    with self.assertRaises(FileExistsError):
                        read_from_actual_caller(results)
                launch.assert_not_called()
                self.assertEqual(path.read_text(), 'preserved')

    def test_malformed_output_is_not_replaced_by_green_log_text(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            with self.native_substitute(results, 'TEST SUCCEEDED; Executed 1 test'):
                with self.assertRaises(json.JSONDecodeError):
                    read_from_actual_caller(results)


if __name__ == '__main__':
    unittest.main()
