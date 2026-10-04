import copy
import hashlib
import importlib.util
import json
import inspect
import os
from pathlib import Path
import struct
import sqlite3
import subprocess
import sys
import tempfile
from unittest import mock
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

class SeedArtifactTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.find_spec('verify_replay_seed')
        self.assertIsNotNone(spec, 'A fail-closed reusable Seed artifact boundary is required')
        self.seed = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.seed)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'repo'
        for name in ['mobile-ios/TelemetryCore/Package.swift', 'mobile-ios/TelemetryCore/Sources/TelemetryCore/Core.swift',
                     'mobile-ios/TelemetryCore/Sources/CSQLite/module.modulemap', 'scripts/tests/offline_replay_seed.swift',
                     'scripts/verify_replay_seed.py']:
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('fixture input\n')
        self.artifact = Path(self.tmp.name) / 'artifact'
        self.artifact.mkdir()
        self.binary = self.artifact / 'Seed'
        self.binary.write_bytes(struct.pack('<IiiIIIII', 0xfeedfacf, 0x100000c, 0, 2, 0, 0, 0, 0))
        self.toolchain = {'xcode_version': '27.0', 'xcode_build': '27A266a', 'ios_sdk': '27.0', 'simulator_sdk': '27.0'}
        self.commit = 'a' * 40
        self.manifest = {
            'schemaVersion': 1, 'commit': self.commit, 'sourceInputs': self.seed.source_inputs(self.root),
            'toolchain': self.toolchain, 'architecture': 'arm64',
            'binarySHA256': hashlib.sha256(self.binary.read_bytes()).hexdigest(), 'budgetSeconds': 240,
            'producerElapsedSeconds': 11.1,
            'buildReceipt': {'exitCode': 0, 'timedOut': False, 'elapsedSeconds': 10},
            'qualificationReceipt': {'exitCode': 0, 'timedOut': False, 'elapsedSeconds': 1},
            'fixture': self.seed.EXPECTED_FIXTURE,
        }
        self.save()

    def save(self, update_trust=True):
        (self.artifact / 'manifest.json').write_text(json.dumps(self.manifest))
        if update_trust:
            self.trusted_digest = hashlib.sha256((self.artifact/'manifest.json').read_bytes()).hexdigest()

    def validate(self):
        return self.seed.validate_artifact(self.root, self.artifact, self.toolchain, 'arm64', self.commit,
                                           self.trusted_digest)

    def test_binary_and_manifest_joint_tamper_is_rejected_by_external_producer_digest(self):
        self.assertIn('expected_manifest_sha256', inspect.signature(self.seed.validate_artifact).parameters,
                      'Artifact-internal hashes alone do not establish producer provenance')
        self.binary.write_bytes(self.binary.read_bytes()+b'changed')
        self.manifest['binarySHA256'] = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.save(update_trust=False)
        with self.assertRaises(ValueError):
            self.seed.validate_artifact(self.root, self.artifact, self.toolchain, 'arm64', self.commit,
                                        self.trusted_digest)

    def test_missing_or_malformed_external_digest_is_rejected(self):
        self.assertIn('expected_manifest_sha256', inspect.signature(self.seed.validate_artifact).parameters)
        for value in ['', 'f'*63, 'g'*64, self.trusted_digest+'\n']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.seed.validate_artifact(self.root, self.artifact, self.toolchain, 'arm64', self.commit, value)

    def test_private_copy_is_independent_of_download_path_mutation(self):
        self.assertTrue(hasattr(self.seed, 'private_artifact'), 'Validate an owned private copy, not download paths')
        private = Path(self.tmp.name)/'private'
        value = self.seed.private_artifact(self.root, self.artifact, private, self.toolchain,
                                           'arm64', self.commit, self.trusted_digest)
        self.assertNotEqual(value['binary'], self.binary)
        original_hash = value['binarySHA256']
        self.binary.write_bytes(b'download path replaced')
        (self.artifact/'manifest.json').write_text('{}')
        self.assertEqual(hashlib.sha256(value['binary'].read_bytes()).hexdigest(), original_hash)
        if os.name == 'posix':
            self.assertEqual(private.stat().st_mode & 0o077, 0)
            self.assertEqual(value['binary'].stat().st_mode & 0o222, 0)

    def test_trusted_digest_is_published_via_separate_job_output(self):
        self.assertTrue(hasattr(self.seed, 'publish_digest'), 'Producer must use a separate job output')
        output = Path(self.tmp.name)/'job-output'
        self.seed.publish_digest(self.trusted_digest, output)
        self.assertEqual(output.read_text(), 'manifest_sha256='+self.trusted_digest+'\n')

    def test_valid_artifact_keeps_original_combined_budget(self):
        value = self.validate()
        self.assertEqual(value['binary'], self.binary)
        self.assertAlmostEqual(value['remainingSeconds'], 228.9)

    def test_missing_manifest_or_binary_fails_without_building(self):
        for file in ['manifest.json', 'Seed']:
            with self.subTest(file=file):
                p = self.artifact / file
                original = p.read_bytes()
                p.unlink()
                with self.assertRaises(ValueError): self.validate()
                p.write_bytes(original)

    def test_tampered_binary_and_source_are_rejected(self):
        self.binary.write_bytes(self.binary.read_bytes() + b'changed')
        with self.assertRaises(ValueError): self.validate()
        self.binary.write_bytes(struct.pack('<IiiIIIII', 0xfeedfacf, 0x100000c, 0, 2, 0, 0, 0, 0))
        (self.root / 'scripts/tests/offline_replay_seed.swift').write_text('changed input')
        with self.assertRaises(ValueError): self.validate()

    def test_deleted_or_added_core_source_is_rejected(self):
        p = self.root / 'mobile-ios/TelemetryCore/Sources/TelemetryCore/Extra.swift'
        p.write_text('new input')
        with self.assertRaises(ValueError): self.validate()
        p.unlink()
        (self.root / 'mobile-ios/TelemetryCore/Sources/TelemetryCore/Core.swift').unlink()
        with self.assertRaises(ValueError): self.validate()

    def test_wrong_commit_schema_toolchain_or_architecture_is_rejected(self):
        good = copy.deepcopy(self.manifest)
        for field, value in [('commit', 'b'*40), ('schemaVersion', 2), ('architecture', 'x86_64'),
                             ('toolchain', {**self.toolchain, 'xcode_build': '27A999'})]:
            with self.subTest(field=field):
                self.manifest = {**good, field: value}; self.save()
                with self.assertRaises(ValueError): self.validate()
        self.manifest = good; self.save()

    def test_manifest_cannot_claim_arm64_for_x86_binary(self):
        self.binary.write_bytes(struct.pack('<IiiIIIII', 0xfeedfacf, 0x1000007, 3, 2, 0, 0, 0, 0))
        self.manifest['binarySHA256'] = hashlib.sha256(self.binary.read_bytes()).hexdigest(); self.save()
        with self.assertRaises(ValueError): self.validate()

    def test_failed_or_timed_out_producer_is_rejected(self):
        good = copy.deepcopy(self.manifest)
        for phase in ['buildReceipt', 'qualificationReceipt']:
            for field, value in [('exitCode', 7), ('timedOut', True), ('elapsedSeconds', -1)]:
                with self.subTest(phase=phase, field=field):
                    self.manifest = copy.deepcopy(good)
                    self.manifest[phase][field] = value; self.save()
                    with self.assertRaises(ValueError): self.validate()

    def test_budget_change_exhaustion_nan_or_falsely_small_elapsed_is_rejected(self):
        good = copy.deepcopy(self.manifest)
        for field, value in [('budgetSeconds', 241), ('producerElapsedSeconds', 240),
                             ('producerElapsedSeconds', float('nan')), ('producerElapsedSeconds', 2)]:
            with self.subTest(field=field, value=value):
                self.manifest = {**good, field: value}; self.save()
                with self.assertRaises(ValueError): self.validate()

    def test_missing_or_wrong_fixture_qualification_is_rejected(self):
        for value in [None, {}, {'sessions': []}]:
            self.manifest['fixture'] = value; self.save()
            with self.assertRaises(ValueError): self.validate()

    @unittest.skipUnless(os.name == 'posix', 'Owned POSIX Seed process')
    def test_consumer_execution_failure_cannot_be_green_and_has_no_rebuild_fallback(self):
        self.binary.write_text('#!/bin/sh\nexit 7\n'); self.binary.chmod(0o755)
        value = {'binary': self.binary, 'remainingSeconds': 5,
                 'binarySHA256': hashlib.sha256(self.binary.read_bytes()).hexdigest()}
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.seed.run_artifact(value, Path(self.tmp.name)/'fixture', Path(self.tmp.name)/'results')
        self.assertEqual(caught.exception.returncode, 7)
        receipt = json.loads((Path(self.tmp.name)/'results/seed-run.json').read_text())
        self.assertEqual(receipt['command'][0], str(self.binary))
        self.assertEqual(receipt['exitCode'], 7)
        self.assertFalse(receipt['timedOut'])

    @unittest.skipUnless(os.name == 'posix', 'Owned POSIX Seed process')
    def test_consumer_budget_exhaustion_cannot_launch_binary(self):
        marker = Path(self.tmp.name)/'executed'
        self.binary.write_text('#!/bin/sh\ntouch '+str(marker)+'\n'); self.binary.chmod(0o755)
        value = {'binary': self.binary, 'remainingSeconds': 0,
                 'binarySHA256': hashlib.sha256(self.binary.read_bytes()).hexdigest()}
        with self.assertRaises(subprocess.TimeoutExpired):
            self.seed.run_artifact(value, Path(self.tmp.name)/'fixture', Path(self.tmp.name)/'results')
        self.assertFalse(marker.exists())

    @unittest.skipUnless(os.name == 'posix', 'Owned POSIX Seed process')
    def test_consumer_runtime_timeout_is_failure(self):
        self.binary.write_text('#!/bin/sh\nsleep 30\n'); self.binary.chmod(0o755)
        value = {'binary': self.binary, 'remainingSeconds': 0.1,
                 'binarySHA256': hashlib.sha256(self.binary.read_bytes()).hexdigest()}
        with self.assertRaises(subprocess.TimeoutExpired):
            self.seed.run_artifact(value, Path(self.tmp.name)/'fixture', Path(self.tmp.name)/'results')
        receipt = json.loads((Path(self.tmp.name)/'results/seed-run.json').read_text())
        self.assertTrue(receipt['timedOut'])
        self.assertTrue(receipt['groupTermSent'])

    def test_invalid_artifact_is_rejected_before_any_simulator_command(self):
        import verify_offline_replay as runner
        result = Path(self.tmp.name)/'gate'
        argv = ['verify', '--seed-artifact', str(self.artifact), '--seed-manifest-sha256', self.trusted_digest,
                '--result-directory', str(result)]
        with mock.patch.object(runner, 'record_toolchain', return_value=self.toolchain), \
             mock.patch.object(runner, 'current_commit', return_value=self.commit), \
             mock.patch.object(runner.platform, 'machine', return_value='arm64'), \
             mock.patch.object(runner, 'output') as simulator_command, mock.patch.object(sys, 'argv', argv):
            with self.assertRaises(ValueError): runner.main()
            simulator_command.assert_not_called()
            self.assertFalse((result/'environment.json').exists())

    def test_valid_admission_is_written_before_first_simulator_command(self):
        import verify_offline_replay as runner
        self.manifest['sourceInputs'] = self.seed.source_inputs(SCRIPTS.parent); self.save()
        result = Path(self.tmp.name)/'gate'
        argv = ['verify', '--seed-artifact', str(self.artifact), '--seed-manifest-sha256', self.trusted_digest,
                '--result-directory', str(result)]
        def completed_fixture(value, destination, results):
            self.assertNotEqual(value['binary'], self.binary)
            self.assertEqual(hashlib.sha256(value['binary'].read_bytes()).hexdigest(), self.manifest['binarySHA256'])
            (results/'seed-fixture.json').write_text(json.dumps(self.seed.EXPECTED_FIXTURE))
        def first_command(command):
            self.assertTrue((result/'seed-admission.json').exists())
            self.assertTrue((result/'seed-fixture.json').exists(), 'Fixture execution must finish before Simulator access')
            self.assertEqual(command[:4], ['xcrun', 'simctl', 'list', 'runtimes'])
            raise RuntimeError('Stop before creating a Simulator in contract test')
        with mock.patch.object(runner, 'record_toolchain', return_value=self.toolchain), \
             mock.patch.object(runner, 'current_commit', return_value=self.commit), \
             mock.patch.object(runner.platform, 'machine', return_value='arm64'), \
             mock.patch.object(runner, 'run_artifact', side_effect=completed_fixture), \
             mock.patch.object(runner, 'output', side_effect=first_command), mock.patch.object(sys, 'argv', argv):
            with self.assertRaisesRegex(RuntimeError, 'Stop before creating'): runner.main()

    def test_binary_replacement_after_admission_fails_before_execution(self):
        value = self.validate()
        self.binary.write_bytes(self.binary.read_bytes()+b'changed after admission')
        with self.assertRaises(ValueError):
            self.seed.run_artifact(value, Path(self.tmp.name)/'fixture', Path(self.tmp.name)/'results')
        self.assertFalse((Path(self.tmp.name)/'results/seed-run.json').exists())

    def test_symlink_artifact_is_not_admitted(self):
        if os.name != 'posix': self.skipTest('POSIX symlink')
        original = self.artifact/'original'
        self.binary.rename(original)
        self.binary.symlink_to(original)
        with self.assertRaises(ValueError): self.validate()

    def test_data_install_preserves_wal_rows_and_raw_profile_bytes(self):
        source = Path(self.tmp.name)/'fixture'
        source.mkdir()
        connection = sqlite3.connect(source/'measurements.sqlite3')
        self.addCleanup(connection.close)
        connection.execute('PRAGMA journal_mode=WAL')
        connection.executescript('CREATE TABLE measurement_sessions(session_id TEXT PRIMARY KEY, mode TEXT, ended_at REAL);\nCREATE TABLE measurements(sequence INTEGER PRIMARY KEY, session_id TEXT, payload_json TEXT);')
        sequence = 0
        for name, expected in self.seed.EXPECTED_FIXTURE['sessions'].items():
            connection.execute('INSERT INTO measurement_sessions VALUES(?,?,?)', (name, 'DEMO', 305))
            for _ in range(expected['rows']):
                sequence += 1
                connection.execute('INSERT INTO measurements VALUES(?,?,?)',
                                   (sequence, name, '{"raw":"AA 00","unit":"%","name":"Live"}'))
        connection.commit()
        self.assertGreater((source/'measurements.sqlite3-wal').stat().st_size, 0)
        profile = b'{"id":"offline-fixture","pages":[{"id":"fixture","widgets":[{},{},{},{},{},{},{}]}]}'
        (source/'dashboard.json').write_bytes(profile)
        target = Path(self.tmp.name)/'new-container'
        self.assertEqual(self.seed.install_fixture(source, target), self.seed.EXPECTED_FIXTURE)
        with sqlite3.connect(target/'measurements.sqlite3') as copied:
            self.assertEqual(copied.execute('SELECT * FROM measurements ORDER BY sequence').fetchall(),
                             connection.execute('SELECT * FROM measurements ORDER BY sequence').fetchall())
        copied.close()
        self.assertEqual((target/'dashboard.json').read_bytes(), profile)

    def test_data_install_refuses_existing_directory_without_overwriting(self):
        target = Path(self.tmp.name)/'existing-container'
        target.mkdir()
        marker = target/'dashboard.json'
        marker.write_text('preserved')
        with self.assertRaises(FileExistsError):
            self.seed.install_fixture(Path(self.tmp.name)/'fixture', target)
        self.assertEqual(marker.read_text(), 'preserved')

    def test_runner_requires_valid_seed_before_creating_or_booting_simulator(self):
        import verify_offline_replay as runner
        argv = [sys.executable, str(SCRIPTS/'verify_offline_replay.py'), '--result-directory', str(Path(self.tmp.name)/'gate')]
        result = subprocess.run(argv, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--seed-artifact', result.stderr)
        self.assertFalse((Path(self.tmp.name)/'gate/environment.json').exists())

if __name__ == '__main__': unittest.main()
