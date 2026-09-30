import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("ios_lifecycle_runner", Path(__file__).resolve().parents[1] / "verify_ios_lifecycle.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)

class LifecycleRunnerTests(unittest.TestCase):
    def test_selects_latest_available_ios_and_compatible_iphone(self):
        data = {"runtimes": [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0", "version": "18.0", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "iphone", "productFamily": "iPhone"}]},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "ipad", "productFamily": "iPad"}, {"identifier": "iphone-new", "productFamily": "iPhone"}]},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-28-0", "version": "28.0", "isAvailable": False, "supportedDeviceTypes": [{"identifier": "phone", "productFamily": "iPhone"}]}]}
        self.assertEqual(runner.select_runtime_and_type(data), ("com.apple.CoreSimulator.SimRuntime.iOS-27-0", "iphone-new"))

    def test_missing_compatible_runtime_is_a_blocker_not_pass(self):
        with self.assertRaises(ValueError):
            runner.select_runtime_and_type({"runtimes": []})

    def test_does_not_choose_an_ipad_only_runtime(self):
        with self.assertRaises(ValueError):
            runner.select_runtime_and_type({"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "ipad", "productFamily": "iPad"}]}]})

    def test_summary_requires_expected_executed_tests(self):
        runner.verify_summary({"totalTestCount": 7, "passedTests": 7, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}, 7)
        for count in [0, 6, 8]:
            with self.subTest(count=count), self.assertRaises(ValueError):
                runner.verify_summary({"totalTestCount": count, "passedTests": count, "failedTests": 0, "skippedTests": 0}, 7)

    def test_skips_failures_and_expected_failures_are_not_pass(self):
        for field in ["failedTests", "skippedTests", "expectedFailures"]:
            summary = {"totalTestCount": 7, "passedTests": 7, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
            summary[field] = 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                runner.verify_summary(summary, 7)

    def test_malformed_or_missing_counters_fail_closed(self):
        for summary in [{}, {"totalTestCount": "7", "passedTests": 7, "failedTests": 0, "skippedTests": 0}, {"totalTestCount": 7, "passedTests": 7, "failedTests": False, "skippedTests": 0}]:
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                runner.verify_summary(summary, 7)

if __name__ == "__main__":
    unittest.main()
