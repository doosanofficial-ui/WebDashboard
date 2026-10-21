"""One optional CI-only bootstatus checkpoint; never changes the primary verdict.

No profiler, target signal, app data, raw output, arguments or environment dump.
Numeric PID image queries are disabled without stable identity through completion.
"""
import datetime
import math
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import uuid

import failure_observation

OBSERVE_AFTER_SECONDS = 150
OBSERVATION_BUDGET_SECONDS = 10
REAP_RESERVE_SECONDS = 1
PROBE_LIMIT_SECONDS = 3
MAX_STATE_OUTPUT_BYTES = 128 * 1024

def cleanup_probe(child, deadline, value):
    """Signal before the first reap; no subsequent signal can hit a reused PID."""
    if value.get('cleanupAttempted'):
        return
    value['cleanupAttempted'] = True
    if child is None:
        value['cleanupResolved'] = True
        return
    try:
        os.killpg(child.pid, signal.SIGKILL)
        value['groupKillSent'] = True
    except ProcessLookupError:
        pass
    except OSError as error:
        value['groupKillErrorType'] = type(error).__name__
    # Popen itself may return late. Spend the existing reap reserve once even
    # then; do not parse more data or extend the original primary command budget.
    cleanup_started = time.monotonic()
    cleanup_deadline = cleanup_started + REAP_RESERVE_SECONDS
    value.update(cleanupStartedMonotonic=cleanup_started,
                 cleanupReapBudgetSeconds=REAP_RESERVE_SECONDS)
    try:
        child.wait(timeout=max(0, cleanup_deadline - time.monotonic()))
        value.update(childReaped=True, childExitCode=child.returncode)
    except BaseException as error:
        value['reapErrorType'] = type(error).__name__
    for stream in (child.stdin, child.stdout):
        if stream is not None:
            try:
                stream.close()
            except OSError as error:
                value['pipeCloseErrorType'] = type(error).__name__
    while True:
        try:
            os.killpg(child.pid, 0)
            value['groupExistsAfterCleanup'] = True
        except ProcessLookupError:
            value['groupExistsAfterCleanup'] = False
        except OSError as error:
            value['groupExistsAfterCleanup'] = None
            value['groupProbeErrorType'] = type(error).__name__
        remaining = cleanup_deadline - time.monotonic()
        if value['groupExistsAfterCleanup'] is not True or remaining <= 0:
            break
        time.sleep(min(.01, remaining))
    value['cleanupBeyondObservationDeadline'] = time.monotonic() > deadline
    value['cleanupResolved'] = bool(value.get('childReaped') and value['groupExistsAfterCleanup'] is False)


def read_owned_state(simulator, deadline, primary_complete):
    """Bound one UUID query and its whole new process group to the shared budget.

    Kill the query group before the first reap, even after stdout EOF. This keeps
    its leader PID reserved until the last signal and also stops pipe-holding
    descendants. Parsed response data is distinct from natural process completion.
    """
    began = time.monotonic()
    value = {'startedMonotonic': began, 'deadlineMonotonic': deadline,
             'childReaped': False, 'groupKillSent': False, 'stdoutComplete': False}
    work_deadline = min(deadline - REAP_RESERVE_SECONDS, began + PROBE_LIMIT_SECONDS)
    child = None
    raw = bytearray()
    try:
        if primary_complete.is_set():
            value['notRunReason'] = 'primary-completed-before-query'
            return value
        if time.monotonic() >= work_deadline:
            value['notRunReason'] = 'observation-deadline-reached'
            return value
        child = subprocess.Popen(['xcrun', 'simctl', 'list', 'devices', simulator, '--json'],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            start_new_session=True)
        value.update(pid=child.pid, processGroup=child.pid, launchReturnedMonotonic=time.monotonic())
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            while selector.get_map():
                if primary_complete.is_set():
                    value['notRunReason'] = 'primary-completed-during-query'
                    break
                remaining = work_deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired('owned-state-query', max(0, work_deadline - began))
                for key, _ in selector.select(timeout=min(.02, remaining)):
                    chunk = os.read(key.fileobj.fileno(), min(65536, MAX_STATE_OUTPUT_BYTES + 1 - len(raw)))
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        raw.extend(chunk)
                        if len(raw) > MAX_STATE_OUTPUT_BYTES:
                            value['errorType'] = 'OutputLimitExceeded'
                            return value
            if primary_complete.is_set():
                value['notRunReason'] = 'primary-completed-during-query'
            if time.monotonic() >= work_deadline:
                value['notRunReason'] = 'observation-deadline-reached'
            if 'notRunReason' not in value:
                value['stdoutComplete'] = True
                value['responseObservedMonotonic'] = time.monotonic()
                value['data'] = failure_observation.parse_probe(
                    'owned-simulator-state', raw.decode('utf-8', errors='replace'), simulator)
    except BaseException as error:
        value['errorType'] = type(error).__name__  # No exception text or raw stdout/stderr.
    finally:
        cleanup_probe(child, deadline, value)
        value['finishedMonotonic'] = time.monotonic()
        value['scope'] = 'Owned UUID response only; EOF/data is not a natural-exit or readiness assertion'
    return value


