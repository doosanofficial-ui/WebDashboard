#!/usr/bin/env python3
"""Build and qualify one exact-input host Seed before any Simulator is booted."""
import argparse
from contextlib import closing
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import sqlite3
import struct
import subprocess
import tempfile
import time

SEED_BUDGET_SECONDS = 240
EXPECTED_FIXTURE = {
    'sessions': {
        name: {'rows': count, 'mode': 'DEMO', 'closed': True}
        for name, count in [('offline-replay-fixture', 3), ('offline-seek-fixture', 8),
                            ('offline-slider-fixture', 7), ('offline-instant-fixture', 3),
                            ('offline-empty-fixture', 0), ('offline-route-fixture', 5)]
    },
    'dashboard': {'id': 'offline-fixture', 'pageID': 'fixture', 'widgetCount': 7},
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_inputs(root):
    core = root / 'mobile-ios/TelemetryCore'
    paths = [core / 'Package.swift', root / 'scripts/tests/offline_replay_seed.swift',
             root / 'scripts/verify_replay_seed.py']
    paths.extend(path for path in (core / 'Sources').rglob('*') if path.is_file())
    return {str(path.relative_to(root)): digest(path) for path in sorted(paths)}


def current_commit(root):
    value = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    if not re.fullmatch(r'[0-9a-f]{40}', value):
        raise ValueError('Seed requires an exact Git commit')
    return value


def binary_architecture(path):
    header = path.read_bytes()[:32]
    if len(header) != 32 or struct.unpack('<I', header[:4])[0] != 0xfeedfacf:
        raise ValueError('Seed must be a thin 64-bit Mach-O executable')
    cpu = struct.unpack('<I', header[4:8])[0]
    if struct.unpack('<I', header[12:16])[0] != 2:
        raise ValueError('Seed Mach-O must be an executable')
    architectures = {0x100000c: 'arm64', 0x1000007: 'x86_64'}
    if cpu not in architectures:
        raise ValueError('Unknown Seed executable architecture')
    return architectures[cpu]


def valid_elapsed(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def validate_artifact(root, artifact, toolchain, architecture, commit, expected_manifest_sha256):
    """No rebuild fallback: reject missing, changed or unqualified input before boot."""
    try:
        binary = artifact / 'Seed'
        manifest_file = artifact / 'manifest.json'
        if binary.is_symlink() or manifest_file.is_symlink():
            raise ValueError('Seed artifact files cannot be symbolic links')
        if (not isinstance(expected_manifest_sha256, str)
                or not re.fullmatch(r'[0-9a-f]{64}', expected_manifest_sha256)):
            raise ValueError('Missing or malformed trusted producer manifest digest')
        manifest_bytes = manifest_file.read_bytes()
        if hashlib.sha256(manifest_bytes).hexdigest() != expected_manifest_sha256:
            raise ValueError('Seed manifest differs from the trusted producer job output')
        manifest = json.loads(manifest_bytes)
        if type(manifest['schemaVersion']) is not int or manifest['schemaVersion'] != 1:
            raise ValueError('Unsupported Seed artifact version')
        if manifest['commit'] != commit or not re.fullmatch(r'[0-9a-f]{40}', commit):
            raise ValueError('Seed artifact commit mismatch')
        if manifest['sourceInputs'] != source_inputs(root):
            raise ValueError('Seed artifact source hashes mismatch')
        if manifest['toolchain'] != toolchain:
            raise ValueError('Seed artifact Xcode/SDK version mismatch')
        if manifest['architecture'] != architecture or binary_architecture(binary) != architecture:
            raise ValueError('Seed artifact architecture mismatch')
        if manifest['binarySHA256'] != digest(binary):
            raise ValueError('Seed artifact binary hash mismatch')
        if type(manifest['budgetSeconds']) is not int or manifest['budgetSeconds'] != SEED_BUDGET_SECONDS:
            raise ValueError('Seed artifact budget must remain 240 seconds')
        for key in ['buildReceipt', 'qualificationReceipt']:
            phase = manifest[key]
            if (type(phase['exitCode']) is not int or phase['exitCode'] != 0
                    or phase['timedOut'] is not False or not valid_elapsed(phase['elapsedSeconds'])):
                raise ValueError('Seed artifact build or qualification failed')
        elapsed = manifest['producerElapsedSeconds']
        phase_sum = sum(manifest[key]['elapsedSeconds'] for key in ['buildReceipt', 'qualificationReceipt'])
        if not valid_elapsed(elapsed) or elapsed < phase_sum or elapsed >= SEED_BUDGET_SECONDS:
            raise ValueError('Seed artifact compile/qualification budget exhausted or invalid')
        if manifest['fixture'] != EXPECTED_FIXTURE:
            raise ValueError('Seed artifact fixture qualification mismatch')
        return {'binary': binary, 'binarySHA256': manifest['binarySHA256'],
                'remainingSeconds': SEED_BUDGET_SECONDS - elapsed, 'manifest': manifest,
                'trustedManifestSHA256': expected_manifest_sha256}
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise ValueError('Missing or malformed Seed artifact: ' + str(error)) from error



def private_artifact(root, downloaded, private, toolchain, architecture, commit, expected_manifest_sha256):
    """Copy into an owned private directory, then validate the copied bytes."""
    private.mkdir(mode=0o700, parents=False, exist_ok=False)
    for name in ['Seed', 'manifest.json']:
        source = downloaded/name
        if source.is_symlink() or not source.is_file():
            raise ValueError('Missing or nonregular downloaded Seed artifact file: ' + name)
        shutil.copyfile(source, private/name)
        if os.name == 'posix':
            (private/name).chmod(0o500 if name == 'Seed' else 0o400)
    return validate_artifact(root, private, toolchain, architecture, commit, expected_manifest_sha256)


def publish_digest(trusted_digest, output_file):
    if not re.fullmatch(r'[0-9a-f]{64}', trusted_digest):
        raise ValueError('Invalid trusted Seed manifest digest')
    with output_file.open('a', encoding='utf-8') as stream:
        stream.write('manifest_sha256='+trusted_digest+'\n')


def verify_fixture(directory):
    database = directory / 'measurements.sqlite3'
    with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)) as connection:
        rows = connection.execute('''SELECT s.session_id, count(m.sequence), s.mode, s.ended_at
            FROM measurement_sessions s LEFT JOIN measurements m ON m.session_id=s.session_id
            GROUP BY s.session_id ORDER BY s.session_id''').fetchall()
    profile = json.loads((directory / 'dashboard.json').read_text())
    value = {'sessions': {name: {'rows': count, 'mode': mode, 'closed': ended is not None}
                          for name, count, mode, ended in rows},
             'dashboard': {'id': profile['id'], 'pageID': profile['pages'][0]['id'],
                           'widgetCount': len(profile['pages'][0]['widgets'])}}
    if value != EXPECTED_FIXTURE:
        raise ValueError('Seed execution produced an unexpected synthetic fixture: ' + json.dumps(value))
    return value



