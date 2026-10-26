"""Read already-produced XCTest log bytes; never issue an AX or device call."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import failure_observation as observation
import verify_offline_replay as runner
import test_layout_runner_budget as budgets

LAYOUT = """Test Case '-[TelemetryUITests.DashboardEditingUITests testLandscapeMoveUsesCurrentMeasuredGeometry]' started.
    t =     0.00s Start Test at 2026-10-26 12:03:12.198
    t =     1.06s     Launch local.webdashboard.Telemetry
/PRIVATE/source/UITests/DashboardEditingUITests.swift:9: error: -[TelemetryUITests.DashboardEditingUITests testLandscapeMoveUsesCurrentMeasuredGeometry] : Application 'local.webdashboard.Telemetry' does not have a process ID
    t =   230.87s Tear Down
Test Case '-[TelemetryUITests.DashboardEditingUITests testLandscapeMoveUsesCurrentMeasuredGeometry]' failed (231.929 seconds).
"""
HELP = """Test Case '-[TelemetryUITests.LocalizationHelpUITests testEveryGuideAtMaximumTextShowsWholeNumberedImageAndClosesZoomInKorean]' started.
    t =     0.04s Start Test at 2026-10-26 13:08:23.189
    t =   165.94s Checking existence of `"help-image-live" Image`
    t =   176.80s Find the "help-image-live" Image
    t =   207.89s     Find the "help-image-live" Image (retry 1)
    t =   239.13s     Find the "help-image-live" Image (retry 2)
    t =   269.16s     Collecting debug information to assist test failure triage
/PRIVATE/source/UITests/LocalizationHelpUITests.swift:206: error: -[TelemetryUITests.LocalizationHelpUITests testEveryGuideAtMaximumTextShowsWholeNumberedImageAndClosesZoomInKorean] : Failed to get matching snapshot: Timed out while evaluating UI query.
    t =   447.91s Tear Down
Test Case '-[TelemetryUITests.LocalizationHelpUITests testEveryGuideAtMaximumTextShowsWholeNumberedImageAndClosesZoomInKorean]' failed (456.718 seconds).
"""


class UITestLogObservationTests(unittest.TestCase):
    def setUp(self):
        self.observe = getattr(observation, 'observe_ui_test_log', None)
        self.assertTrue(callable(self.observe), 'Missing passive observation of existing XCTest log boundaries')

    def parse(self, content):
        raw = content.encode('utf-8')
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            log, destination = folder / 'test.log', folder / 'observed.json'
            log.write_bytes(raw)
            with patch.object(observation.subprocess, 'Popen', side_effect=AssertionError('No process/AX/device calls')):
                self.assertTrue(self.observe(log, destination))
            self.assertEqual(log.read_bytes(), raw)
            report = json.loads(destination.read_text())
        self.assertEqual(report['sourceSHA256'], hashlib.sha256(raw).hexdigest())
        self.assertNotIn('PRIVATE', json.dumps(report))
        return report

    def test_launch_and_error_keep_case_clock_anchor_and_log_bracket(self):
        report = self.parse(LAYOUT)
        case = report['cases'][0]
        self.assertEqual(case['case'], 'TelemetryUITests/DashboardEditingUITests/testLandscapeMoveUsesCurrentMeasuredGeometry')
        self.assertEqual(case['startTest'], {'line': 2, 'timestamp': '2026-10-26 12:03:12.198',
                                            'relativeSeconds': 0.0, 'timezone': None})
        self.assertEqual(case['events'][0]['kind'], 'app-launch')
        self.assertEqual(case['events'][0]['relativeSeconds'], 1.06)
        self.assertEqual(case['failures'][0]['logBracketRelativeSeconds'], [1.06, 230.87])
        self.assertIsNone(case['failures'][0]['failureOccurredAt'])
        self.assertEqual(case['outcome'], 'failed')
        self.assertEqual(case['durationSeconds'], 231.929)

    def test_help_queries_preserve_existing_retry_rows_without_inventing_step_or_iteration(self):
        case = self.parse(HELP)['cases'][0]
        events = case['events']
        self.assertEqual([event['kind'] for event in events],
                         ['help-image-exists', 'help-image-find', 'help-image-find', 'help-image-find'])
        self.assertEqual([event['relativeSeconds'] for event in events], [165.94, 176.8, 207.89, 239.13])
        self.assertEqual([event['existingXCTestRetry'] for event in events], [None, None, 1, 2])
        self.assertEqual(events[0]['nextLogBoundary'], {'line': 4, 'relativeSeconds': 176.8})
        for event in events:
            self.assertEqual(event['guide'], 'live')
            self.assertIsNone(event['step'])
            self.assertIsNone(event['iteration'])
        self.assertEqual(case['failures'][0]['kind'], 'ui-query-timeout')
        self.assertEqual(case['failures'][0]['logBracketRelativeSeconds'], [269.16, 447.91])

    def test_next_case_does_not_inherit_anchor_query_or_error_times(self):
        partial = """Test Case '-[TelemetryUITests.DashboardEditingUITests testNextCase]' started.
    t =      nans Launch local.webdashboard.Telemetry
    t =     1.00s Launch local.webdashboard.Telemetry