class BootstatusCheckpoint:
    def __init__(self, child, simulator, results, began, phase_deadline, primary_complete):
        self.child, self.simulator, self.results = child, simulator, Path(results)
        self.primary_complete = primary_complete
        self.scheduled = began + OBSERVE_AFTER_SECONDS
        self.deadline = min(self.scheduled + OBSERVATION_BUDGET_SECONDS, phase_deadline)
        self.attempted = False
        self.evidence = None

    def wait_seconds(self):
        return 15 if self.attempted else min(15, max(.001, self.scheduled - time.monotonic()))

    def observe_once(self):
        now = time.monotonic()
        if self.attempted or now < self.scheduled:
            return
        self.attempted = True  # No query/journal error may schedule a retry.
        value = self.evidence = {'schemaVersion': 1, 'simulator': self.simulator,
            'pid': self.child.pid, 'processGroup': self.child.pid,
            'scheduledMonotonic': self.scheduled, 'deadlineMonotonic': self.deadline,
            'startedMonotonic': now, 'latenessSeconds': max(0, now - self.scheduled),
            'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'budgetSeconds': OBSERVATION_BUDGET_SECONDS,
            'image': {'available': False, 'notRunReason':
                'Stable process identity through query completion unavailable; PID image query disabled'},
            'stack': {'available': False, 'notRunReason':
                'Target stack profiling can suspend/resume the primary; no verified non-interfering method in scope'},
            'scope': 'One hosted-CI bootstatus checkpoint; no app data, raw output or readiness claim'}
        try:
            if self.primary_complete.is_set() or self.child.returncode is not None:
                value['notRunReason'] = 'primary-completed-before-checkpoint'
                return
            if now >= self.deadline - REAP_RESERVE_SECONDS:
                value['notRunReason'] = 'observation-deadline-reached'
                return
            value['state'] = read_owned_state(self.simulator, self.deadline, self.primary_complete)
        except BaseException as error:
            value['errorType'] = type(error).__name__
        finally:
            value['finishedMonotonic'] = time.monotonic()
            failure_observation.safe_write(self.results / 'bootstatus-inflight-observation.json', value)


def checkpoint_for(command, child, results, began, deadline, primary_complete):
    """No local/native opt-in or additional phase gets this checkpoint."""
    try:
        # Match the caller's forward addition; subtracting rounded clocks can lose 180.
        if (os.environ.get('GITHUB_ACTIONS') != 'true' or sys.platform != 'darwin'
                or os.name != 'posix' or not math.isfinite(began) or not math.isfinite(deadline)
                or deadline != began + 180 or len(command) != 5
                or command[:3] != ['xcrun', 'simctl', 'bootstatus'] or command[4] != '-b'):
            return None
        simulator = str(uuid.UUID(command[3])).upper()
        return BootstatusCheckpoint(child, simulator, results, began, deadline, primary_complete)
    except Exception:
        return None


if __name__ == '__main__':
    raise SystemExit(2)
