"""Optional first-failure evidence; never changes a verification result.

The CI worker reads allowlisted numeric/owned-UUID state only. It inherits its
supervisor's new process group; no existing device or service is controlled.
"""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time
import uuid

DIAGNOSTIC_BUDGET_SECONDS = 20
PROBE_BUDGET_SECONDS = 3
MAX_PROBE_OUTPUT_BYTES = 2 * 1024 * 1024


def resources():
    value = {'cpuCount': os.cpu_count(), 'physicalHostIdentity': None,
             'scope': 'Guest/runner observations; load is not CPU utilization or a host-cause diagnosis'}
    try:
        value['loadAverage'] = list(os.getloadavg())
    except (AttributeError, OSError):
        value['loadAverage'] = None
    try:
        import resource
        usage = resource.getrusage(resource.RUSAGE_SELF)
        value['runnerUsage'] = {'userCPUSeconds': usage.ru_utime, 'systemCPUSeconds': usage.ru_stime,
            'voluntaryContextSwitches': usage.ru_nvcsw, 'involuntaryContextSwitches': usage.ru_nivcsw,
            'majorFaults': usage.ru_majflt, 'maximumResidentSet': usage.ru_maxrss,
            'maximumResidentSetUnit': 'bytes' if sys.platform == 'darwin' else 'KiB'}
    except (ImportError, AttributeError, OSError):
        value['runnerUsage'] = None
    return value


def failure_snapshot(error, child_exit_code=None, source='caller', observed_monotonic=None):
    """Observation time, never an inferred kernel exit timestamp."""
    value = {'observedMonotonic': time.monotonic() if observed_monotonic is None else observed_monotonic,
        'observedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'errorType': type(error).__name__, 'source': source,
        'childExitCodeBeforeStop': child_exit_code, 'kernelExitTimestamp': None}
    try:
        value['resources'] = resources()
        value['resourcesSampleMonotonic'] = time.monotonic()
    except Exception as snapshot_error:
        value['resources'] = None
        value['resourceErrorType'] = type(snapshot_error).__name__
    return value


def safe_write(path, value, exclusive=True):
    try:
        with path.open('x' if exclusive else 'w', encoding='utf-8') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
        return True
    except Exception:
        return False  # Optional evidence cannot replace the caller's result.


