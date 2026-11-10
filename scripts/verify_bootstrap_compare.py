"""One owned iOS27 bootstrap trial; diagnostic evidence, never UI acceptance."""
import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path
import uuid

import failure_observation
from verify_ios_lifecycle import output, record_toolchain, BOOTSTATUS_TIMEOUT_SECONDS
from verify_replay_seed import current_commit
from verify_offline_replay import (cleanup_simulator, create_result_directory,
                                   run_owned_phase, select_ui_destination, prepare_simulator)
from owned_simulator_boot_log import OwnedSimulatorBootLog


def read_object(path):
    with path.open('rb') as stream:
        raw = stream.read(failure_observation.MAX_PROBE_OUTPUT_BYTES + 1)
    if len(raw) > failure_observation.MAX_PROBE_OUTPUT_BYTES:
        raise ValueError('Diagnostic receipt exceeds its output limit')
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError('Diagnostic receipt must be an object')
    return value


def control_outcome(journal):
    probes = journal.get('probes', [])
    if not isinstance(probes, list):
        raise ValueError('Diagnostic probes must be a list')
    controls = [p for p in probes if isinstance(p, dict) and p.get('name') == 'neutral-process']
    observed = len(controls) == 1
    succeeded = bool(observed and controls[0].get('childReaped') is True
        and type(controls[0].get('childExitCode')) is int and controls[0]['childExitCode'] == 0
        and not controls[0].get('errorType') and not controls[0].get('cleanupErrorType'))
    return observed, succeeded


def run_neutral_baseline(results):
    """Admit the trial only after a real control and its entire worker stop."""
    budget = failure_observation.DIAGNOSTIC_BUDGET_SECONDS
    deadline = time.monotonic() + budget
    command = [sys.executable, '-B', str(Path(failure_observation.__file__).resolve()),
        '--worker', str(results), '--simulator', '-', '--deadline', str(deadline), '--neutral-baseline']
    process_receipt = results / 'baseline-worker.json'
    value = {'admitted': False, 'controlObserved': False, 'controlSucceeded': False,
        'workerSucceeded': False, 'workerCleanupResolved': False,
        'scope': 'Preflight control only; no Simulator or boot readiness claim',
        'deadlineMonotonic': deadline, 'budgetSeconds': budget}
    primary, recorded = None, {}
    try:
        recorded = run_owned_phase(command, results / 'baseline-worker.log', process_receipt,
            budget, ensure_group_cleanup=True)
    except BaseException as error:
        primary = error
        value['workerErrorType'] = type(error).__name__
        try:
            recorded = read_object(process_receipt)
        except Exception as receipt_error:
            value['processReceiptErrorType'] = type(receipt_error).__name__
    if not isinstance(recorded, dict):
        recorded = {}
    value['workerSucceeded'] = bool(recorded.get('launched') is True
        and type(recorded.get('exitCode')) is int and recorded['exitCode'] == 0
        and recorded.get('timedOut') is False)
    value['workerCleanupResolved'] = recorded.get('groupExistsAfterCleanup') is False
    value['completionWaiterStopped'] = recorded.get('completionWaiterStopped') is True
    if value['workerCleanupResolved'] and value['completionWaiterStopped']:
        try:
            journal = read_object(results / 'neutral-process-baseline.json')
            value['controlObserved'], value['controlSucceeded'] = control_outcome(journal)
            value['admitted'] = bool(primary is None and value['workerSucceeded']
                and value['controlObserved'] and value['controlSucceeded']
                and journal.get('controlSucceeded') is True and len(journal.get('probes', [])) == 1)
        except Exception as journal_error:
            value['journalErrorType'] = type(journal_error).__name__
    else:
        value['notObservedReason'] = 'Worker or completion waiter cleanup unconfirmed'
    try:
        (results / 'baseline-admission.json').write_text(json.dumps(value, indent=2))
    except BaseException:
        if primary is None:
            raise
    if primary is not None:
        raise primary
    if not value['admitted']:
        raise RuntimeError('Neutral baseline not admitted; no Simulator operation allowed')
    return value


