import json
from pathlib import Path
import re
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as runner

class ReplayGroupTests(unittest.TestCase):
    def test_partition_is_disjoint_and_covers_all_31_language_tests(self):
        root = Path(__file__).resolve().parents[2] / "mobile-ios/UITests"
        expected = set()
        for suite in ("OfflineReplayUITests", "UIClarityUITests", "DashboardEditingUITests", "SmallViewportUIRegression", "SmallViewportStatusUIRegression", "LocalizationHelpUITests"):
            expected.update("TelemetryUITests/" + suite + "/" + name for name in re.findall(r"func (test\w+)\(", (root / (suite + ".swift")).read_text()))
        expected.update("TelemetryUITests/TelemetryUITests/" + name for name in ("testMeasurementExportControlIsVisible", "testMeasurementCSVExportControlIsVisible"))
        replay, layout = runner.TEST_GROUPS["replay"], runner.TEST_GROUPS["layout"]
        self.assertEqual((len(replay), len(layout)), (11, 14))
        self.assertFalse(set(replay) & set(layout))
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
        self.assertEqual([part.strip() for part in matrix.group(1).split(',')], ['replay', 'layout', 'help', 'help-max-en', 'help-max-ko'])
        for group in ['replay', 'layout', 'help', 'help-max-en', 'help-max-ko']:
            self.assertIn('name: offline-replay-' + group + '-${{ github.sha }}', workflow)
            self.assertIn('path: ui-results/' + group, workflow)
        self.assertIn('timeout-minutes: 40', workflow)
        self.assertIn("if [ \"$UI_GROUP_RESULT\" != \"success\" ]", workflow)

    def test_missing_skipped_or_wrong_language_cannot_pass_aggregate(self):
        for missing in ('help-max-en', 'help-max-ko'):
            with self.subTest(group=missing):
                self.assertIn(missing, runner.TEST_GROUPS)
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    for group, tests in runner.TEST_GROUPS.items():
                        (root / group).mkdir()
                        (root / group / 'selection.json').write_text(json.dumps({'group': group, 'tests': tests}))
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
