"""Bind fresh Help attachments to one unchanged build-for-testing product set.

Only the owned UI runner calls the producer. Verification is read-only and cannot
upgrade historical source inventories/captures into same-run binary evidence.
This contract does not perform the required foreground visual review.
"""
import copy
import hashlib
import json
from pathlib import Path
import plistlib
import re
import time
import uuid


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def object_digest(value):
    return sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode())


def valid_digest(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def canonical_uuid(value):
    try:
        require(isinstance(value, str) and str(uuid.UUID(value)).upper() == value, 'Noncanonical capture UUID')
    except (TypeError, AttributeError, ValueError) as error:
        raise ValueError('Missing/invalid capture UUID') from error
    return value


def tree_digest(directory):
    require(directory.is_dir() and not directory.is_symlink(), 'Missing final product/result bundle')
    files = {}
    for path in sorted(directory.rglob('*')):
        require(not path.is_symlink(), 'Symlink in final product/result bundle')
        if path.is_file():
            data = path.read_bytes()
            files[path.relative_to(directory).as_posix()] = {'sha256': sha256(data), 'bytes': len(data)}
    require(bool(files), 'Empty final product/result bundle')
    return object_digest(files), len(files)


def _source_receipt(value):
    require(isinstance(value, dict) and value.get('schemaVersion') == 1
            and value.get('scope') == 'help-capture-source-inventory'
            and value.get('captureCertified') is False
            and isinstance(value.get('sourceBaseCommit'), str)
            and re.fullmatch('[0-9a-f]{40}', value['sourceBaseCommit']) is not None
            and valid_digest(value.get('captureTestSHA256')), 'Missing source/test receipt')
    inputs = value.get('sourceInputs')
    require(isinstance(inputs, dict) and bool(inputs) and all(valid_digest(h) for h in inputs.values()),
            'Missing source input hashes')


def _target(config):
    if 'TestConfigurations' in config:
        targets = [target for entry in config['TestConfigurations'] for target in entry['TestTargets']
                   if target.get('BlueprintName') == 'TelemetryUITests']
    else:
        targets = [config['TelemetryUITests']] if 'TelemetryUITests' in config else []
    require(len(targets) == 1, 'Exactly one generated TelemetryUITests target required')
    return targets[0]


def _under_products(path, products):
    try:
        path.resolve().relative_to(products.resolve())
    except ValueError as error:
        raise ValueError('Final product escapes owned build products') from error
    return path


def _product_path(value, products, host=None):
    require(isinstance(value, str) and bool(value), 'Missing final product path')
    value = value.replace('__TESTROOT__', str(products))
    if host is not None:
        value = value.replace('__TESTHOST__', str(host))
    require('__' not in value, 'Unsupported product path placeholder')
    path = Path(value)
    return _under_products(path if path.is_absolute() else products / path, products)


def _snapshot(products, config):
    target = _target(config)
    runner = _product_path(target.get('TestHostPath'), products)
    paths = {'application': _product_path(target.get('UITargetAppPath'), products),
             'runner': runner, 'xctest': _product_path(target.get('TestBundlePath'), products, runner)}
    require(paths['application'].name == 'Telemetry.app' and runner.name == 'TelemetryUITests-Runner.app'
            and paths['xctest'].parent == runner / 'PlugIns'
            and paths['xctest'].name == 'TelemetryUITests.xctest', 'Unexpected final Help product roles')
    values = {}
    for role, bundle in paths.items():
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        executable = info.get('CFBundleExecutable')
        require(isinstance(executable, str) and Path(executable).name == executable, 'Invalid product executable')
        binary = bundle / executable
        require(binary.is_file() and not binary.is_symlink(), 'Missing final product executable')
        bundle_sha, count = tree_digest(bundle)
        values[role] = {'path': bundle.relative_to(products).as_posix(), 'executable': executable,
                        'executableSHA256': sha256(binary.read_bytes()), 'bundleSHA256': bundle_sha, 'fileCount': count}
    return values


def prepare_run(products, source_receipt, simulator):
    """After build-for-testing, before install/test. No native command or data access."""
    products = Path(products).resolve()
    _source_receipt(source_receipt)
    canonical_uuid(simulator)
    paths = list(products.glob('*.xctestrun'))
    require(len(paths) == 1 and not paths[0].is_symlink(), 'Exactly one generated xctestrun required')
    path = paths[0]
    config = plistlib.loads(path.read_bytes())
    inventory = _snapshot(products, config)
    context = {'schemaVersion': 1, 'scope': 'same-run-help-products-and-captures',
               'runID': str(uuid.uuid4()).upper(), 'simulatorUUID': simulator,
               'sourceReceipt': copy.deepcopy(source_receipt), 'sourceReceiptSHA256': object_digest(source_receipt),
               'productsBefore': inventory, 'productsSHA256': object_digest(inventory),
               'xctestrun': path.relative_to(products).as_posix(), 'startedAt': time.time(),
               'testMode': 'test-without-building', 'captureCertified': False, 'visualReviewRequired': True}
    target = _target(config)
    environment = target.setdefault('EnvironmentVariables', {})
    require(isinstance(environment, dict), 'Invalid test environment')
    environment.update(HELP_CAPTURE_RUN_ID=context['runID'], HELP_CAPTURE_PRODUCTS_SHA256=context['productsSHA256'],
                       HELP_CAPTURE_SOURCE_SHA256=context['sourceReceiptSHA256'], HELP_CAPTURE_SIMULATOR_UUID=simulator)
    path.write_bytes(plistlib.dumps(config))
    context['xctestrunSHA256Before'] = sha256(path.read_bytes())
    return context


def _unchanged_products(products, context):
    path = _under_products(Path(products) / context['xctestrun'], Path(products))
    current_sha = sha256(path.read_bytes())
    require(current_sha == context['xctestrunSHA256Before'], 'xctestrun changed after capture preparation')
    inventory = _snapshot(Path(products), plistlib.loads(path.read_bytes()))
    require(inventory == context['productsBefore'], 'Final product changed/rebuilt after capture preparation')
    return inventory, current_sha


def test_command(products, context, bundle, selected_tests):
    _unchanged_products(products, context)
    return ['xcodebuild', 'test-without-building', '-xctestrun', str(Path(products) / context['xctestrun']),
            '-destination', 'platform=iOS Simulator,id=' + context['simulatorUUID'],
            '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
            '-resultBundlePath', str(bundle)] + selected_tests


def _expected_test(name):
    return 'LocalizationHelpUITests/testCapture' + ('Korean' if '-ko-' in name else 'English') + 'GuideScreens()'


def _verify_receipt(receipt, context, name, target):
    require(isinstance(receipt, dict) and receipt.get('schemaVersion') == 1, 'Missing capture receipt')
    for key in ('runID', 'productsSHA256', 'sourceReceiptSHA256', 'simulatorUUID'):
        require(receipt.get(key) == context.get(key) and key in context, 'Mixed capture execution: ' + key)
    require(receipt.get('screen') == name and receipt.get('targetID') == target
            and receipt.get('test') == _expected_test(name) and receipt.get('fixture') == 'synthetic-offline',
            'Capture test/target receipt mismatch: ' + name)
    require(valid_digest(receipt.get('sha256')) and valid_digest(receipt.get('markerSHA256')), 'Missing capture byte digests')
    stamp = receipt.get('timestamp')
    require(type(stamp) in (int, float) and context['startedAt'] <= stamp <= context['completedAt'],
            'Capture timestamp outside this execution')


def _collect_receipts(exported, context, targets):
    manifest = json.loads((exported / 'manifest.json').read_text())
    require(isinstance(manifest, list), 'Missing attachment export manifest')
    tests, found = set(), {}
    pattern = re.compile(r'^(Help-[a-z]+-(?:en|ko)-[0-9]+)(-markers|-capture-receipt)?_[0-9]+_.+\.(png|json)$')
    expected_tests = {_expected_test(name) for name in targets}
    for row in manifest:
        test = row.get('testIdentifier')
        if test not in expected_tests:
            continue
        require(test not in tests, 'Duplicate capture test execution')
        tests.add(test)
        for item in row['attachments']:
            match = pattern.fullmatch(item.get('suggestedHumanReadableName', ''))
            if match is None:
                continue
            name, suffix, extension = match.groups()
            require(name in targets and test == _expected_test(name), 'Unexpected capture attachment test/name')
            require(item.get('deviceId') == context['simulatorUUID'] and item.get('isAssociatedWithFailure') is False,
                    'Failed attachment or mixed capture device')
            role = {'-markers': 'marker', '-capture-receipt': 'receipt', None: 'png'}[suffix]
            require(extension == ('png' if role == 'png' else 'json'), 'Invalid capture attachment type')
            filename = item.get('exportedFileName')
            require(isinstance(filename, str) and Path(filename).name == filename and bool(filename), 'Escaping attachment filename')
            path = exported / filename
            require(path.is_file() and not path.is_symlink(), 'Missing capture attachment bytes')
            entries = found.setdefault(name, {})
            require(role not in entries, 'Duplicate capture attachment')
            entries[role] = path.read_bytes()
    require(tests == expected_tests and set(found) == set(targets), 'Missing capture tests/screens')
    captures = {}
    for name, parts in found.items():
        require(set(parts) == {'png', 'marker', 'receipt'}, 'Missing image/marker/capture receipt: ' + name)
        receipt = json.loads(parts['receipt'])
        _verify_receipt(receipt, context, name, targets[name])
        require(sha256(parts['png']) == receipt['sha256'] and sha256(parts['marker']) == receipt['markerSHA256'],
                'Capture attachment byte digest mismatch: ' + name)
        require(parts['png'].startswith(b'\x89PNG\r\n\x1a\n'), 'Invalid capture PNG')
        markers = json.loads(parts['marker'])
        require(isinstance(markers, list) and len(markers) == 1 and isinstance(markers[0], dict)
                and markers[0].get('number') == int(name.rsplit('-', 1)[1])
                and all(type(markers[0].get(key)) in (int, float) and 0 <= markers[0][key] <= 1 for key in ('x', 'y')),
                'Invalid capture marker')
        captures[name] = receipt
    return captures


def finish_run(products, before, source_after, exported, bundle, targets):
    """Fail closed on rebuild/source drift or missing/mixed XCTest receipts."""
    context = copy.deepcopy(before)
    after = dict(source_after)
    require(after.pop('sourceStableDuringRun', None) is True and after == context['sourceReceipt'],
            'Source/test inputs changed during capture')
    context['productsAfter'], context['xctestrunSHA256After'] = _unchanged_products(products, context)
    context['completedAt'] = time.time()
    context['resultBundleSHA256'] = tree_digest(Path(bundle))[0]
    context['exportManifestSHA256'] = sha256((Path(exported) / 'manifest.json').read_bytes())
    context['captures'] = _collect_receipts(Path(exported), context, targets)
    verify_capture_run(context, context['captures'], source_after['sourceInputs'], targets, source_after['captureTestSHA256'])
    return context


def verify_capture_run(run, screens, source_inputs, targets, capture_test_sha256):
    """Validate bundled evidence without touching products, devices, or assets."""
    require(isinstance(run, dict) and run.get('schemaVersion') == 1
            and run.get('scope') == 'same-run-help-products-and-captures'
            and run.get('testMode') == 'test-without-building'
            and run.get('captureCertified') is False and run.get('visualReviewRequired') is True,
            'Missing same-run final product/capture evidence')
    canonical_uuid(run.get('runID')); canonical_uuid(run.get('simulatorUUID'))
    source = run.get('sourceReceipt')
    _source_receipt(source)
    require(source['sourceInputs'] == source_inputs and source['captureTestSHA256'] == capture_test_sha256
            and run.get('sourceReceiptSHA256') == object_digest(source), 'Capture source/test receipt mismatch')
    before, after = run.get('productsBefore'), run.get('productsAfter')
    require(isinstance(before, dict) and set(before) == {'application', 'xctest', 'runner'}
            and before == after and run.get('productsSHA256') == object_digest(before), 'Missing/mixed/rebuilt final products')
    for product in before.values():
        require(isinstance(product, dict) and valid_digest(product.get('executableSHA256'))
                and valid_digest(product.get('bundleSHA256')) and type(product.get('fileCount')) is int
                and product['fileCount'] > 0 and isinstance(product.get('path'), str)
                and isinstance(product.get('executable'), str), 'Incomplete final product digest')
    require(valid_digest(run.get('xctestrunSHA256Before')) and run.get('xctestrunSHA256Before') == run.get('xctestrunSHA256After')
            and valid_digest(run.get('resultBundleSHA256')) and valid_digest(run.get('exportManifestSHA256')),
            'Missing/changed execution or xcresult digest')
    require(type(run.get('startedAt')) in (int, float) and type(run.get('completedAt')) in (int, float)
            and run['completedAt'] >= run['startedAt'], 'Missing capture execution interval')
    captures = run.get('captures')
    require(isinstance(captures, dict) and set(captures) == set(targets) == set(screens), 'Missing capture receipts')
    for name, target in targets.items():
        receipt = captures[name]
        _verify_receipt(receipt, run, name, target)
        for key in ('sha256', 'markerSHA256', 'targetID', 'fixture', 'simulatorUUID', 'timestamp', 'test'):
            require(screens[name].get(key) == receipt[key], 'Manifest/capture receipt mismatch: ' + name + ':' + key)
