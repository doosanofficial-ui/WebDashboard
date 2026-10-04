from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_offline_replay as runner

SE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation'
PHONE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
def runtime(version, devices, available=True):
    return {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-' + version.replace('.', '-'),
            'version': version, 'isAvailable': available,
            'supportedDeviceTypes': [{'identifier': device, 'productFamily': 'iPhone'} for device in devices]}

class SEViewportRunnerTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(hasattr(runner, "select_ui_destination"), "SE destination selection is not registered")
        self.assertTrue(hasattr(runner, "SE_VIEWPORT_TESTS"), "SE repeated selectors are not registered")

    def test_requires_exact_se3_on_ios27_even_with_other_phones_and_ios28(self):
        data = {'runtimes': [runtime('28.0', [SE]), runtime('27.0', [PHONE]), runtime('27.0.1', [SE, PHONE])]}
        self.assertEqual(runner.select_ui_destination(data, se_viewport=True),
                         ('com.apple.CoreSimulator.SimRuntime.iOS-27-0-1', SE))
        self.assertEqual(runner.select_ui_destination(data),
                         ('com.apple.CoreSimulator.SimRuntime.iOS-27-0', PHONE))
        self.assertEqual(len(data['runtimes'][2]['supportedDeviceTypes']), 2, 'Selection must not mutate the catalog')

    def test_missing_se_or_ios27_is_failure_without_fallback(self):
        for runtimes in ([], [runtime('27.0', [PHONE])], [runtime('26.2', [SE])],
                         [runtime('28.0', [SE])], [runtime('27.0', [SE], available=False)],
                         [runtime('26.2', [SE]), runtime('27.0', [PHONE])]):
            with self.subTest(runtimes=runtimes), self.assertRaises(ValueError):
                runner.select_ui_destination({'runtimes': runtimes}, se_viewport=True)

    def test_two_se_reexecutions_remain_subset_of_30_unique_tests(self):
        self.assertEqual(runner.SE_VIEWPORT_TESTS, [
            'TelemetryUITests/SmallViewportUIRegression/testSmallViewportLiveAndEditorReachability',
            'TelemetryUITests/SmallViewportStatusUIRegression/testStatusAndEditingHelpRemainAccessibleAtMaximumText'])
        existing = [test for group in runner.TEST_GROUPS.values() for test in group]
        self.assertEqual((len(existing), len(set(existing))), (30, 30))
        self.assertTrue(set(runner.SE_VIEWPORT_TESTS).issubset(runner.TEST_GROUPS['layout']))
        clean = {'totalTestCount': 2, 'passedTests': 2, 'failedTests': 0, 'skippedTests': 0}
        runner.verify_summary(clean, len(runner.SE_VIEWPORT_TESTS))
        for field in ('failedTests', 'skippedTests', 'passedTests', 'totalTestCount'):
            with self.subTest(field=field), self.assertRaises(ValueError):
                runner.verify_summary({**clean, field: clean[field] + 1}, 2)

if __name__ == '__main__': unittest.main()
