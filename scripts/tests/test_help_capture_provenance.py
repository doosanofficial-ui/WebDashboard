"""Synthetic product/attachment fixtures. These never certify real captures."""
import copy
from contextlib import ExitStack, redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import help_capture_provenance as proof

SIMULATOR = '11111111-1111-4111-8111-111111111111'
TARGETS = {f'Help-{guide}-{language}-{number}': target
           for language in ('en', 'ko')
           for guide, values in {'live': ['record', 'gps', 'event'], 'editor': ['resize', 'undo'],
                                 'setup': ['import', 'start'], 'sessions': ['picker', 'export', 'replay'],
                                 'replay': ['play', 'time'], 'signals': ['raw', 'stale']}.items()
           for number, target in enumerate(values, 1)}


def digest(data):
    return hashlib.sha256(data).hexdigest()


class HelpProductReceiptTests(unittest.TestCase):
    def fixture(self, root, version=2, app_directory="Debug-iphonesimulator"):
        products = root / 'Build/Products'
        app = products / app_directory / 'Telemetry.app'
        runner = products / 'Debug-iphonesimulator/TelemetryUITests-Runner.app'
        tests = runner / 'PlugIns/TelemetryUITests.xctest'
        for bundle, executable in ((app, 'Telemetry'), (runner, 'TelemetryUITests-Runner'), (tests, 'TelemetryUITests')):
            bundle.mkdir(parents=True, exist_ok=True)
            (bundle / executable).write_bytes(b'synthetic executable fixture; never native')
            with (bundle / 'Info.plist').open('wb') as stream:
                plistlib.dump({'CFBundleExecutable': executable}, stream)
        target = {'BlueprintName': 'TelemetryUITests',
                  'TestHostPath': '__TESTROOT__/Debug-iphonesimulator/TelemetryUITests-Runner.app',
                  'TestBundlePath': '__TESTHOST__/PlugIns/TelemetryUITests.xctest',
                  'UITargetAppPath': '__TESTROOT__/' + app_directory + '/Telemetry.app',
                  'EnvironmentVariables': {'PRESERVE_EXISTING_VALUE': 'yes'}}
        config = {'TestConfigurations': [{'TestTargets': [target]}], '__xctestrun_metadata__': {'FormatVersion': 2}} if version == 2 else {'TelemetryUITests': target}
        path = products / 'Telemetry_fixture.xctestrun'
        with path.open('wb') as stream:
            plistlib.dump(config, stream)
        source = {'schemaVersion': 1, 'scope': 'help-capture-source-inventory',
                  'sourceBaseCommit': 'a' * 40, 'sourceInputs': {'mobile-ios/App/Fixture.swift': 'b' * 64},
                  'captureTestSHA256': 'c' * 64, 'captureCertified': False}
        return products, source, app, runner, tests, path

    def attachments(self, root, context):
        exported = root / 'screenshots'
        exported.mkdir()
        rows = []
        for language in ('en', 'ko'):
            test = 'LocalizationHelpUITests/testCapture' + ('English' if language == 'en' else 'Korean') + 'GuideScreens()'
            row = {'testIdentifier': test, 'attachments': []}
            for name, target in TARGETS.items():
                if f'-{language}-' not in name:
                    continue
                number = int(name.rsplit('-', 1)[1])
                image = b'\x89PNG\r\n\x1a\nsynthetic-unit-only-' + name.encode()
                markers = json.dumps([{'number': number, 'x': .5, 'y': .5}]).encode()
                receipt = {'schemaVersion': 1, 'runID': context['runID'], 'productsSHA256': context['productsSHA256'],
                           'sourceReceiptSHA256': context['sourceReceiptSHA256'],
                           'simulatorUUID': SIMULATOR, 'screen': name, 'test': test, 'targetID': target,
                           'sha256': digest(image), 'markerSHA256': digest(markers),
                           'timestamp': context['startedAt'] + .01, 'fixture': 'synthetic-offline'}
                for suffix, extension, content in (('', '.png', image), ('-markers', '.json', markers),
                                                    ('-capture-receipt', '.json', json.dumps(receipt).encode())):
                    filename = name + suffix + extension
                    (exported / filename).write_bytes(content)
                    row['attachments'].append({'deviceId': SIMULATOR, 'isAssociatedWithFailure': False,
                        'exportedFileName': filename, 'suggestedHumanReadableName': name + suffix + '_0_fixture' + extension,
                        'timestamp': context['startedAt'] + .02})
            rows.append(row)
        (exported / 'manifest.json').write_text(json.dumps(rows))
        result = root / 'ReplayUI.xcresult'
        result.mkdir()
        (result / 'fixture.txt').write_text('synthetic result only; no XCTest executed')
        return exported, result

    def finish(self, root, products, source, before, exported, result):
        with patch.object(proof.time, 'time', return_value=before['startedAt'] + 1):
            return proof.finish_run(products, before, dict(source, sourceStableDuringRun=True), exported, result, TARGETS)

    def test_literal_double_underscores_in_owned_products_do_not_become_placeholders(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'literal__owned__root'
            products, source, *_ = self.fixture(root)
            before = proof.prepare_run(products, source, SIMULATOR)
            exported, result = self.attachments(root, before)
            run = self.finish(root, products, source, before, exported, result)
            proof.verify_capture_run(run, run['captures'], source['sourceInputs'], TARGETS, source['captureTestSHA256'])
            self.assertEqual(len(run['captures']), 28)
            rows = json.loads((exported / 'manifest.json').read_text())
            receipt = exported / rows[0]['attachments'][2]['exportedFileName']
            value = json.loads(receipt.read_text()); value['productsSHA256'] = 'e' * 64
            receipt.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'Mixed capture execution: productsSHA256'):
                self.finish(root, products, source, before, exported, result)

    def test_unresolved_original_product_tokens_still_fail_with_literal_root_underscores(self):
        for field, value in (
            ('TestHostPath', '__UNKNOWN__/TelemetryUITests-Runner.app'),
            ('TestHostPath', '__TESTHOST__/TelemetryUITests-Runner.app'),
            ('UITargetAppPath', '__TESTROOT__/__UNKNOWN__/Telemetry.app'),
            ('TestBundlePath', '__TESTHOST__/__UNKNOWN__/TelemetryUITests.xctest'),
        ):
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as directory:
                products, source, *_, path = self.fixture(Path(directory) / 'literal__owned__root')
                data = plistlib.loads(path.read_bytes())
                data['TestConfigurations'][0]['TestTargets'][0][field] = value
                path.write_bytes(plistlib.dumps(data))
                with self.assertRaisesRegex(ValueError, 'Unsupported product path placeholder'):
                    proof.prepare_run(products, source, SIMULATOR)

    def test_generated_xctestrun_binds_all_final_products_and_executes_without_building(self):
        for version in (1, 2):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                products, source, app, runner, tests, path = self.fixture(Path(directory), version)
                context = proof.prepare_run(products, source, SIMULATOR)
                self.assertEqual(set(context['productsBefore']), {'application', 'xctest', 'runner'})
                for item in context['productsBefore'].values():
                    self.assertEqual(len(item['executableSHA256']), 64)
                    self.assertEqual(len(item['bundleSHA256']), 64)
                data = plistlib.loads(path.read_bytes())
                target = data['TestConfigurations'][0]['TestTargets'][0] if version == 2 else data['TelemetryUITests']
                env = target['EnvironmentVariables']
                self.assertEqual(env['PRESERVE_EXISTING_VALUE'], 'yes')
                self.assertEqual(env['HELP_CAPTURE_RUN_ID'], context['runID'])
                self.assertEqual(env['HELP_CAPTURE_PRODUCTS_SHA256'], context['productsSHA256'])
                self.assertEqual(env['HELP_CAPTURE_SIMULATOR_UUID'], SIMULATOR)
                command = proof.test_command(products, context, Path(directory) / 'result.xcresult', ['-only-testing:Fixture'])
                self.assertIn('test-without-building', command)
                self.assertNotIn('test', command)
                self.assertNotIn('-project', command)
                self.assertNotIn('-scheme', command)
                self.assertIn(str(path), command)

    def test_incomplete_or_ambiguous_final_products_fail_before_capture(self):
        for fault in ('app', 'runner', 'xctest', 'duplicate-config', 'escaping-product', 'symlink-product'):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                products, source, app, runner, tests, path = self.fixture(root)
                if fault in ('app', 'runner', 'xctest'):
                    bundle = {'app': app, 'runner': runner, 'xctest': tests}[fault]
                    (bundle / plistlib.loads((bundle / 'Info.plist').read_bytes())['CFBundleExecutable']).unlink()
                elif fault == 'duplicate-config':
                    (products / 'another.xctestrun').write_bytes(path.read_bytes())
                elif fault == 'symlink-product':
                    (app / 'external').symlink_to(root.parent)
                else:
                    data = plistlib.loads(path.read_bytes())
                    data['TestConfigurations'][0]['TestTargets'][0]['UITargetAppPath'] = str(root.parent)
                    path.write_bytes(plistlib.dumps(data))
                with self.assertRaises((ValueError, FileNotFoundError)):
                    proof.prepare_run(products, source, SIMULATOR)

    def test_completed_run_binds_exactly_twenty_eight_receipts_to_sources_products_and_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); products, source, *_ = self.fixture(root)
            before = proof.prepare_run(products, source, SIMULATOR)
            exported, result = self.attachments(root, before)
            run = self.finish(root, products, source, before, exported, result)
            self.assertEqual(len(run['captures']), 28)
            self.assertFalse(run['captureCertified'])
            self.assertTrue(run['visualReviewRequired'])
            proof.verify_capture_run(run, run['captures'], source['sourceInputs'], TARGETS, source['captureTestSHA256'])
            for key in ('productsBefore', 'productsAfter', 'captures', 'resultBundleSHA256', 'xctestrunSHA256After'):
                broken = copy.deepcopy(run); broken.pop(key)
                with self.subTest(missing=key), self.assertRaises(ValueError):
                    proof.verify_capture_run(broken, run['captures'], source['sourceInputs'], TARGETS, source['captureTestSHA256'])
            for mutation in ('mixed-run', 'stale-source', 'changed-test', 'rebuild', 'changed-product-digest', 'omitted-receipt'):
                broken = copy.deepcopy(run)
                name = next(iter(broken['captures']))
                if mutation == 'mixed-run': broken['captures'][name]['runID'] = '22222222-2222-4222-8222-222222222222'
                elif mutation == 'stale-source': broken['sourceReceipt']['sourceInputs']['mobile-ios/App/Fixture.swift'] = 'd' * 64
                elif mutation == 'changed-test': broken['sourceReceipt']['captureTestSHA256'] = 'd' * 64
                elif mutation == 'rebuild': broken['productsAfter']['runner']['executableSHA256'] = 'd' * 64
                elif mutation == 'changed-product-digest': broken['productsSHA256'] = 'd' * 64
                else: broken['captures'].pop(name)
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    proof.verify_capture_run(broken, run['captures'], source['sourceInputs'], TARGETS, source['captureTestSHA256'])

    def test_actual_product_or_xctestrun_changes_after_preparation_reject_rebuild_mismatch(self):
        for target in ('application', 'runner', 'xctest', 'xctestrun'):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); products, source, app, runner, tests, path = self.fixture(root)
                before = proof.prepare_run(products, source, SIMULATOR)
                exported, result = self.attachments(root, before)
                changed = path if target == 'xctestrun' else {'application': app / 'Telemetry', 'runner': runner / 'TelemetryUITests-Runner', 'xctest': tests / 'TelemetryUITests'}[target]
                changed.write_bytes(changed.read_bytes() + b'changed final product')
                with self.assertRaisesRegex(ValueError, 'changed|rebuild'):
                    self.finish(root, products, source, before, exported, result)

    def test_missing_mixed_duplicate_failed_or_changed_attachments_cannot_be_certified(self):
        for fault in ('missing-receipt', 'mixed-run', 'mixed-product', 'mixed-device', 'wrong-test', 'wrong-target',
                      'changed-png', 'changed-marker', 'duplicate', 'failed', 'out-of-run', 'escaping-file'):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); products, source, *_ = self.fixture(root)
                before = proof.prepare_run(products, source, SIMULATOR)
                exported, result = self.attachments(root, before)
                manifest_path = exported / 'manifest.json'; rows = json.loads(manifest_path.read_text())
                row = rows[0]; png, marker, receipt = row['attachments'][:3]
                value = json.loads((exported / receipt['exportedFileName']).read_text())
                if fault == 'missing-receipt': row['attachments'].remove(receipt)
                elif fault == 'mixed-run': value['runID'] = '22222222-2222-4222-8222-222222222222'
                elif fault == 'mixed-product': value['productsSHA256'] = 'e' * 64
                elif fault == 'mixed-device': png['deviceId'] = '22222222-2222-4222-8222-222222222222'
                elif fault == 'wrong-test': row['testIdentifier'] = rows[1]['testIdentifier']
                elif fault == 'wrong-target': value['targetID'] = 'other-control'
                elif fault == 'changed-png': (exported / png['exportedFileName']).write_bytes(b'changed')
                elif fault == 'changed-marker': (exported / marker['exportedFileName']).write_bytes(b'[]')
                elif fault == 'duplicate': row['attachments'].append(dict(receipt))
                elif fault == 'failed': png['isAssociatedWithFailure'] = True
                elif fault == 'out-of-run': value['timestamp'] = before['startedAt'] - 100
                else: png['exportedFileName'] = '../outside.png'
                (exported / receipt['exportedFileName']).write_text(json.dumps(value))
                manifest_path.write_text(json.dumps(rows))
                with self.assertRaises(ValueError):
                    self.finish(root, products, source, before, exported, result)

    def producer_trial(self, fault=None):
        """Main's real ordering; every native, fixture-data and device boundary is fake."""
        import verify_offline_replay as runner
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); results = root / 'results'
            events, phases = [], []
            original_error = subprocess.TimeoutExpired(['synthetic-boundary'], 180 if fault == 'boot' else 60)
            source = {'schemaVersion': 1, 'scope': 'help-capture-source-inventory', 'sourceBaseCommit': 'a' * 40,
                      'sourceInputs': {'mobile-ios/App/Fixture.swift': 'b' * 64}, 'captureTestSHA256': 'c' * 64,
                      'captureCertified': False}
            def stage(_root, destination):
                (destination / 'App').mkdir(parents=True)
                (destination / 'App/AppHelpView.swift').write_text('synthetic guide parser boundary')
            def output(command, timeout=60):
                events.append(command)
                if command[1:4] == ['simctl', 'list', 'runtimes']:
                    return json.dumps({'runtimes': [{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                        'version': '27.0', 'isAvailable': True,
                        'supportedDeviceTypes': [{'identifier': 'synthetic-iPhone', 'productFamily': 'iPhone'}]}]})
                if command[1:3] == ['simctl', 'create']: return SIMULATOR
                if command[0] == 'xcodegen' or command[1:3] == ['simctl', 'install']: return ''
                if command[1:5] == ['xcresulttool', 'get', 'test-results', 'summary']:
                    return json.dumps({'totalTestCount': 2, 'passedTests': 2, 'failedTests': 0, 'skippedTests': 0})
                if command[1:4] == ['xcresulttool', 'export', 'attachments']: return ''
                raise AssertionError('Unexpected fake native boundary: ' + repr(command))
            def boot(*args, **kwargs):
                if fault == 'boot': raise original_error
            def container(*args, **kwargs):
                if fault == 'app-container': raise original_error
                return str(root / 'device/Containers/Data/Application' / SIMULATOR)
            def phase(command, log, receipt, timeout):
                phases.append(command)
                if 'build-for-testing' in command:
                    self.fixture(Path(command[command.index('-derivedDataPath') + 1]), app_directory='Generated-configuration')
                elif 'test-without-building' in command:
                    before = json.loads((results / 'help-capture-run-before.json').read_text())
                    self.attachments(results, before)
                    # Unit timestamps must precede the host's finish boundary.
                    for file in (results / 'screenshots').glob('*-capture-receipt.json'):
                        value = json.loads(file.read_text()); value['timestamp'] = before['startedAt']; file.write_text(json.dumps(value))
                    if fault == 'rebuild':
                        path = Path(command[command.index('-xctestrun') + 1]).parent / 'Debug-iphonesimulator/TelemetryUITests-Runner.app/TelemetryUITests-Runner'
                        path.write_bytes(b'changed runner after fake capture')
                else: raise AssertionError('Unexpected build/test mode')
            stdout = io.StringIO(); caught = None
            arguments = ['verify_offline_replay.py', '--result-directory', str(results), '--seed-artifact', directory,
                         '--seed-manifest-sha256', 'a' * 64, '--only-test', 'help-capture']
            with ExitStack() as stack:
                stack.enter_context(patch.object(sys, 'argv', arguments))
                for name, value in (('record_toolchain', {}), ('private_artifact', {'manifest': {}}),
                                    ('run_artifact', None), ('current_commit', 'a' * 40), ('cleanup_simulator', True),
                                    ('observe_first_failure', None), ('capture_simulator_bootstrap_failure', None), ('install_fixture', None)):
                    stack.enter_context(patch.object(runner, name, return_value=value))
                stream = stack.enter_context(patch.object(runner, 'OwnedSimulatorBootLog'))
                stream.return_value.finalize.return_value = {'collectorCleaned': True}
                stack.enter_context(patch.object(runner, 'stage_sources', side_effect=stage))
                stack.enter_context(patch.object(runner.help_sources, 'begin_capture', return_value=source))
                stack.enter_context(patch.object(runner.help_sources, 'finish_capture', return_value=dict(source, sourceStableDuringRun=True)))
                stack.enter_context(patch.object(runner, 'expected_capture_targets', return_value=TARGETS))
                stack.enter_context(patch.object(runner, 'prepare_simulator', side_effect=boot))
                stack.enter_context(patch.object(runner, 'output', side_effect=output))
                stack.enter_context(patch.object(runner.failure_observation, 'simctl_output', side_effect=container))
                stack.enter_context(patch.object(runner, 'run_owned_phase', side_effect=phase))
                stack.enter_context(redirect_stdout(stdout))
                try: runner.main()
                except Exception as error: caught = error
            run = results / 'help-capture-run.json'
            return {'error': caught, 'original': original_error, 'phases': phases, 'events': events,
                    'run': json.loads(run.read_text()) if run.exists() else None,
                    'completed': (results / 'ui-completion.json').exists(), 'stdout': stdout.getvalue()}

    def test_owned_producer_builds_once_and_publishes_only_after_same_run_verification(self):
        result = self.producer_trial()
        self.assertIsNone(result['error'])
        self.assertEqual(len(result['phases']), 2)
        self.assertIn('build-for-testing', result['phases'][0])
        self.assertIn('test-without-building', result['phases'][1])
        self.assertEqual(len(result['run']['captures']), 28)
        products = Path(result['phases'][1][result['phases'][1].index('-xctestrun') + 1]).parent
        install = next(command for command in result['events'] if command[1:3] == ['simctl', 'install'])
        self.assertEqual(Path(install[-1]), products / result['run']['productsBefore']['application']['path'],
                         'Installed application must be the exact xctestrun/digest product')
        self.assertTrue(result['completed'])
        broken = self.producer_trial('rebuild')
        self.assertIsInstance(broken['error'], ValueError)
        self.assertIn('rebuilt', str(broken['error']))
        self.assertIsNone(broken['run'])
        self.assertFalse(broken['completed'])
        self.assertNotIn('OFFLINE REPLAY UI PASS', broken['stdout'])

    def test_remote_pre_ui_failure_classes_preserve_timeout_and_never_publish_ui_success(self):
        for fault, timeout in (('boot', 180), ('app-container', 60)):
            with self.subTest(fault=fault):
                value = self.producer_trial(fault)
                self.assertIs(value['error'], value['original'])
                self.assertEqual(value['error'].timeout, timeout)
                self.assertFalse(any('test-without-building' in command for command in value['phases']))
                self.assertFalse(value['completed'])
                self.assertIsNone(value['run'])
                self.assertNotIn('OFFLINE REPLAY UI PASS', value['stdout'])


if __name__ == '__main__':
    unittest.main()
