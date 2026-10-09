"""Optional first-failure evidence; never changes a verification result.

The CI worker reads allowlisted numeric/owned-UUID state only. It inherits its
supervisor's new process group; no existing device or service is controlled.
"""
import os
import sys
import time


def _worker_checkpoint(stage):
    """Best-effort CLI boundary; no imports, paths or probe output in its payload."""
    if (__name__ != '__main__' or os.environ.get('GITHUB_ACTIONS') != 'true'
            or stage not in ('python-entry', 'module-imports-complete', 'arguments-valid',
                             'journal-entry-write-started', 'journal-entry-written', 'journal-entry-write-failed')):
        return
    try:
        payload = ('{"stage":"' + stage + '","observedMonotonic":' + str(time.monotonic())
                   + ',"observedEpoch":' + str(time.time()) + '}\n').encode('ascii')
        os.write(1, payload)  # One small direct write; avoid Python stdout buffering.
    except Exception:
        pass  # Checkpoint failure cannot change the original result or cleanup.


_worker_checkpoint('python-entry')

import argparse
import datetime
import json
import math
from pathlib import Path
import re
import selectors
import subprocess
import uuid

_worker_checkpoint('module-imports-complete')

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


def failure_snapshot(error, child_exit_code=None, source='caller', observed_monotonic=None,
                     sample_resources=True):
    """Observation time, never an inferred kernel exit timestamp."""
    value = {'observedMonotonic': time.monotonic() if observed_monotonic is None else observed_monotonic,
        'observedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'errorType': type(error).__name__, 'source': source,
        'childExitCodeBeforeStop': child_exit_code, 'kernelExitTimestamp': None}
    if not sample_resources:
        value.update(resources=None, resourcesSampleMonotonic=None,
                     contextDeferredReason='Owned cleanup takes priority after Timeout')
        return value
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


def captured_output_metadata(output, stderr=None):
    """Lengths only: raw bytes or UTF-8 size of <=64Ki characters; otherwise unknown."""
    def byte_length(value):
        if isinstance(value, bytes):
            return len(value)
        if isinstance(value, str):
            if len(value) > 65536:
                return None  # Optional text counting must have bounded work.
            try:
                # Bound temporary encoding memory; never persist any output body.
                return sum(len(value[i:i + 4096].encode('utf-8')) for i in range(0, len(value), 4096))
            except UnicodeEncodeError:
                return None
        return None
    return {'outputPresent': output is not None, 'outputBytes': byte_length(output),
            'stderrPresent': stderr is not None, 'stderrBytes': byte_length(stderr)}


def observe_call(operation, results, phase, timeout, record_output_metadata=False):
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
            if record_output_metadata:
                value['outputMetadata'] = captured_output_metadata(result)
        except Exception:
            pass
        return result
    except BaseException as error:
        try:
            value['errorType'] = type(error).__name__
            value['childExitCode'] = getattr(error, 'returncode', None)
            value['firstFailure'] = failure_snapshot(error, value['childExitCode'], 'subprocess-call-return')
            if record_output_metadata:
                value['outputMetadata'] = captured_output_metadata(getattr(error, 'output', None),
                                                                  getattr(error, 'stderr', None))
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


def simctl_device(command):
    """Only the two call boundaries belonging to the runner's created UUID."""
    if (len(command) >= 4 and command[:2] == ['xcrun', 'simctl']
            and command[2] in ('bootstatus', 'get_app_container')):
        try:
            return str(uuid.UUID(command[3])).upper()
        except (ValueError, TypeError):
            pass
    return None


def owned_boundary(pid, simulator):
    """CI-only native PID path; no subprocess, filesystem read or app data."""
    value = {'pid': pid, 'simulator': simulator, 'observedMonotonic': time.monotonic(),
             'observedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'kernelExecTimestamp': None,
             'scope': 'Leader executable sample, not service health or kernel exec time'}
    if os.environ.get('GITHUB_ACTIONS') != 'true' or sys.platform != 'darwin':
        value['skipped'] = 'Native owned boundary restricted to macOS hosted CI'
        return value
    try:
        import ctypes
        library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        function = library.proc_pidpath
        function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        function.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(4096)
        length = function(pid, buffer, len(buffer))
        path = buffer.value.decode('utf-8', errors='replace') if length > 0 else None
        allowed = path in ('/usr/bin/xcrun', '/bin/bash', '/bin/sh') or bool(path and (
            re.fullmatch(r'/Applications/[A-Za-z0-9_.-]+\.app/Contents/Developer/usr/bin/simctl', path)
            or re.fullmatch(r'/Library/Developer/PrivateFrameworks/CoreSimulator\.framework/(?:Versions/[A-Za-z0-9_.-]+/)?Resources/bin/simctl', path)))
        value['executable'] = path if allowed else None
        value['executableObserved'] = bool(allowed)
        if length <= 0:
            value['pidPathErrno'] = ctypes.get_errno()
    except Exception as error:
        value['pidPathErrorType'] = type(error).__name__
    value['returnedMonotonic'] = time.monotonic()
    return value