def install_fixture(source, destination):
    """Copy only completed fixture data; never execute the artifact after boot."""
    destination.mkdir(parents=True, exist_ok=False)
    with closing(sqlite3.connect((source/'measurements.sqlite3').as_uri()+'?mode=ro', uri=True)) as original:
        with closing(sqlite3.connect(destination/'measurements.sqlite3')) as copied:
            original.backup(copied)
            # Finalize only the new copy without a dependency on source WAL sidecars.
            # The app's recorder selects WAL itself when it later opens this database.
            copied.execute('PRAGMA journal_mode=DELETE')
    shutil.copyfile(source/'dashboard.json', destination/'dashboard.json')
    return verify_fixture(destination)


def run_artifact(validated, destination, results):
    from verify_offline_replay import run_seed_phase
    results.mkdir(parents=True, exist_ok=True)
    binary = validated['binary']
    if digest(binary) != validated['binarySHA256']:
        raise ValueError('Seed executable changed after admission; no rebuild fallback')
    binary.chmod(binary.stat().st_mode | 0o100)
    admission = {'mode': 'prebuilt-executable', 'binarySHA256': validated['binarySHA256'],
                 'remainingSeconds': validated['remainingSeconds'], 'manifest': validated.get('manifest'),
                 'trustedManifestSHA256': validated.get('trustedManifestSHA256')}
    (results / 'seed-consumer.json').write_text(json.dumps(admission, indent=2) + '\n')
    run_seed_phase([str(binary), str(destination)], results / 'seed.log', results / 'seed-run.json',
                   validated['remainingSeconds'])
    fixture = verify_fixture(destination)
    (results / 'seed-fixture.json').write_text(json.dumps(fixture, indent=2) + '\n')



def resource_snapshot():
    value = {'cpuCount': os.cpu_count(), 'architecture': platform.machine(),
             'operatingSystem': platform.platform(), 'runnerImage': os.environ.get('ImageOS'),
             'runnerImageVersion': os.environ.get('ImageVersion')}
    if hasattr(os, 'getloadavg'):
        value['loadAverage'] = list(os.getloadavg())
    if platform.system() == 'Darwin':
        try:
            value['memoryBytes'] = int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True, timeout=2))
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            value['memoryObservationError'] = str(error)
    return value


