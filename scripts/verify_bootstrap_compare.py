"""One owned iOS27 bootstrap trial; diagnostic evidence, never UI acceptance."""
import argparse
import hashlib
import json
from pathlib import Path
import uuid

from verify_ios_lifecycle import output, record_toolchain
from verify_replay_seed import current_commit
from verify_offline_replay import (cleanup_simulator, create_result_directory,
                                   run_owned_phase, select_ui_destination)
from owned_simulator_boot_log import OwnedSimulatorBootLog


def run_trial(root, results, *, combined, se_viewport=False):
    """The only mutable device is the UUID returned by this trial's create call."""
    create_result_directory(results)
    value = {'schemaVersion': 1, 'mode': 'combined' if combined else 'separate',
        'sourceCommit': current_commit(root),
        'probeSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'bootstatusLimitSeconds': 180, 'separateBootLimitSeconds': 60,
        'uiTestsExecuted': 0, 'officialBootstatusPassed': False,
        'cleanupResolved': False,
        'scope': 'Fresh owned Simulator bootstrap only; no install, app launch, user data or readiness bypass',
        'comparisonBoundary': 'Both arms use -d and therefore exclude the production len5-only midpoint query. '
            'Different fresh hosted runners and host load remain confounders; this is not a production fix.'}
    simulator, boot_log, primary, secondary = None, None, None, None
    phase = 'setup'
    try:
        toolchain = record_toolchain(results)
        existing = json.loads(output(['xcrun', 'simctl', 'list', 'devices', '--json']))
        existing_ids = {str(uuid.UUID(row['udid'])).upper()
            for rows in existing['devices'].values() for row in rows}
        catalog = json.loads(output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))
        runtime, device = select_ui_destination(catalog, se_viewport)
        selected = next(row for row in catalog['runtimes'] if row['identifier'] == runtime)
        created = str(uuid.UUID(output(['xcrun', 'simctl', 'create',
            'BootstrapCompare-' + uuid.uuid4().hex, device, runtime]).strip())).upper()
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
        value['trialPassed'] = primary is None and secondary is None and simulator is not None
        try:
            (results / 'comparison.json').write_text(json.dumps(value, indent=2))
        except BaseException as error:
            if primary is None and secondary is None:
                secondary = error
    if primary is not None:
        raise primary
    if secondary is not None:
        raise secondary
    print('BOOTSTRAP COMPARISON PASS; diagnostic only, zero UI tests', flush=True)
    return value


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['separate', 'combined'], required=True)
    parser.add_argument('--result-directory', type=Path, required=True)
    parser.add_argument('--se-viewport', action='store_true')
    args = parser.parse_args()
    run_trial(Path(__file__).resolve().parents[1], args.result_directory.resolve(),
              combined=args.mode == 'combined', se_viewport=args.se_viewport)