def diagnostic_coverage(results):
    """Worker completion is separate from having observed a neutral control."""
    value = {'workerSucceeded': False, 'workerCleanupResolved': False,
        'controlObserved': False, 'controlSucceeded': False}
    try:
        status = read_object(results / 'failure-diagnostic-status.json')
        value['workerSucceeded'] = status.get('success') is True
        value['workerCleanupResolved'] = status.get('ownedGroupCleanupResolved') is True
        worker = status.get('worker')
        if not value['workerCleanupResolved'] or not isinstance(worker, dict) or worker.get('completionWaiterStopped') is not True:
            value['notObservedReason'] = 'Worker cleanup or completion waiter unconfirmed'
        else:
            journal = read_object(results / 'failure-diagnostic-probes.json')
            value['controlObserved'], value['controlSucceeded'] = control_outcome(journal)
            if not value['controlObserved']:
                value['notObservedReason'] = 'Neutral control not observed'
    except Exception as error:
        value['unavailableErrorType'] = type(error).__name__
    return value


def publish_boot_receipt(results, value):
    """Publish a verdict only after its staged file has been written and closed."""
    pending = results / ('.boot-only-pending-' + uuid.uuid4().hex + '.json')
    try:
        pending.write_text(json.dumps(value, indent=2), encoding='utf-8')
        pending.replace(results / 'boot-only.json')
    finally:
        try:
            pending.unlink(missing_ok=True)
        except OSError:
            pass  # A staging cleanup error cannot replace the original publication result.


