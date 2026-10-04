import json
from pathlib import Path
import re
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as runner

class ReplayGroupTests(unittest.TestCase):
    def test_partition_is_disjoint_and_covers_exact_existing_25(self):
        root = Path(__file__).resolve().parents[2] / "mobile-ios/UITests"
        expected = set()
        for suite in ("OfflineReplayUITests", "UIClarityUITests", "DashboardEditingUITests", "SmallViewportUIRegression", "SmallViewportStatusUIRegression"):
            expected.update("TelemetryUITests/" + suite + "/" + name for name in re.findall(r"func (test\w+)\(", (root / (suite + ".swift")).read_text()))
        expected.update("TelemetryUITests/TelemetryUITests/" + name for name in ("testMeasurementExportControlIsVisible", "testMeasurementCSVExportControlIsVisible"))
        replay, layout = runner.TEST_GROUPS["replay"], runner.TEST_GROUPS["layout"]
        self.assertEqual((len(replay), len(layout)), (11, 14))
        self.assertFalse(set(replay) & set(layout))
        self.assertEqual(set(replay) | set(layout), expected)
        self.assertEqual(len(expected), 25)

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

if __name__ == "__main__": unittest.main()
