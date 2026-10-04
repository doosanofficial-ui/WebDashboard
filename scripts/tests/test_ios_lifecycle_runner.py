import importlib.util
from pathlib import Path
import unittest
import tempfile
import sys
import subprocess
import re

SPEC = importlib.util.spec_from_file_location("ios_lifecycle_runner", Path(__file__).resolve().parents[1] / "verify_ios_lifecycle.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)

class LifecycleRunnerTests(unittest.TestCase):
    def test_ascii_staging_preserves_sources_and_excludes_generated_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "workspace\u00a0name"
            source = root / "mobile-ios"
            source.mkdir(parents=True)
            (source / "project.yml").write_text("version: fixture")
            (source / "Fixture.xcodeproj").mkdir()
            (source / ".build").mkdir()
            destination = Path(directory) / "ascii-stage"
            runner.stage_sources(root, destination)
            self.assertEqual((destination / "project.yml").read_text(), "version: fixture")
            self.assertFalse((destination / "Fixture.xcodeproj").exists())
            self.assertFalse((destination / ".build").exists())
            self.assertTrue((source / "Fixture.xcodeproj").is_dir())

    def test_staging_cannot_overwrite_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "mobile-ios").mkdir()
            with self.assertRaises(FileExistsError):
                runner.stage_sources(root, root)
    def test_selects_pinned_ios27_even_when_ios28_is_available(self):
        data = {"runtimes": [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0", "version": "18.0", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "iphone", "productFamily": "iPhone"}]},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "ipad", "productFamily": "iPad"}, {"identifier": "iphone-new", "productFamily": "iPhone"}]},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-28-0", "version": "28.0", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "phone", "productFamily": "iPhone"}]}]}
        self.assertEqual(runner.select_runtime_and_type(data), ("com.apple.CoreSimulator.SimRuntime.iOS-27-0", "iphone-new"))

    def test_ios26_cannot_be_a_fallback(self):
        with self.assertRaises(ValueError):
            runner.select_runtime_and_type({"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-2", "version": "26.2", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "phone", "productFamily": "iPhone"}]}]})

    def test_toolchain_rejects_wrong_xcode_or_sdk_and_records_build(self):
        evidence = runner.verify_toolchain("Xcode 27.0\nBuild version 27A266a\n", "27.0", "27.0")
        self.assertEqual(evidence["xcode_build"], "27A266a")
        for xcode, ios, simulator in [("Xcode 26.2\nBuild version 17C52", "27.0", "27.0"), ("Xcode 27.0\nBuild version 27A266a", "26.2", "27.0"), ("Xcode 27.0\nBuild version 27A266a", "27.0", "28.0")]:
            with self.subTest(xcode=xcode, ios=ios, simulator=simulator), self.assertRaises(ValueError):
                runner.verify_toolchain(xcode, ios, simulator)

    def test_numeric_ios27_patch_versions_are_allowed_and_preserved(self):
        self.assertEqual(runner.verify_toolchain("Xcode 27.0.1\nBuild version 27A999", "27.0.2", "27.1")["xcode_version"], "27.0.1")
        data = {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0-1", "version": "27.0.1", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "phone", "productFamily": "iPhone"}]}]}
        self.assertEqual(runner.select_runtime_and_type(data)[0], data["runtimes"][0]["identifier"])
        for version in ("26.9", "28.0", "270.0", "27.beta", "27.0beta"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                runner.verify_toolchain(f"Xcode {version}\nBuild version fixture", "27.0", "27.0")

    def test_test_command_nonzero_cannot_be_green_with_passing_counters(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                runner.run_test_command([sys.executable, "-c", "print('23 passed, 0 failed'); raise SystemExit(65)"], log, 10)
            self.assertEqual(failure.exception.returncode, 65)
            self.assertIn("23 passed", log.read_text())
            runner.run_test_command([sys.executable, "-c", "print('success')"], log, 10)
            self.assertIn("success", log.read_text())

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

    def test_default_gate_matches_all_declared_hosted_tests(self):
        root = Path(__file__).resolve().parents[2]
        declarations = []
        for path in sorted((root / "mobile-ios/LifecycleTests").glob("*.swift")):
            declarations.extend(re.findall(r"^\s+func (test\w+)\(", path.read_text(), re.MULTILINE))
        self.assertIn("sources: [LifecycleTests]", (root / "mobile-ios/lifecycle-tests.yml").read_text())
        self.assertEqual(len(declarations), 83)
        self.assertEqual(runner.EXPECTED_TEST_COUNT, len(declarations))
        self.assertIn("testCancelledComputedManySignalSeekCannotPublish", declarations)
        self.assertIn("testStopAfterComputedManySignalSeekDiscardsResultAndAllOwnedState", declarations)

    def test_expanded_gate_rejects_old_green_or_partial_counts(self):
        expected = runner.EXPECTED_TEST_COUNT
        runner.verify_summary({"totalTestCount": 83, "passedTests": 83, "failedTests": 0,
                               "skippedTests": 0, "expectedFailures": 0}, expected)
        for count in [0, 81, 82, 84]:
            with self.subTest(count=count), self.assertRaises(ValueError):
                runner.verify_summary({"totalTestCount": count, "passedTests": count,
                                       "failedTests": 0, "skippedTests": 0}, expected)

    def test_expanded_gate_never_accepts_skips_or_expected_failures(self):
        for field in ["failedTests", "skippedTests", "expectedFailures"]:
            summary = {"totalTestCount": 83, "passedTests": 83, "failedTests": 0,
                       "skippedTests": 0, "expectedFailures": 0}
            summary[field] = 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                runner.verify_summary(summary, 83)

if __name__ == "__main__":
    unittest.main()
