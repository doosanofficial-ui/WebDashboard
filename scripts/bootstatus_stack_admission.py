"""Fail-closed planning for a future owned LLDB launch; no debugger or sampler.

An eligible plan is not native safety proof. Launch authorization, a stable
reference, an independent watchdog and connection-loss cleanup must be verified
by a future adapter. LLDB instance IDs alone are not kernel PID-generation tokens.
"""
import math
import subprocess
import uuid

NATIVE_SIMCTL = '/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl'


def read_developer_mode(run=subprocess.run):
    """Read policy only; never enable it, request credentials, or launch a probe."""
    try:
        result = run(['/usr/sbin/DevToolsSecurity', '-status'],
                     capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError) as error:
        return {'mode': 'unknown', 'reason': type(error).__name__}
    modes = {'Developer mode is currently enabled.': 'enabled',
             'Developer mode is currently disabled.': 'disabled'}
    mode = (modes.get(result.stdout.strip(), 'unknown')
            if type(result.returncode) is int and result.returncode == 0 and
            isinstance(result.stdout, str) else 'unknown')
    return {'mode': mode, 'queryExitCode': result.returncode}


def _valid_original(identity):
    if not isinstance(identity, dict):
        return False
    try:
        canonical_uuid = str(uuid.UUID(identity.get('simulator', ''))).upper()
    except (ValueError, TypeError, AttributeError):
        return False
    return (identity.get('phase') == 'bootstatus' and
            identity.get('executable') == NATIVE_SIMCTL and
            identity.get('simulator') == canonical_uuid and
            all(type(identity.get(key)) is int and identity[key] > 0
                for key in ('pid', 'processInstanceID')))


def plan_stack_observation(*, mode, own_launch_authorized, stable_reference_verified,
                           cleanup_verified, original, event, now, deadline,
                           requested_seconds):
    """Plan one observation of the original reference; never attach by PID.

The proof booleans are explicit prerequisites, not facts derived from policy,
PID equality or API availability. This pure gate has no native adapter and is
not integrated into the runner. Deadlines here limit admission/planning only;
they cannot impose a wall-time limit on a future debugger call.
"""
    def blocked(reason):
        return {'eligible': False, 'reason': reason, 'nativeExecutionPerformed': False}

    if mode != 'enabled':
        return blocked('policy-disabled-or-unknown')
    if any(value is not True for value in
           (own_launch_authorized, stable_reference_verified, cleanup_verified)):
        return blocked('native-prerequisite-unverified')
    if not _valid_original(original):
        return blocked('invalid-owned-identity')
    keys = ('processInstanceID', 'pid', 'phase', 'simulator', 'executable')
    if not _valid_original(event) or any(event.get(key) != original[key] for key in keys):
        return blocked('identity-mismatch')
    numbers = (now, deadline, requested_seconds)
    try:
        valid_numbers = all(type(value) in (int, float) and math.isfinite(value)
                            for value in numbers)
    except OverflowError:
        valid_numbers = False
    if not valid_numbers:
        return blocked('invalid-clock-or-budget')
    try:
        remaining = deadline - now
        if not math.isfinite(remaining):
            return blocked('invalid-clock-or-budget')
    except OverflowError:
        return blocked('invalid-clock-or-budget')
    if remaining <= 0 or not 0 < requested_seconds <= 2:
        return blocked('no-observation-budget')
    return {'eligible': True, 'originalDeadline': deadline,
            'maximumObservationSeconds': min(requested_seconds, remaining),
            'cleanupTarget': 'original-stable-reference',
            'nativeExecutionPerformed': False}