"""
        case = self.parse(LAYOUT + partial)['cases'][1]
        self.assertIsNone(case['startTest'])
        self.assertEqual(len(case['events']), 1)
        self.assertIsNone(case['events'][0]['nextLogBoundary'])
        self.assertEqual(case['failures'], [])
        self.assertEqual(case['outcome'], 'unknown')

    def test_oversized_log_never_claims_complete_source_or_exact_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            log, destination = folder / 'test.log', folder / 'observed.json'
            log.write_bytes(b'x' * 33)
            with patch.object(observation, 'MAX_UI_LOG_BYTES', 32, create=True):
                self.assertTrue(self.observe(log, destination))
            report = json.loads(destination.read_text())
        self.assertTrue(report['incomplete'])
        self.assertIsNone(report['sourceSHA256'])
        self.assertEqual(report['bytesRead'], 33)

    def test_existing_observation_and_missing_log_stay_optional_without_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            destination = folder / 'observed.json'
            destination.write_text('preserve earlier evidence')
            self.assertFalse(self.observe(folder / 'absent.log', destination))
            self.assertEqual(destination.read_text(), 'preserve earlier evidence')

    def test_long_nonerror_payload_is_skipped_without_changing_normal_error(self):
        # Removing the per-line work bound would silently accept this omitted row.
        content = LAYOUT.replace('/PRIVATE', 'A' * 2048 + '\n/PRIVATE', 1)
        report = self.parse(content)
        self.assertTrue(report['incomplete'])
        self.assertEqual(report['oversizedLineCount'], 1)
        failure = report['cases'][0]['failures'][0]
        self.assertEqual((failure['file'], failure['sourceLine']), ('DashboardEditingUITests.swift', 9))
        self.assertEqual(failure['logBracketRelativeSeconds'], [None, 230.87])
        self.assertIsNone(report['cases'][0]['events'][0]['nextLogBoundary'])

    def test_long_malformed_error_does_not_pollute_following_normal_case(self):
        # A long basename with no .swift used to trigger greedy retries at every position.
        malformed = 'A' * 2048 + ': error: -[TelemetryUITests.DashboardEditingUITests testWrongCase] : payload'
        report = self.parse(LAYOUT.replace('/PRIVATE', malformed + '\n/PRIVATE', 1) + HELP)
        self.assertTrue(report['incomplete'])
        self.assertEqual(report['oversizedLineCount'], 1)
        self.assertEqual([len(case['failures']) for case in report['cases']], [1, 1])
        self.assertEqual(report['cases'][0]['failures'][0]['logBracketRelativeSeconds'], [None, 230.87])
        case = report['cases'][1]
        self.assertEqual(case['case'], 'TelemetryUITests/LocalizationHelpUITests/testEveryGuideAtMaximumTextShowsWholeNumberedImageAndClosesZoomInKorean')
        self.assertEqual(case['startTest']['timestamp'], '2026-10-26 13:08:23.189')
        self.assertEqual((case['failures'][0]['file'], case['failures'][0]['sourceLine']), ('LocalizationHelpUITests.swift', 206))
        self.assertEqual(case['failures'][0]['logBracketRelativeSeconds'], [269.16, 447.91])

    def test_discarded_timing_row_keeps_pending_boundaries_unknown(self):
        timing = '    t =   100.00s ' + 'Z' * 2048
        content = LAYOUT.replace('    t =   230.87s Tear Down', timing + '\n    t =   230.87s Tear Down')
        report = self.parse(content)
        self.assertTrue(report['incomplete'])
        self.assertEqual(report['oversizedLineCount'], 1)
        case = report['cases'][0]
        self.assertIsNone(case['events'][0]['nextLogBoundary'])
        self.assertEqual(case['failures'][0]['logBracketRelativeSeconds'], [1.06, None])
        self.assertEqual(case['outcome'], 'failed')

    def test_near_file_limit_payload_never_reaches_regex_processing(self):
        # Trap the regression before executing any costly regex on the RED path.
        # Normal lines still use the real regex engine and real parser/file I/O.
        fullmatch, search = observation.re.fullmatch, observation.re.search

        def bounded(operation):
            def call(pattern, text, *args, **kwargs):
                self.assertLessEqual(len(text), 1024, 'Oversized parser input reached the regex engine')
                return operation(pattern, text, *args, **kwargs)
            return call

        content = LAYOUT.replace('/PRIVATE', 'Z' * 1500000 + '\n/PRIVATE', 1)
        with patch.object(observation.re, 'fullmatch', side_effect=bounded(fullmatch)), \
                patch.object(observation.re, 'search', side_effect=bounded(search)):
            report = self.parse(content)
        self.assertTrue(report['incomplete'])
        self.assertEqual(report['oversizedLineCount'], 1)
        self.assertEqual(report['cases'][0]['failures'][0]['sourceLine'], 9)

    def test_runner_observation_write_error_cannot_mask_original_ui_failure(self):
        with patch.object(runner.failure_observation, 'observe_ui_test_log', side_effect=OSError('optional write error')) as observe:
            ui, _, _ = budgets.LayoutRunnerBudgetTests().run_selection(['--group', 'layout'])
        self.assertIsNotNone(ui)
        self.assertEqual(observe.call_count, 1, 'Existing test log must be observed once after the original UI command')


if __name__ == '__main__':
    unittest.main()
