import math
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bootstatus_stack_admission as admission


class StackAdmissionTests(unittest.TestCase):
    def context(self, **changes):
        identity = {
            'processInstanceID': 71, 'pid': 912, 'phase': 'bootstatus',
            'simulator': 'DE44ADF1-75C5-4D24-AEAC-DDA5E472B8FF',
            'executable': admission.NATIVE_SIMCTL,
        }
        context = dict(mode='enabled', own_launch_authorized=True,
                       stable_reference_verified=True, cleanup_verified=True,
                       original=identity, event=dict(identity), now=120.0,
                       deadline=180.0, requested_seconds=2.0)
        context.update(changes)
        return context

    def test_status_query_is_readonly_and_bounded(self):
        run = Mock(return_value=subprocess.CompletedProcess([], 0,
                   stdout='Developer mode is currently disabled.\n', stderr=''))
        self.assertEqual(admission.read_developer_mode(run)['mode'], 'disabled')
        run.assert_called_once_with(['/usr/sbin/DevToolsSecurity', '-status'],
                                    capture_output=True, text=True, timeout=5)

    def test_only_exact_successful_status_is_accepted(self):
        for output, code, expected in [
            ('Developer mode is currently enabled.\n', 0, 'enabled'),
            ('Developer mode is currently disabled.\n', 0, 'disabled'),
            ('not enabled', 0, 'unknown'),
            ('Developer mode is currently enabled.\nextra', 0, 'unknown'),
            ('Developer mode is currently enabled.', 1, 'unknown'),
        ]:
            with self.subTest(output=output, code=code):
                run = Mock(return_value=subprocess.CompletedProcess([], code,
                           stdout=output, stderr=''))
                self.assertEqual(admission.read_developer_mode(run)['mode'], expected)

    def test_status_timeout_or_denial_remains_unknown(self):
        for error in [subprocess.TimeoutExpired('status', 5), PermissionError(1, 'denied')]:
            with self.subTest(error=type(error).__name__):
                self.assertEqual(admission.read_developer_mode(Mock(side_effect=error))['mode'],
                                 'unknown')

    def test_missing_status_output_remains_unknown(self):
        run = Mock(return_value=subprocess.CompletedProcess([], 0, stdout=None, stderr=''))
        self.assertEqual(admission.read_developer_mode(run)['mode'], 'unknown')

    def test_permission_and_native_proofs_cannot_be_inferred(self):
        for values in [dict(mode='disabled'), dict(mode='unknown'),
                       dict(own_launch_authorized=False),
                       dict(stable_reference_verified=False), dict(cleanup_verified=False)]:
            with self.subTest(values=values):
                self.assertFalse(admission.plan_stack_observation(**self.context(**values))['eligible'])
        for key in ('own_launch_authorized', 'stable_reference_verified', 'cleanup_verified'):
            for value in (None, 1, 'true'):
                with self.subTest(key=key, value=value):
                    self.assertFalse(admission.plan_stack_observation(
                        **self.context(**{key: value}))['eligible'])

    def test_same_pid_with_different_instance_is_rejected(self):
        context = self.context()
        context['event']['processInstanceID'] += 1
        result = admission.plan_stack_observation(**context)
        self.assertFalse(result['eligible'])
        self.assertEqual(result['reason'], 'identity-mismatch')

    def test_foreign_uuid_phase_executable_or_pid_is_rejected(self):
        for key, value in [('simulator', '2AE3C623-0726-44C5-93E8-0B6FA16BBDA3'),
                           ('phase', 'test-process'), ('executable', '/bin/sh'), ('pid', 913)]:
            with self.subTest(key=key):
                context = self.context()
                context['event'][key] = value
                self.assertFalse(admission.plan_stack_observation(**context)['eligible'])

    def test_original_identity_must_be_native_owned_bootstatus(self):
        for key, value in [('phase', 'boot'), ('executable', '/bin/sh'),
                           ('simulator', 'not-a-UUID'), ('pid', 0), ('processInstanceID', 0)]:
            with self.subTest(key=key):
                context = self.context()
                context['original'][key] = value
                context['event'] = dict(context['original'])
                self.assertFalse(admission.plan_stack_observation(**context)['eligible'])

    def test_boolean_event_pid_cannot_impersonate_integer_pid(self):
        context = self.context()
        context['original']['pid'] = 1
        context['event'] = dict(context['original'], pid=True)
        self.assertFalse(admission.plan_stack_observation(**context)['eligible'])

    def test_no_budget_extension_and_separate_cleanup_is_required(self):
        result = admission.plan_stack_observation(**self.context(now=179.5))
        self.assertTrue(result['eligible'])
        self.assertEqual(result['maximumObservationSeconds'], 0.5)
        self.assertEqual(result['originalDeadline'], 180.0)
        self.assertEqual(result['cleanupTarget'], 'original-stable-reference')
        self.assertFalse(result['nativeExecutionPerformed'])
        for changes in [dict(now=180.0), dict(now=181.0), dict(now=math.nan),
                        dict(deadline=math.inf), dict(requested_seconds=0),
                        dict(requested_seconds=math.inf), dict(requested_seconds=3)]:
            with self.subTest(changes=changes):
                self.assertFalse(admission.plan_stack_observation(**self.context(**changes))['eligible'])

    def test_overflowing_clock_or_difference_is_blocked(self):
        for changes in [dict(now=10**400), dict(now=-1e308, deadline=1e308),
                        dict(now=-(10**308), deadline=10**308)]:
            with self.subTest(changes=changes):
                self.assertFalse(admission.plan_stack_observation(**self.context(**changes))['eligible'])


if __name__ == '__main__':
    unittest.main()
