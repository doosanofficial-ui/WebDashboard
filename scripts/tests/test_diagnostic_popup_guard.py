"""Rejecting a target crash or accepting unavailable metadata breaks these tests.

Fixtures model window metadata, not captured pixels or app readiness. Only the
native subprocess boundary is mocked; no device or GUI action runs in this suite.
"""
from pathlib import Path
import json
import subprocess
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import diagnostic_popup_guard as guard


class PopupGuardTests(unittest.TestCase):
    def snapshot(self, title='SpringBoard에 대한 문제 리포트', **changes):
        window = dict(ownerBundle='com.apple.ProblemReporter', onScreen=True,
                      title=title, pid=85904, windowNumber=5593)
        window.update(changes)
        return dict(querySucceeded=True, windows=[window])

    def check(self, snapshot):
        return guard.classify_snapshot(snapshot, ('SpringBoard', 'Telemetry'))

    def test_observed_korean_popup_stops_readiness_wait(self):
        result = self.check(self.snapshot())
        self.assertEqual(result['action'], 'pause')
        self.assertEqual(result['reason'], 'matching-error-popup')
        self.assertEqual(result['candidates'][0]['subject'], 'SpringBoard')
        self.assertEqual(result['candidates'][0]['patternEvidence'], 'ko-observed')
        self.assertFalse(result['screenVerified'])

    def test_english_resource_pattern_is_not_claimed_as_visual_observation(self):
        result = self.check(self.snapshot('Problem Report for Telemetry'))
        self.assertEqual(result['action'], 'pause')
        self.assertEqual(result['candidates'][0]['patternEvidence'], 'en-apple-resource')

    def test_title_lookalike_owned_by_other_app_is_ignored(self):
        result = self.check(self.snapshot(ownerBundle='com.example.OtherApp'))
        self.assertEqual(result['action'], 'continue')
        self.assertFalse(result['screenVerified'])

    def test_recognized_unrelated_crash_does_not_stop_target_wait(self):
        self.assertEqual(self.check(self.snapshot('MSTeams에 대한 문제 리포트'))['action'],
                         'continue')

    def test_subject_names_require_exact_match(self):
        self.assertEqual(self.check(self.snapshot('OtherTelemetry에 대한 문제 리포트'))['action'],
                         'continue')

    def test_hidden_untitled_companion_is_ignored(self):
        self.assertEqual(self.check(self.snapshot('', onScreen=False))['action'], 'continue')

    def test_unrecognized_visible_reporter_requires_review(self):
        for title in ('', None, 'Unrecognized localized report'):
            with self.subTest(title=title):
                result = self.check(self.snapshot(title))
                self.assertEqual(result['action'], 'pause')
                self.assertEqual(result['reason'], 'unclassified-error-window')

    def test_unknown_visibility_requires_review(self):
        result = self.check(self.snapshot(onScreen=None))
        self.assertEqual(result['action'], 'pause')

    def test_failed_or_malformed_query_never_allows_normal_wait(self):
        for snapshot in (None, {}, {'querySucceeded': False},
                         {'querySucceeded': 1, 'windows': []},
                         {'querySucceeded': True, 'windows': None},
                         {'querySucceeded': True, 'windows': [None]}):
            with self.subTest(snapshot=snapshot):
                self.assertEqual(self.check(snapshot)['action'], 'pause')

    def test_empty_target_scope_is_not_accepted(self):
        self.assertEqual(guard.classify_snapshot(self.snapshot(), ())['action'], 'pause')

    def test_absent_popup_is_only_metadata_clearance(self):
        result = self.check({'querySucceeded': True, 'windows': []})
        self.assertEqual(result['action'], 'continue')
        self.assertFalse(result['screenVerified'])

    def test_native_query_is_bounded_without_ui_commands(self):
        snapshot = self.snapshot()
        run = Mock(return_value=subprocess.CompletedProcess([], 0,
                   stdout=json.dumps(snapshot), stderr=''))
        self.assertEqual(guard.read_snapshot(run), snapshot)
        args, kwargs = run.call_args
        self.assertEqual(args[0], [sys.executable, guard.__file__, '--native-snapshot'])
        self.assertEqual(kwargs['timeout'], 3)
        self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)

    def test_query_timeout_denial_invalid_json_and_nonzero_exit_stay_unknown(self):
        runs = [Mock(side_effect=subprocess.TimeoutExpired('metadata', 3)),
                Mock(side_effect=PermissionError(1, 'denied')),
                Mock(return_value=subprocess.CompletedProcess([], 1, stdout='{}', stderr='')),
                Mock(return_value=subprocess.CompletedProcess([], 0, stdout='invalid', stderr=''))]
        for run in runs:
            with self.subTest(run=run):
                result = guard.read_snapshot(run)
                self.assertIs(result['querySucceeded'], False)
                self.assertEqual(self.check(result)['action'], 'pause')


if __name__ == '__main__':
    unittest.main()