def owned_progress(process_group, log, began):
    value = {'ownedProcessGroup': process_group, 'elapsedSeconds': time.monotonic()-began,
             'logBytes': log.stat().st_size, 'logModifiedEpoch': log.stat().st_mtime}
    try:
        # Only this newly-created group; no command arguments or global process dump.
        found = subprocess.run(['pgrep', '-g', str(process_group), '.'], capture_output=True, text=True, timeout=2)
        pids = [pid for pid in found.stdout.split() if pid.isdigit()]
        if pids:
            observed = subprocess.run(['ps', '-p', ','.join(pids), '-o',
                                      'pid=,ppid=,pgid=,state=,%cpu=,time=,etime=,comm='],
                                     capture_output=True, text=True, timeout=2)
            value['ownedProcesses'] = [line for line in observed.stdout.splitlines()
                                      if len(line.split()) >= 3 and line.split()[2] == str(process_group)]
            value['processColumns'] = ['pid', 'ppid', 'pgid', 'state', 'cpuPercent', 'cpuTime', 'elapsed', 'commandName']
        else:
            value['ownedProcesses'] = []
    except (OSError, subprocess.SubprocessError) as error:
        value['processObservationError'] = str(error)
    return value


def build_artifact(root, results):
    from verify_ios_lifecycle import record_toolchain
    from verify_offline_replay import run_seed_phase
    results.mkdir(parents=True, exist_ok=False)
    before = source_inputs(root)
    commit = current_commit(root)
    toolchain = record_toolchain(results)
    (results / 'swift-version.txt').write_text(subprocess.check_output(['swift', '--version'], text=True))
    with tempfile.TemporaryDirectory(prefix='telemetry-seed-build-') as directory:
        workspace = Path(directory)
        core = workspace / 'source/TelemetryCore'
        # Byte copies exclude Finder/resource-fork attributes and existing build caches.
        shutil.copytree(root / 'mobile-ios/TelemetryCore', core, copy_function=shutil.copyfile,
                        ignore=shutil.ignore_patterns('.build', '.swiftpm', '.DS_Store'))
        seed = workspace / 'Seed'
        (seed / 'Sources/Seed').mkdir(parents=True)
        (seed / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Seed", platforms: [.macOS(.v13)],
 dependencies: [.package(path: "../source/TelemetryCore")],
 targets: [.executableTarget(name: "Seed", dependencies: [.product(name: "TelemetryCore", package: "TelemetryCore")])])
''')
        shutil.copyfile(root / 'scripts/tests/offline_replay_seed.swift', seed / 'Sources/Seed/main.swift')
        started = time.monotonic()
        deadline = started + SEED_BUDGET_SECONDS
        run_seed_phase(['swift', 'build', '--package-path', str(seed), '-v'],
                       results / 'seed-build.log', results / 'seed-build.json', deadline - time.monotonic())
        run_seed_phase(['swift', 'build', '--package-path', str(seed), '--show-bin-path'],
                       results / 'binary-location.log', results / 'binary-location.json', deadline - time.monotonic())
        built = Path((results / 'binary-location.log').read_text().strip()) / 'Seed'
        if not built.resolve().is_relative_to(seed.resolve()):
            raise ValueError('Seed binary must come from the owned build directory')
        binary = results / 'Seed'
        shutil.copyfile(built, binary)
        binary.chmod(0o755)
        architecture = platform.machine()
        if binary_architecture(binary) != architecture:
            raise ValueError('Built Seed architecture mismatch')
        fixture_directory = workspace / 'qualification'
        fixture_directory.mkdir()
        run_seed_phase([str(binary.resolve()), str(fixture_directory)],
                       results / 'qualification.log', results / 'qualification.json', deadline - time.monotonic())
        fixture = verify_fixture(fixture_directory)
        elapsed = time.monotonic() - started
        if elapsed >= SEED_BUDGET_SECONDS:
            raise ValueError('Seed build/qualification exceeded the unchanged 240-second budget')
        if before != source_inputs(root) or commit != current_commit(root):
            raise ValueError('Seed inputs changed during build/qualification')
        manifest = {'schemaVersion': 1, 'commit': commit, 'sourceInputs': before,
                    'toolchain': toolchain, 'architecture': architecture, 'binarySHA256': digest(binary),
                    'budgetSeconds': SEED_BUDGET_SECONDS, 'producerElapsedSeconds': elapsed,
                    'buildReceipt': json.loads((results / 'seed-build.json').read_text()),
                    'qualificationReceipt': json.loads((results / 'qualification.json').read_text()),
                    'fixture': fixture}
        manifest_bytes = (json.dumps(manifest, indent=2) + '\n').encode('utf-8')
        trusted_digest = hashlib.sha256(manifest_bytes).hexdigest()
        (results / 'manifest.json').write_bytes(manifest_bytes)
        validate_artifact(root, results, toolchain, architecture, commit, trusted_digest)
    print(f'SEED ARTIFACT PASS: exact inputs, qualified executable, {elapsed:.2f}s of 240s; no Simulator', flush=True)
    print('SEED MANIFEST SHA256: '+trusted_digest, flush=True)
    return trusted_digest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    trusted_digest = build_artifact(Path(__file__).resolve().parents[1], arguments.output.resolve())
    if os.environ.get('GITHUB_OUTPUT'):
        publish_digest(trusted_digest, Path(os.environ['GITHUB_OUTPUT']))