def run_trial(root, results, *, combined, se_viewport=False, production=False):
    """The only mutable device is the UUID returned by this trial's create call."""
    if production:
        if combined:
            raise ValueError('Production protocol cannot use the combined verbose comparison')
        if os.environ.get('GITHUB_ACTIONS') != 'true' or sys.platform != 'darwin' or os.name != 'posix':
            raise ValueError('Production boot-only trial is restricted to hosted macOS CI')
        if results.exists() or results.is_symlink():
            raise FileExistsError('Production trial requires a new result directory')
    create_result_directory(results)
    value = {'schemaVersion': 1, 'mode': 'production' if production else ('combined' if combined else 'separate'),
        'sourceCommit': current_commit(root),
        'probeSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'bootstatusLimitSeconds': 180, 'separateBootLimitSeconds': 60,
        'uiTestsExecuted': 0, 'officialBootstatusPassed': False,
        'cleanupResolved': False,
        'scope': 'Fresh owned Simulator bootstrap only; no install, app launch, user data or readiness bypass',
        'comparisonBoundary': 'Both arms use -d and therefore exclude the production len5-only midpoint query. '
            'Different fresh hosted runners and host load remain confounders; this is not a production fix.'}
    if production:
        value.update(baselineAdmitted=False, baselineAdmission='baseline-admission.json',
            bootstatusLimitSeconds=BOOTSTATUS_TIMEOUT_SECONDS,
            scope='Fresh owned Simulator, original production bootstrap only; no build/install/app/UI',
            comparisonBoundary=f'Production boot60 then len5 bootstatus -b{BOOTSTATUS_TIMEOUT_SECONDS}. Local variants are not equivalent. '
                'This diagnostic does not establish a root cause or authorize its execution.')
    simulator, boot_log, primary, secondary = None, None, None, None
    phase = 'setup'
    try:
        if production:
            phase = 'neutral-baseline'
            run_neutral_baseline(results)
            value['baselineAdmitted'] = True
            phase = 'setup'
        toolchain = record_toolchain(results)
        existing = json.loads(output(['xcrun', 'simctl', 'list', 'devices', '--json']))
        existing_ids = {str(uuid.UUID(row['udid'])).upper()
            for rows in existing['devices'].values() for row in rows}
        catalog = json.loads(output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))
        runtime, device = select_ui_destination(catalog, se_viewport)
        selected = next(row for row in catalog['runtimes'] if row['identifier'] == runtime)
        if production:
            phase = 'simulator-create'
        created = str(uuid.UUID(output(['xcrun', 'simctl', 'create',
            ('BootstrapProduction-' if production else 'BootstrapCompare-') + uuid.uuid4().hex,
            device, runtime]).strip())).upper()
        if created in existing_ids:
            raise ValueError('Create returned an existing UUID; ownership not established')
        simulator = created
        environment = {**toolchain, 'simulator': simulator, 'runtime': runtime,
            'runtime_version': selected['version'], 'runtime_build': selected.get('buildversion'),
            'device_type': device, 'existingUUIDCount': len(existing_ids),
            'createdUUIDWasAbsent': True}
        value['environment'] = environment
        (results / 'environment.json').write_text(json.dumps(environment, indent=2))
        print(json.dumps(environment), flush=True)
        boot_log = OwnedSimulatorBootLog(simulator, results)
        boot_log.mark_boot_started()
        if production:
            phase = 'bootstrap'
            prepare_simulator(simulator, results, boot_log=boot_log)
            value['officialBootstatusPassed'] = True
        else:
            phases = [('bootstatus', 180)] if combined else [('boot', 60), ('bootstatus', 180)]
            try:
                for phase, timeout in phases:
                    command = ['xcrun', 'simctl', phase, simulator]
                    if phase == 'bootstatus':
                        command += ['-b', '-d']
                    run_owned_phase(command, results / ('simulator-' + phase + '.log'),
                        results / ('simulator-' + phase + '.json'), timeout)
                value['officialBootstatusPassed'] = True
            finally:
                try:
                    boot_log.request_stop()
                except Exception as error:
                    value['collectorStopErrorType'] = type(error).__name__
    except BaseException as error:
        primary = error
        value['primaryErrorType'] = type(error).__name__
        value['failedPhase'] = phase
    finally:
        if simulator is not None:
            try:
                value['cleanupResolved'] = cleanup_simulator(simulator, results)
                if not value['cleanupResolved']:
                    secondary = RuntimeError('Owned comparison Simulator cleanup unresolved')
            except BaseException as error:
                secondary = error
                value['cleanupErrorType'] = type(error).__name__
        if boot_log is not None:
            try:
                value['collectorCleaned'] = boot_log.finalize()['collectorCleaned']
                if not value['collectorCleaned'] and secondary is None:
                    secondary = RuntimeError('Owned comparison event collector cleanup unresolved')
            except BaseException as error:
                value['collectorCleaned'] = False
                value['collectorErrorType'] = type(error).__name__
                if secondary is None:
                    secondary = error
        if production:
            value['diagnosticCoverage'] = diagnostic_coverage(results)
            if primary is None and secondary is None and (results / 'first-failure-observation.json').exists():
                secondary = RuntimeError('Retained first failure prevents boot-only acceptance')
        value['trialPassed'] = primary is None and secondary is None and simulator is not None
        try:
            if production:
                publish_boot_receipt(results, value)
            else:
                (results / 'comparison.json').write_text(json.dumps(value, indent=2))
        except BaseException as error:
            if primary is None and secondary is None:
                secondary = error
    if primary is not None:
        raise primary
    if secondary is not None:
        raise secondary
    print('BOOTSTRAP ' + ('PRODUCTION' if production else 'COMPARISON') + ' PASS; diagnostic only, zero UI tests', flush=True)
    return value


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['separate', 'combined', 'production'], required=True)
    parser.add_argument('--result-directory', type=Path, required=True)
    parser.add_argument('--se-viewport', action='store_true')
    args = parser.parse_args()
    # Keep a production symlink visible to run_trial's preflight guard.
    results = args.result_directory.absolute()
    if args.mode != 'production':
        results = results.resolve()
    run_trial(Path(__file__).resolve().parents[1], results,
              combined=args.mode == 'combined', se_viewport=args.se_viewport, production=args.mode == 'production')
