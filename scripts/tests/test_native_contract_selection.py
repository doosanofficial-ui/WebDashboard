import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_native_contracts as contracts

ROOT = Path(os.environ.get("NATIVE_CONTRACT_TEST_ROOT", Path(__file__).resolve().parents[2]))


class ExampleCheck(unittest.TestCase):
    __test__ = False
    def __init__(self, identity, fail=False):
        super().__init__("runTest")
        self.identity, self.fail_check = identity, fail
    def id(self):
        return self.identity
    def runTest(self):
        if self.fail_check:
            self.fail("synthetic failed contract")


class NativeContractSelectionTests(unittest.TestCase):
    def suite(self, unrelated_failure=False):
        return unittest.TestSuite([
            ExampleCheck(contracts.FINAL_HELP_GATE, True),
            ExampleCheck("test_fixture.Producer.test_build_integrity"),
            ExampleCheck("unittest.loader._FailedTest.import_error", unrelated_failure)])

    def test_seed_and_se_defer_only_final_bundle_gate_and_keep_other_failures(self):
        for stage in ("seed", "se"):
            selected, report = contracts.select_suite(self.suite(True), stage)
            self.assertEqual(selected.countTestCases(), 2)
            self.assertEqual(report["deferred"], [contracts.FINAL_HELP_GATE])
            self.assertFalse(report["fullValidationPerformed"])
            result = unittest.TestResult()
            selected.run(result)
            self.assertEqual(len(result.failures), 1)

    def test_full_suite_keeps_stale_help_failure(self):
        selected, report = contracts.select_suite(self.suite(), "all")
        self.assertEqual(selected.countTestCases(), 3)
        self.assertEqual(report["deferred"], [])
        self.assertTrue(report["fullValidationPerformed"])
        result = unittest.TestResult()
        selected.run(result)
        self.assertEqual(len(result.failures), 1)

    def test_missing_duplicated_or_unknown_gate_selection_fails_closed(self):
        for stage in ("all", "seed", "se"):
            for tests in ([ExampleCheck("unrelated")],
                          [ExampleCheck(contracts.FINAL_HELP_GATE), ExampleCheck(contracts.FINAL_HELP_GATE)]):
                with self.subTest(stage=stage), self.assertRaises(ValueError):
                    contracts.select_suite(unittest.TestSuite(tests), stage)
        with self.assertRaises(ValueError):
            contracts.select_suite(self.suite(), "unknown")

    def test_cli_preparation_passes_but_full_validation_stays_red(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "scripts/tests"
            tests.mkdir(parents=True)
            (tests / "test_help_assets.py").write_text('''import unittest
class HelpAssetGateTests(unittest.TestCase):
    def test_bundled_captures_and_provenance_are_complete(self):
        self.fail("stale-image-fixture")
    def test_rejects_corrupt_capture(self):
        self.assertTrue(True)
''')
            for stage, expected in (("seed", 0), ("se", 0), ("all", 1)):
                result = subprocess.run([sys.executable, "-B", "-O", str(Path(contracts.__file__)),
                                         "--root", str(root), "--suite", stage],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, expected, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(report["fullValidationPassed"], False)
                if stage == "all":
                    self.assertIn("stale-image-fixture", result.stderr)
                else:
                    self.assertEqual(report["deferred"], [contracts.FINAL_HELP_GATE])

    def test_workflow_separates_full_contracts_from_seed_and_se_preparation(self):
        workflow = (ROOT / ".github/workflows/native-reliability.yml").read_text()
        def job(name):
            match = re.search(r"(?ms)^  " + re.escape(name) + r":\n(.*?)(?=^  [\w-]+:\n|\Z)", workflow)
            self.assertIsNotNone(match, name)
            return match.group(1)
        complete, seed, se = job("native-contracts"), job("native-seed"), job("native-se-viewport")
        self.assertIn("verify_native_contracts.py --suite all", complete)
        self.assertNotIn("needs:", complete)
        self.assertIn("verify_native_contracts.py --suite seed", seed)
        self.assertIn("verify_native_contracts.py --suite se", se)
        self.assertNotIn("unittest discover", seed)
        self.assertNotIn("unittest discover", se)
        self.assertIn("run: python scripts/verify_help_assets.py", job("contracts"))
        self.assertIn('Require all 31 UI tests across six disjoint groups', job("native-replay-ui-aggregate"))
        self.assertNotIn("continue-on-error", workflow)


def load_tests(loader, tests, pattern):
    # ExampleCheck is a nested-run fixture, not an independently discoverable test.
    return loader.loadTestsFromTestCase(NativeContractSelectionTests)
