import hashlib, importlib.util, json, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

spec=importlib.util.spec_from_file_location("help_assets",Path(__file__).resolve().parents[1]/"verify_help_assets.py")
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

def byte_validation_fixture(root,target):
    """Create a valid unit fixture; never rewrite bundled capture provenance."""
    shutil.copytree(root/'mobile-ios/App',target/'mobile-ios/App')
    app=target/'mobile-ios/App'
    path=app/'Resources/HelpScreenshots/manifest.json'
    manifest=json.loads(path.read_text())
    manifest['screenInputs']={
        relative:hashlib.sha256((target/relative).read_bytes().replace(b'\r\n',b'\n')).hexdigest()
        for relative in module.expected_screen_inputs(target)
    }
    manifest['unitFixtureScope']='Byte-validation unit fixture only; not native capture or release evidence'
    path.write_text(json.dumps(manifest))
    return manifest

class HelpAssetGateTests(unittest.TestCase):
    def test_optimized_interpreter_still_rejects_missing_capture_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)
            byte_validation_fixture(Path(__file__).resolve().parents[2],target)
            path=target/'mobile-ios/App/Resources/HelpScreenshots/manifest.json'
            bad=json.loads(path.read_text());bad['captureSummary']['failed']=1
            path.write_text(json.dumps(bad))
            command=[sys.executable,'-B','-O','-c',
                     'import runpy,sys; from pathlib import Path; '
                     'runpy.run_path(sys.argv[1])["verify"](Path(sys.argv[2]))',
                     str(Path(module.__file__).resolve()),str(target)]
            result=subprocess.run(command,capture_output=True,text=True,timeout=10)
            self.assertNotEqual(result.returncode,0,'Optimized Python accepted invalid capture evidence')
            self.assertIn('Capture success receipt required',result.stderr)
            self.assertNotIn('APP HELP CAPTURES PASS',result.stdout)

    def test_new_and_nested_app_sources_cannot_be_omitted(self):
        root=Path(__file__).resolve().parents[2]
        for relative in ['mobile-ios/App/NewScreen.swift',
                         'mobile-ios/App/CarPlay/NewProjection.swift',
                         'mobile-ios/App/Resources/Nested/new-input.json',
                         'mobile-ios/App/Resources/es.lproj/Localizable.strings']:
            with self.subTest(path=relative),tempfile.TemporaryDirectory() as directory:
                target=Path(directory);byte_validation_fixture(root,target)
                module.verify(target)
                added=target/relative;added.parent.mkdir(parents=True,exist_ok=True)
                added.write_text('{}')
                with self.assertRaisesRegex(AssertionError,'Incomplete source provenance'):
                    module.verify(target)

    def test_guide_order_and_duplicate_ids_cannot_select_wrong_capture(self):
        root=Path(__file__).resolve().parents[2]
        for kind in ['reordered_steps','duplicate_step','duplicate_guide']:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as directory:
                target=Path(directory);byte_validation_fixture(root,target)
                module.verify(target)
                path=target/'mobile-ios/App/AppHelpView.swift'
                lines=path.read_text().splitlines(keepends=True)
                first=next(i for i,line in enumerate(lines) if '.init(id:"toggle-recording"' in line)
                second=next(i for i,line in enumerate(lines) if '.init(id:"toggle-gps"' in line)
                if kind=='reordered_steps':lines[first],lines[second]=lines[second],lines[first]
                elif kind=='duplicate_step':lines.insert(second,lines[second])
                else:
                    start=next(i for i,line in enumerate(lines) if '.init(id: "setup", title:' in line)
                    end=next(i for i,line in enumerate(lines) if '.init(id:"live",title:' in line)
                    lines[end:end]=lines[start:end]
                path.write_text(''.join(lines))
                message='Duplicate guide ID' if kind=='duplicate_guide' else 'Guide step numbers must match display order'
                with self.assertRaisesRegex(AssertionError,message):module.verify(target)

    def test_bundled_captures_and_provenance_are_complete(self):
        module.verify(Path(__file__).resolve().parents[2])
    def test_gate_rejects_image_marker_and_source_drift(self):
        root=Path(__file__).resolve().parents[2]
        for kind in ['image','marker','source','receipt']:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as directory:
                target=Path(directory)
                manifest=byte_validation_fixture(root,target)
                module.verify(target)
                name=next(iter(manifest['screens']))
                if kind=='image': path=target/'mobile-ios/App/Resources/HelpScreenshots'/(name+'.png')
                elif kind=='marker': path=target/'mobile-ios/App/Resources/HelpScreenshots'/(name+'.json')
                elif kind=='source': path=target/next(iter(manifest['screenInputs']))
                else: path=target/'mobile-ios/App/Resources/HelpScreenshots/manifest.json'
                if kind=='receipt':
                    bad=json.loads(path.read_text());bad['captureSummary']['failed']=1;path.write_text(json.dumps(bad))
                else:path.write_bytes(path.read_bytes()+b' ')
                expected_errors = {
                    'image': 'Capture changed',
                    'marker': 'Number position changed',
                    'source': 'Guided screen changed',
                    'receipt': 'Capture success receipt required',
                }
                with self.assertRaisesRegex(AssertionError,expected_errors[kind]):module.verify(target)

    def test_source_line_endings_are_portable_without_changing_image_bytes(self):
        root=Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)
            manifest=byte_validation_fixture(root,target)
            module.verify(target)
            for path in manifest['screenInputs']:
                source=target/path;source.write_bytes(source.read_bytes().replace(b'\r\n',b'\n').replace(b'\n',b'\r\n'))
            module.verify(target)