def optional_boundary(pid, simulator):
    try:
        return owned_boundary(pid, simulator)
    except Exception as error:
        return {'errorType': type(error).__name__}


def child_boundary(child, simulator):
    """Never query a reaped/reusable PID; skip a busy completion-wait lock.

    The POSIX Popen reap lock prevents concurrent waitpid/PID reuse during the
    native sample. If that implementation lock is absent or busy, stay unknown.
    """
    value = {'pid': child.pid, 'simulator': simulator,
             'observedMonotonic': time.monotonic(), 'kernelExecTimestamp': None}
    try:
        lock = getattr(child, '_waitpid_lock', None)
        if lock is None or not lock.acquire(blocking=False):
            value['skipped'] = 'Reap lock unavailable or busy; executable unknown'
            return value
        try:
            if child.returncode is not None:
                value['skipped'] = 'Leader exit known; reusable PID not resampled'
                return value
            return optional_boundary(child.pid, simulator)
        finally:
            lock.release()
    except Exception as error:
        value['errorType'] = type(error).__name__
        return value



def simctl_output(command, results, phase, timeout=60):
    """check_output semantics, with this call's pre-kill metadata only.

    Popen time remains outside communicate's original timeout, like check_output.
    Return stdout unchanged; never publish stdout/container paths in the receipt.
    """
    simulator = simctl_device(command)
    if simulator is None or command[2:] != ['get_app_container', simulator, 'local.webdashboard.Telemetry', 'data']:
        raise ValueError('Expected owned Telemetry data-container call')
    began = time.monotonic()
    value = {'simulator': simulator, 'operation': 'get_app_container',
             'bundleID': 'local.webdashboard.Telemetry', 'containerType': 'data',
             'callStartedMonotonic': began, 'timeoutSeconds': timeout,
             'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'kernelExitTimestamp': None, 'childExitCode': None,
             'scope': 'Dedicated subprocess call; timestamps are observations, no kernel exit/exec inference'}
    child = None
    def note(error, source):
        try:
            value['firstFailure'] = failure_snapshot(error, child.returncode, source)
            value['firstFailure']['ownedBoundary'] = child_boundary(child, simulator)
        except Exception:
            pass  # Original exception and cleanup always take priority.
    try:
        value['launchRequestedMonotonic'] = time.monotonic()
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as child:
            value.update(pid=child.pid, launchReturnedMonotonic=time.monotonic())
            value['communicateStartedMonotonic'] = time.monotonic()
            try:
                stdout, _ = child.communicate(timeout=timeout)
                value['communicateReturnedMonotonic'] = time.monotonic()
            except subprocess.TimeoutExpired as error:
                value['communicateReturnedMonotonic'] = time.monotonic()
                note(error, 'communicate-before-kill')
                value['killRequestedMonotonic'] = time.monotonic()
                child.kill()
                # Match stdlib POSIX check_output: retain TimeoutExpired.output bytes.
                child.wait()
                raise
            except BaseException:
                child.kill()
                raise
            code = child.poll()
            value['childExitCode'] = code
            if code:
                error = subprocess.CalledProcessError(code, command, output=stdout)
                note(error, 'communicate-return')
                raise error
            value['returnedNormally'] = True
            return stdout
    except BaseException as error:
        value['errorType'] = type(error).__name__
        raise
    finally:
        if child is not None:
            value['childExitCode'] = child.returncode
        value.update(callReturnedMonotonic=time.monotonic(),
                     finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
        safe_write(results / (phase + '-observation.json'), value, exclusive=False)


def simctl_identity(results):
    """Fixed system files only; this runs inside the existing diagnostic worker budget."""
    import hashlib
    import plistlib
    framework = Path('/Library/Developer/PrivateFrameworks/CoreSimulator.framework')
    paths = [('framework', framework / 'Versions/A/Resources/bin/simctl')]
    developer = selected_xcode(results).get('effectiveDeveloperDirectory')
    if developer:
        paths.append(('launcher', Path(developer) / 'usr/bin/simctl'))
    value = {'scope': 'Post-failure file identity, not proof of the executed launcher branch', 'files': []}
    for name, path in paths:
        entry = {'name': name, 'path': str(path)}
        try:
            with path.open('rb') as stream:
                raw = stream.read(4 * 1024 * 1024 + 1)
            if len(raw) > 4 * 1024 * 1024:
                raise ValueError('SystemFileLimit')
            entry.update(sizeBytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(),
                         magicHex=raw[:4].hex(), shellLauncher=raw.startswith(b'#!'))
        except Exception as error:
            entry['errorType'] = type(error).__name__
        value['files'].append(entry)
    try:
        with (framework / 'Resources/Info.plist').open('rb') as stream:
            raw = stream.read(65537)
        if len(raw) > 65536:
            raise ValueError('SystemMetadataLimit')
        version = plistlib.loads(raw).get('CFBundleVersion')
        value['frameworkVersion'] = version if isinstance(version, str) and re.fullmatch(r'[0-9.]+', version) else None
    except Exception as error:
        value['frameworkVersionErrorType'] = type(error).__name__
    return value


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
    if name == 'owned-app-registration':
        import plistlib
        apps = plistlib.loads(raw.encode('utf-8'))
        if not isinstance(apps, dict):
            raise ValueError('MalformedAppRegistry')
        return {'simulator': simulator, 'bundleID': 'local.webdashboard.Telemetry',
                'registered': 'local.webdashboard.Telemetry' in apps,
                'scope': 'Post-failure listapps response only; not container readiness at original deadline'}
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
        if timeout <= 0:
            value['notRunReason'] = 'deadlineReached'
            raise subprocess.TimeoutExpired(command, timeout)
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



def replace_worker_journal(path, value):
    """Publish a complete worker snapshot without truncating the previous one."""
    temporary = None
    try:
        temporary = path.with_name(f'.{path.name}.{uuid.uuid4().hex}.tmp')
        with temporary.open('x', encoding='utf-8') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
        temporary.replace(path)
        return True
    except Exception:
        return False
    finally:
        if temporary is not None:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass


def worker(results, simulator, deadline):
    probes = [('neutral-process', [sys.executable, '-c', 'pass'])]
    if simulator:
        probes.append(('owned-simulator-state', ['xcrun', 'simctl', 'list', 'devices', simulator, '--json']))
        probes.append(('owned-app-registration', ['xcrun', 'simctl', 'listapps', simulator]))
    probes.extend([('memory-pages', ['/usr/bin/vm_stat']),
        ('service-processes', ['/bin/ps', '-A', '-ww', '-o', 'pid=,stat=,time=,comm=']),
        ('selected-xcresulttool', ['xcrun', '--find', 'xcresulttool']),
        ('disk-io', ['/usr/sbin/iostat', '-d', '-c', '1'])])
    value = {'diagnosisStartedMonotonic': time.monotonic(), 'deadlineMonotonic': deadline,
             'budgetSeconds': DIAGNOSTIC_BUDGET_SECONDS, 'resources': None, 'probes': [], 'stages': [],
             'scope': 'CI-only, owned UUID and numeric allowlist; no raw system dump'}
    destination = results / 'failure-diagnostic-probes.json'
    # Persist worker entry before optional imports, system file reads or subprocess observations.
    _worker_checkpoint('journal-entry-write-started')
    if not safe_write(destination, value):
        _worker_checkpoint('journal-entry-write-failed')
        return 2
    _worker_checkpoint('journal-entry-written')

    class JournalWriteError(Exception):
        pass

    def publish():
        if not replace_worker_journal(destination, value):
            raise JournalWriteError('Optional diagnostic journal could not be published')

    def observe_stage(name, operation):
        stage = {'name': name, 'startedMonotonic': time.monotonic()}
        value['stages'].append(stage)
        publish()
        try:
            if time.monotonic() >= deadline:
                value['deadlineReached'] = True
                stage['notRunReason'] = 'deadlineReached'
                return None
            return operation()
        except Exception as error:
            stage['errorType'] = type(error).__name__
            raise
        finally:
            stage['finishedMonotonic'] = time.monotonic()
            publish()

    try:
        if time.monotonic() < deadline:
            value['resources'] = observe_stage('resources', resources)
        if time.monotonic() < deadline:
            try:
                value['simctlIdentity'] = observe_stage('simctl-identity', lambda: simctl_identity(results))
            except JournalWriteError:
                raise
            except Exception as error:
                value['simctlIdentityErrorType'] = type(error).__name__
        for name, command in probes:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                value['deadlineReached'] = True
                break
            probe = observe_stage(name,
                lambda: run_probe(name, command, min(PROBE_BUDGET_SECONDS, deadline - time.monotonic()), simulator))
            if probe is None:
                break
            value['probes'].append(probe)
            publish()
        value['finishedMonotonic'] = time.monotonic()
        publish()
        return 0 if all(p.get('childReaped') or p.get('errorType') == 'FileNotFoundError' for p in value['probes']) else 1
    except JournalWriteError:
        return 2


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
        _worker_checkpoint('arguments-valid')
        raise SystemExit(worker(args.worker, device, args.deadline))
    except Exception:
        raise SystemExit(2)  # No raw probe output or private exception details.
