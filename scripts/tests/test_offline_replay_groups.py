import json
import contextlib
import io
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as runner


def successful_receipts(target, group, tests):
    (target / "test-process.json").write_text(json.dumps({"launched": True, "exitCode": 0, "timedOut": False}))
    (target / "ui-completion.json").write_text(json.dumps({"group": group, "executedTests": len(tests), "result": "passed"}))


class ReplayGroupTests(unittest.TestCase):
    def green_groups(self, root):
        for group, tests in runner.TEST_GROUPS.items():
            (root / group).mkdir()
            (root / group / "selection.json").write_text(json.dumps({"group": group, "tests": tests}))
            successful_receipts(root / group, group, tests)
            (root / group / "summary.json").write_text(json.dumps({"totalTestCount": len(tests), "passedTests": len(tests), "failedTests": 0, "skippedTests": 0}))

    def test_failed_collected_green_counts_do_not_pass_independent_aggregate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.green_groups(root)
            failed = root / "help-max-en"
            (failed / "summary.json").unlink()
            (failed / "test-process.json").write_text(json.dumps({"launched": True, "exitCode": 65, "timedOut": False}))
            (failed / "first-failure-observation.json").write_text(json.dumps({"phase": "ui-test", "errorType": "CalledProcessError"}))
            (failed / "ui-completion.json").unlink()
            bundle = failed / "Synthetic.xcresult"
            bundle.mkdir()
            with self.assertRaises((ValueError, FileNotFoundError)):
                runner.verify_group_results(root)

            def phase(command, log, receipt, timeout, **kwargs):
                log.write_text(json.dumps({"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}))
                return {"launched": True, "groupExistsAfterCleanup": False}

            with patch.object(runner, "run_owned_phase", side_effect=phase):
                runner.collect_failed_test_results(bundle, failed, time.monotonic() + 1)
            stream = io.StringIO()
            with contextlib.redirect_stdout(stream), self.assertRaises((ValueError, FileNotFoundError)):
                runner.verify_group_results(root)
            self.assertNotIn("FULL GATE PASS", stream.getvalue())
            self.assertTrue((failed / "failed-summary.json").is_file())
            self.assertFalse((failed / "summary.json").exists())

    def test_exit65_or_timeout_rejects_even_green_counters(self):
        for receipt in [{"launched": True, "exitCode": 65, "timedOut": False},
                        {"launched": True, "exitCode": 0, "timedOut": True},
                        {"launched": True, "exitCode": False, "timedOut": False}]:
            with self.subTest(receipt=receipt), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.green_groups(root)
                (root / "help-max-en/test-process.json").write_text(json.dumps(receipt))
                with self.assertRaises(ValueError):
                    runner.verify_group_results(root)

    def test_first_failure_latch_rejects_green_process_and_counters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.green_groups(root)
            (root / "help-max-en/first-failure-observation.json").write_text(json.dumps({"phase": "ui-test"}))
            with self.assertRaises(ValueError):
                runner.verify_group_results(root)

    def test_missing_or_invalid_completion_rejects_green_counters(self):
        for completion in [None, {"group": "help-max-en", "executedTests": 1, "result": "failed"}]:
            with self.subTest(completion=completion), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.green_groups(root)
                target = root / "help-max-en/ui-completion.json"
                if completion is None:
                    target.unlink()
                else:
                    target.write_text(json.dumps(completion))
                with self.assertRaises((ValueError, FileNotFoundError)):
                    runner.verify_group_results(root)

    def test_independent_cli_rejects_failed_receipts_with_green_counters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.green_groups(root)
            command = [sys.executable, "-B", str(Path(runner.__file__)), "--verify-groups", str(root)]
            normal = subprocess.run(command, text=True, capture_output=True, timeout=10)
            self.assertEqual(normal.returncode, 0, normal.stderr)
            self.assertIn("FULL GATE PASS", normal.stdout)
            for receipt in [{"launched": True, "exitCode": 65, "timedOut": False},
                            {"launched": True, "exitCode": 0, "timedOut": True}]:
                with self.subTest(receipt=receipt):
                    (root / "help-max-en/test-process.json").write_text(json.dumps(receipt))
                    failed = subprocess.run(command, text=True, capture_output=True, timeout=10)
                    self.assertNotEqual(failed.returncode, 0)
                    self.assertNotIn("FULL GATE PASS", failed.stdout)

    def test_partition_is_disjoint_and_covers_all_31_language_tests(self):
        root = Path(__file__).resolve().parents[2] / "mobile-ios/UITests"
        expected = set()
        for suite in ("OfflineReplayUITests", "UIClarityUITests", "DashboardEditingUITests", "SmallViewportUIRegression", "SmallViewportStatusUIRegression", "LocalizationHelpUITests"):
            expected.update("TelemetryUITests/" + suite + "/" + name for name in re.findall(r"func (test\w+)\(", (root / (suite + ".swift")).read_text()))
        expected.update("TelemetryUITests/TelemetryUITests/" + name for name in ("testMeasurementExportControlIsVisible", "testMeasurementCSVExportControlIsVisible"))
        replay, layout = runner.TEST_GROUPS["replay"], runner.TEST_GROUPS["layout"]
        self.assertEqual((len(replay), len(layout)), (10, 14))
        self.assertFalse(set(replay) & set(layout))
        route = runner.TEST_GROUPS.get('replay-route')
        self.assertEqual(route, ['TelemetryUITests/OfflineReplayUITests/testRecordedGPSRouteContainsOnlySelectedTimePrefix'])
        self.assertFalse(set(route) & set(replay))
        help_tests=runner.TEST_GROUPS["help"]
        self.assertEqual(len(help_tests),4)
        maximum = []
        for language, suffix in [('en', 'English'), ('ko', 'Korean')]:
            group = 'help-max-' + language
            self.assertIn(group, runner.TEST_GROUPS)
            self.assertEqual(runner.TEST_GROUPS[group], ['TelemetryUITests/LocalizationHelpUITests/testEveryGuideAtMaximumTextShowsWholeNumberedImageAndClosesZoomIn' + suffix])
            maximum.extend(runner.TEST_GROUPS[group])
        all_tests = [test for group in runner.TEST_GROUPS.values() for test in group]
        self.assertEqual(len(all_tests), 31)
        self.assertEqual(len(set(all_tests)), 31)
        self.assertFalse(set(help_tests) & set(maximum))
        self.assertFalse((set(replay)|set(layout)) & (set(help_tests)|set(maximum)))
        self.assertEqual(set(all_tests), expected)
        self.assertEqual(len(expected), 31)

    def test_aggregate_requires_both_exact_groups_and_clean_counters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for group, tests in runner.TEST_GROUPS.items():
                (root / group).mkdir()
                (root / group / "selection.json").write_text(json.dumps({"group": group, "tests": tests}))
                successful_receipts(root / group, group, tests)
                (root / group / "summary.json").write_text(json.dumps({"totalTestCount":len(tests),"passedTests":len(tests),"failedTests":0,"skippedTests":0}))
            runner.verify_group_results(root)
            target = root / "layout/summary.json"
            original = target.read_text()
            for field in ("failedTests", "skippedTests", "passedTests", "totalTestCount"):
                data = json.loads(original); data[field] += 1
                target.write_text(json.dumps(data))
                with self.subTest(field=field), self.assertRaises(ValueError): runner.verify_group_results(root)
            target.write_text(original)
            selection = root / "layout/selection.json"
            data = json.loads(selection.read_text()); data["tests"][0] = runner.TEST_GROUPS["replay"][0]
            selection.write_text(json.dumps(data))
            with self.assertRaises(ValueError): runner.verify_group_results(root)
            target.unlink()
            with self.assertRaises((ValueError, FileNotFoundError)): runner.verify_group_results(root)

    def test_workflow_includes_every_partition_and_downloads_the_new_group(self):
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/native-reliability.yml').read_text()
        matrix = re.search(r'group:\s*\[([^\]]+)\]', workflow)
        self.assertIsNotNone(matrix)
        self.assertEqual([part.strip() for part in matrix.group(1).split(',')], ['replay', 'replay-route', 'layout', 'help', 'help-max-en', 'help-max-ko'])
        for group in ['replay', 'replay-route', 'layout', 'help', 'help-max-en', 'help-max-ko']:
            self.assertIn('name: offline-replay-' + group + '-${{ github.sha }}', workflow)
            self.assertIn('path: ui-results/' + group, workflow)
        from test_layout_runner_budget import workflow_timeout
        from test_native_ui_scheduling import job_block
        self.assertEqual(workflow_timeout(job_block(workflow, 'native-replay-ui'), 'layout'), 67)
        self.assertEqual(workflow_timeout(job_block(workflow, 'native-replay-ui'), 'replay'), 57)
        self.assertIn("if [ \"$UI_GROUP_RESULT\" != \"success\" ]", workflow)

    def test_missing_skipped_or_duplicated_route_cannot_pass_aggregate(self):
        self.assertIn('replay-route', runner.TEST_GROUPS)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for group, tests in runner.TEST_GROUPS.items():
                (root / group).mkdir()
                (root / group / 'selection.json').write_text(json.dumps({'group': group, 'tests': tests}))
                successful_receipts(root / group, group, tests)
                if group != 'replay-route':
                    (root / group / 'summary.json').write_text(json.dumps({'totalTestCount': len(tests), 'passedTests': len(tests), 'failedTests': 0, 'skippedTests': 0}))
            with self.assertRaises(FileNotFoundError): runner.verify_group_results(root)
            summary = root / 'replay-route/summary.json'
            summary.write_text(json.dumps({'totalTestCount': 1, 'passedTests': 0, 'failedTests': 0, 'skippedTests': 1}))
            with self.assertRaises(ValueError): runner.verify_group_results(root)
            summary.write_text(json.dumps({'totalTestCount': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}))
            (root / 'replay-route/selection.json').write_text(json.dumps({'group': 'replay-route', 'tests': [runner.TEST_GROUPS['replay'][0]]}))
            with self.assertRaises(ValueError): runner.verify_group_results(root)

    def test_missing_skipped_or_wrong_language_cannot_pass_aggregate(self):
        for missing in ('help-max-en', 'help-max-ko'):
            with self.subTest(group=missing):
                self.assertIn(missing, runner.TEST_GROUPS)
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    for group, tests in runner.TEST_GROUPS.items():
                        (root / group).mkdir()
                        (root / group / 'selection.json').write_text(json.dumps({'group': group, 'tests': tests}))
                        successful_receipts(root / group, group, tests)
                        if group != missing:
                            (root / group / 'summary.json').write_text(json.dumps({'totalTestCount': len(tests), 'passedTests': len(tests), 'failedTests': 0, 'skippedTests': 0}))
                    with self.assertRaises(FileNotFoundError):
                        runner.verify_group_results(root)
                    target = root / missing / 'summary.json'
                    target.write_text(json.dumps({'totalTestCount': 1, 'passedTests': 0, 'failedTests': 0, 'skippedTests': 1}))
                    with self.assertRaises(ValueError):
                        runner.verify_group_results(root)
                    target.write_text(json.dumps({'totalTestCount': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}))
                    selection = root / missing / 'selection.json'
                    other = 'help-max-ko' if missing == 'help-max-en' else 'help-max-en'
                    selection.write_text(json.dumps({'group': missing, 'tests': runner.TEST_GROUPS[other]}))
                    with self.assertRaises(ValueError):
                        runner.verify_group_results(root)

if __name__ == "__main__": unittest.main()