def source_audit_fixture(target):
    root=Path(__file__).resolve().parents[2]
    app=target/'mobile-ios/App'
    (app/'CarPlay').mkdir(parents=True)
    (app/'Resources/en.lproj').mkdir(parents=True)
    (app/'Resources/HelpScreenshots').mkdir()
    shutil.copyfile(root/'mobile-ios/App/AppHelpView.swift',app/'AppHelpView.swift')
    (app/'Screen.swift').write_bytes(b'first\nsecond\n')
    (app/'CarPlay/Projection.swift').write_bytes(b'projection\n')
    (app/'Resources/en.lproj/Localizable.strings').write_bytes(b'"Example" = "Example";\n')
    inputs={p:hashlib.sha256((target/p).read_bytes()).hexdigest()
            for p in module.expected_screen_inputs(target)}
    manifest=app/'Resources/HelpScreenshots/manifest.json'
    manifest.write_text(json.dumps({'screenInputs':inputs}))
    return manifest


class HelpSourceAuditTests(unittest.TestCase):
    def test_source_match_is_not_claimed_as_full_asset_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory);manifest=source_audit_fixture(target)
            before=manifest.read_bytes()
            report=module.audit_source_provenance(target)
            self.assertTrue(report['sourceInputsMatch'])
            self.assertFalse(report['fullAssetVerificationPerformed'])
            self.assertFalse(report['assetFilesModified'])
            self.assertEqual(report['expectedSourceInputCount'],3)
            self.assertEqual(len(report['expectedCaptureTargets']),28)
            self.assertEqual(report['expectedCaptureTargets']['Help-live-ko-2'],'toggle-gps')
            self.assertEqual(report['expectedCaptureTargets']['Help-editor-en-1'],
                             'resize-dashboard-widget-fixture-0')
            self.assertEqual(manifest.read_bytes(),before)
            self.assertFalse(list(manifest.parent.glob('*.png')))

    def test_missing_extra_and_stale_inputs_are_reported_together_without_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory);path=source_audit_fixture(target)
            manifest=json.loads(path.read_text())
            missing='mobile-ios/App/CarPlay/Projection.swift'
            del manifest['screenInputs'][missing]
            extra='../outside-capture-scope.swift'
            manifest['screenInputs'][extra]='not-a-current-input'
            path.write_text(json.dumps(manifest))
            (target/'mobile-ios/App/Screen.swift').write_bytes(b'changed\n')
            before={str(p.relative_to(target)):p.read_bytes()
                    for p in target.rglob('*') if p.is_file()}
            report=module.audit_source_provenance(target)
            self.assertFalse(report['sourceInputsMatch'])
            self.assertEqual(report['missingSourceInputs'],[missing])
            self.assertEqual(report['extraSourceInputs'],[extra])
            self.assertEqual(report['staleSourceInputs'],['mobile-ios/App/Screen.swift'])
            self.assertEqual(report['recordedSourceInputCount'],3)
            self.assertEqual({str(p.relative_to(target)):p.read_bytes()
                              for p in target.rglob('*') if p.is_file()},before)

    def test_source_audit_normalizes_line_endings_without_rewriting_files(self):
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory);source_audit_fixture(target)
            path=target/'mobile-ios/App/Screen.swift'
            path.write_bytes(b'first\r\nsecond\r\n')
            report=module.audit_source_provenance(target)
            self.assertTrue(report['sourceInputsMatch'])
            self.assertEqual(path.read_bytes(),b'first\r\nsecond\r\n')

    def test_optimized_cli_audit_reports_drift_and_never_prints_asset_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory);source_audit_fixture(target)
            scripts=target/'scripts';scripts.mkdir()
            driver=scripts/'verify_help_assets.py';shutil.copyfile(module.__file__,driver)
            (target/'mobile-ios/App/CarPlay/NewProjection.swift').write_text('new source')
            result=subprocess.run([sys.executable,'-B','-O',str(driver),'--audit-source'],
                                  capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,1,result.stderr)
            report=json.loads(result.stdout)
            self.assertEqual(report['missingSourceInputs'],
                             ['mobile-ios/App/CarPlay/NewProjection.swift'])
            self.assertFalse(report['fullAssetVerificationPerformed'])
            self.assertNotIn('APP HELP CAPTURES PASS',result.stdout)
            self.assertEqual(result.stderr,'')