def observe_call(operation, results, phase, timeout):
    """Keep the original subprocess call, kwargs, result and exception object."""
    value = {}
    try:
        began = time.monotonic()
        value = {'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                 'callStartedMonotonic': began, 'timeoutSeconds': timeout,
                 'childExitCode': None, 'kernelExitTimestamp': None,
                 'scope': 'Caller boundary; Popen and kernel-exit times are not measured'}
        value['resources'] = resources()
    except Exception:
        pass
    try:
        result = operation()
        try:
            value['childExitCode'] = getattr(result, 'returncode', None)
            value['returnedNormally'] = True
        except Exception:
            pass
        return result
    except BaseException as error:
        try:
            value['errorType'] = type(error).__name__
            value['childExitCode'] = getattr(error, 'returncode', None)
            value['firstFailure'] = failure_snapshot(error, value['childExitCode'], 'subprocess-call-return')
        except Exception:
            pass
        raise
    finally:
        try:
            returned = time.monotonic()
            value.update(callReturnedMonotonic=returned, elapsedSeconds=returned - began,
                         finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
            safe_write(results / (phase + '-observation.json'), value)
        except Exception:
            pass


def recorded_failure(results, phase, error=None):
    mapping = {'ui-test': 'test-process.json', 'app-build': 'build-process.json'}
    for name in (mapping.get(phase, phase + '.json'), phase + '-observation.json'):
        try:
            receipt = json.loads((results / name).read_text())
            value = receipt.get('firstFailure')
            if isinstance(value, dict):
                return value
            if error is not None and receipt.get('childExitCode'):
                return failure_snapshot(error, receipt['childExitCode'], 'caller-after-subprocess',
                                        receipt.get('callReturnedMonotonic'))
        except Exception:
            pass
    return None


def system_developer_path(path):
    if isinstance(path, str) and re.fullmatch(r'/Applications/[A-Za-z0-9_.-]+\.app/Contents/Developer(?:/usr/bin/xcresulttool)?', path):
        return path
    return None


def selected_xcode(results):
    try:
        raw = json.loads((results / 'toolchain.json').read_text())
        version = re.search(r'^Xcode ([0-9.]+)$', raw.get('xcode', ''), re.MULTILINE)
        build = re.search(r'^Build version ([A-Za-z0-9]+)$', raw.get('xcode', ''), re.MULTILINE)
        override = raw.get('developer_directory_override')
        default = raw.get('xcode_select_default')
        return {'version': version.group(1) if version else None, 'build': build.group(1) if build else None,
            'developerDirectoryOverridePresent': bool(override),
            'effectiveDeveloperDirectory': system_developer_path(override or default),
            'xcodeSelectDefault': system_developer_path(default),
            'source': 'Existing pre-phase toolchain record; non-system paths omitted'}
    except Exception:
        return {'source': 'Pre-phase toolchain record unavailable', 'version': None, 'build': None}


def parse_probe(name, raw, simulator):
    """Never retain raw stdout, environment, arguments, other UUIDs or names."""
    if name == 'owned-simulator-state':
        device = next((d for group in json.loads(raw).get('devices', {}).values() for d in group
                       if isinstance(d, dict) and d.get('udid', '').upper() == simulator), None)
        state = device.get('state') if device else None
        return {'simulator': simulator, 'found': device is not None,
                'state': state if state in ('Booted', 'Shutdown', 'Booting', 'Shutting Down') else None,
                'isAvailable': device.get('isAvailable') if device and type(device.get('isAvailable')) is bool else None}
    if name == 'service-processes':
        counts = {}
        names = {'CoreSimulatorService': 'CoreSimulatorService',
                 'com.apple.CoreSimulator.CoreSimulatorService': 'CoreSimulatorService',
                 'simdiskimaged': 'simdiskimaged', 'SimulatorTrampoline': 'SimulatorTrampoline'}
        for line in raw.splitlines():
            fields = line.split(None, 3)
            if len(fields) == 4:
                service = names.get(Path(fields[3]).name)
                if service:
                    counts[service] = counts.get(service, 0) + 1
        return {'counts': counts, 'scope': 'Allowlisted process presence counts; does not prove service health or measurement activity'}
    if name == 'memory-pages':
        size = re.search(r'page size of ([0-9]+) bytes', raw)
        allowed = ('Pages free', 'Pages active', 'Pages inactive', 'Pages wired down',
                   'Pages occupied by compressor', 'Pageins', 'Pageouts', 'Swapins', 'Swapouts')
        counts = {}
        for key in allowed:
            match = re.search(r'^' + re.escape(key) + r':\s*([0-9]+)\.?\s*$', raw, re.MULTILINE)
            if match:
                counts[key] = int(match.group(1))
        return {'pageSizeBytes': int(size.group(1)) if size else None, 'pageCounts': counts}
    if name == 'selected-xcresulttool':
        return {'path': system_developer_path(raw.strip()), 'scope': 'Resolved at diagnosis time; distinguish from pre-phase selection'}
    if name == 'disk-io':
        rows = []
        for line in raw.splitlines():
            parts = line.split()
            if parts and all(re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', p) for p in parts):
                values = [float(p) for p in parts[:24]]
                if all(math.isfinite(v) for v in values):
                    rows.append(values)
        return {'numericRows': rows[:2], 'scope': 'iostat first report, may be cumulative since boot; not instantaneous disk latency'}
    return {}  # Neutral or unknown probes never publish their output.


def run_probe(name, command, timeout, simulator):
    began = time.monotonic()
    value = {'name': name, 'startedMonotonic': began, 'timeoutSeconds': timeout,
             'childExitCode': None, 'childReaped': False, 'kernelExitTimestamp': None}
    child = None
    try:
        value['launchRequestedMonotonic'] = time.monotonic()
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        value['launchReturnedMonotonic'] = time.monotonic()
        remaining = timeout - (time.monotonic() - began)
        if remaining <= 0:
            raise subprocess.TimeoutExpired(command, timeout)
        # Read at most the cap + one byte; a noisy probe cannot grow memory unbounded.
        stdout = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = timeout - (time.monotonic() - began)
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                for key, _ in selector.select(timeout=min(.1, remaining)):
                    chunk = os.read(key.fileobj.fileno(), min(65536, MAX_PROBE_OUTPUT_BYTES + 1 - len(stdout)))
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        stdout.extend(chunk)
                        if len(stdout) > MAX_PROBE_OUTPUT_BYTES:
                            raise ValueError('OutputLimitExceeded')
        remaining = timeout - (time.monotonic() - began)
        if remaining <= 0:
            raise subprocess.TimeoutExpired(command, timeout)
        child.wait(timeout=remaining)
        value.update(childExitCode=child.returncode, childReaped=True,
                     completionObservedMonotonic=time.monotonic())
        if child.returncode:
            value['errorType'] = 'CalledProcessError'
        else:
            value['data'] = parse_probe(name, stdout.decode('utf-8', errors='replace'), simulator)
    except Exception as error:
        value['errorType'] = 'OutputLimitExceeded' if isinstance(error, ValueError) and str(error) == 'OutputLimitExceeded' else type(error).__name__
        if child is not None:
            try:
                child.kill()
                child.wait(timeout=1)
                value.update(childExitCode=child.returncode, childReaped=True,
                             forcedStop=True, completionObservedMonotonic=time.monotonic())
            except Exception as cleanup_error:
                value['cleanupErrorType'] = type(cleanup_error).__name__
    finally:
        if child is not None and child.stdout is not None:
            child.stdout.close()
    value['elapsedSeconds'] = time.monotonic() - began
    return value


def worker(results, simulator, deadline):
    probes = [('neutral-process', [sys.executable, '-c', 'pass'])]
    if simulator:
        probes.append(('owned-simulator-state', ['xcrun', 'simctl', 'list', 'devices', simulator, '--json']))
    probes.extend([('memory-pages', ['/usr/bin/vm_stat']),
        ('service-processes', ['/bin/ps', '-A', '-ww', '-o', 'pid=,stat=,time=,comm=']),
        ('selected-xcresulttool', ['xcrun', '--find', 'xcresulttool']),
        ('disk-io', ['/usr/sbin/iostat', '-d', '-c', '1'])])
    value = {'diagnosisStartedMonotonic': time.monotonic(), 'deadlineMonotonic': deadline,
             'budgetSeconds': DIAGNOSTIC_BUDGET_SECONDS, 'resources': resources(), 'probes': [],
             'scope': 'CI-only, owned UUID and numeric allowlist; no raw system dump'}
    destination = results / 'failure-diagnostic-probes.json'
    if not safe_write(destination, value):
        return 2
    for name, command in probes:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            value['deadlineReached'] = True
            break
        value['probes'].append(run_probe(name, command, min(PROBE_BUDGET_SECONDS, remaining), simulator))
        safe_write(destination, value, exclusive=False)
    value['finishedMonotonic'] = time.monotonic()
    safe_write(destination, value, exclusive=False)
    return 0 if all(p.get('childReaped') or p.get('errorType') == 'FileNotFoundError' for p in value['probes']) else 1


def observe_first_failure(error, results, simulator, phase, run_phase=None, snapshot=None):
    """At most one extra diagnostic budget. All errors remain optional."""
    try:
        simulator = str(uuid.UUID(simulator)).upper() if simulator else None
        if snapshot is None:
            snapshot = recorded_failure(results, phase, error)
        value = {'errorType': type(error).__name__, 'phase': phase, 'simulator': simulator,
                 'firstFailure': snapshot or failure_snapshot(error, getattr(error, 'returncode', None)),
                 'callerReceivedMonotonic': time.monotonic(), 'selectedXcode': selected_xcode(results),
                 'diagnosticBudgetSeconds': DIAGNOSTIC_BUDGET_SECONDS,
                 'scope': 'First original failure; subsequent failures never overwrite this file'}
        if not safe_write(results / 'first-failure-observation.json', value):
            return
        status = {'success': False, 'ownedGroupCleanupResolved': None}
        if os.environ.get('GITHUB_ACTIONS') != 'true':
            status['skipped'] = 'External diagnostics restricted to hosted CI; no local device/service probing'
        else:
            if run_phase is None:
                from verify_offline_replay import run_owned_phase as run_phase
            deadline = time.monotonic() + DIAGNOSTIC_BUDGET_SECONDS
            command = [sys.executable, str(Path(__file__).resolve()), '--worker', str(results),
                       '--simulator', simulator or '-', '--deadline', str(deadline)]
            status['diagnosisRequestedMonotonic'] = time.monotonic()
            try:
                recorded = run_phase(command, results / 'failure-diagnostic-worker.log',
                    results / 'failure-diagnostic-worker.json', DIAGNOSTIC_BUDGET_SECONDS,
                    ensure_group_cleanup=True)
                status['success'] = bool(recorded and recorded.get('exitCode') == 0)
            except Exception as diagnostic_error:
                status['errorType'] = type(diagnostic_error).__name__
            status['diagnosisReturnedMonotonic'] = time.monotonic()
            try:
                recorded = json.loads((results / 'failure-diagnostic-worker.json').read_text())
                status['worker'] = {key: recorded.get(key) for key in (
                    'exitCode', 'timedOut', 'launched', 'launchRequestedElapsedSeconds',
                    'launchReturnedElapsedSeconds', 'elapsedSeconds', 'completionWaiterStopped',
                    'groupTermSent', 'groupKillSent', 'groupStillExistsAfterLeaderWait', 'groupExistsAfterCleanup')}
                final_group = recorded.get('groupExistsAfterCleanup')
                if type(final_group) is bool:
                    status['ownedGroupCleanupResolved'] = not final_group
                status['worker']['groupCleanupErrors'] = [{key: item.get(key) for key in ('operation', 'type', 'errno')}
                    for item in recorded.get('groupCleanupErrors', [])]
            except Exception:
                status['worker'] = None
            status['success'] = status['success'] and status['ownedGroupCleanupResolved'] is True
            status['cleanupScope'] = 'Inherited owned diagnostic process group only; signal attempts are not proof of group disappearance'
        safe_write(results / 'failure-diagnostic-status.json', status)
    except BaseException:
        pass  # Observation cannot mask the primary failure or skip its cleanup.


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--deadline', type=float, required=True)
    args = parser.parse_args()
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        raise SystemExit(2)
    try:
        device = str(uuid.UUID(args.simulator)).upper() if args.simulator != '-' else None
        raise SystemExit(worker(args.worker, device, args.deadline))
    except Exception:
        raise SystemExit(2)  # No raw probe output or private exception details.
