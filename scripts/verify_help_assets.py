#!/usr/bin/env python3
"""Fail closed when bundled actual guide captures or their source provenance drift."""
import argparse,hashlib,json,re
from pathlib import Path

def require(condition, message):
    """Evidence checks must remain active under -O and PYTHONOPTIMIZE."""
    if not condition:
        raise AssertionError(message)

def expected_capture_targets(guide_source):
    guides=list(re.finditer(r'\.init\(id:\s*"(\w+)",\s*title:',guide_source))
    guide_ids=[guide.group(1) for guide in guides]
    require(len(guide_ids)==len(set(guide_ids)), 'Duplicate guide ID')
    expected={}
    for index,guide in enumerate(guides):
        block=guide_source[guide.end():guides[index+1].start() if index+1<len(guides) else guide_source.index('struct AppHelpView:')]
        steps=re.findall(r'\.init\(id:\s*"([^"\n]+)",\s*number:\s*(\d+)',block)
        require(steps and [int(number) for _,number in steps]==list(range(1,len(steps)+1)),
                f'Guide step numbers must match display order: {guide.group(1)}')
        for target,number in steps:
            for language in ['ko','en']:expected[f'Help-{guide.group(1)}-{language}-{number}']=target
    require(len(expected)==28,'Guide step contract changed; update captures and tests together')
    return expected

def _screen_source_paths(app):
    """One recursive rule for repository and physically staged App sources."""
    paths={p for p in app.rglob('*.swift') if p!=app/'AppHelpView.swift'}
    resources=app/'Resources'
    paths|={p for p in resources.rglob('*') if p.is_file() and p.suffix in {'.json','.strings'}
            and p.relative_to(resources).parts[0]!='HelpScreenshots'}
    return {'mobile-ios/App/'+p.relative_to(app).as_posix():p for p in paths}


def expected_screen_inputs(root):
    """AppHelpView targets are separate; generated Help assets are not inputs."""
    return set(_screen_source_paths(Path(root)/'mobile-ios/App'))


def staged_source_input_hashes(mobile_ios_root):
    paths=_screen_source_paths(Path(mobile_ios_root)/'App')
    return {relative:hashlib.sha256(paths[relative].read_bytes().replace(b'\r\n',b'\n')).hexdigest()
            for relative in sorted(paths)}


def source_input_hashes(root):
    """Canonical inventory for both capture-time source collection and checks."""
    return staged_source_input_hashes(Path(root)/'mobile-ios')


def audit_source_provenance(root):
    """Compare source inputs without modifying assets or certifying a capture run."""
    root=Path(root)
    directory=root/'mobile-ios/App/Resources/HelpScreenshots'
    manifest=json.loads((directory/'manifest.json').read_text())
    recorded=manifest['screenInputs']
    expected=expected_screen_inputs(root)
    current=source_input_hashes(root)
    missing=sorted(expected-set(recorded))
    extra=sorted(set(recorded)-expected)
    stale=sorted(relative for relative in expected & set(recorded)
                 if current[relative]!=recorded[relative])
    targets=expected_capture_targets((root/'mobile-ios/App/AppHelpView.swift').read_text(encoding='utf-8'))
    return {
        'schemaVersion':1,
        'scope':'source-input-audit-only',
        'sourceInputsMatch':not (missing or extra or stale),
        'fullAssetVerificationPerformed':False,
        'assetFilesModified':False,
        'expectedSourceInputCount':len(expected),
        'recordedSourceInputCount':len(recorded),
        'missingSourceInputs':missing,
        'extraSourceInputs':extra,
        'staleSourceInputs':stale,
        'currentSourceInputs':current,
        'expectedCaptureTargets':targets,
    }


def verify(root):
    directory=root/'mobile-ios/App/Resources/HelpScreenshots'
    manifest=json.loads((directory/'manifest.json').read_text())
    require(manifest['captureSummary']=={'passed':2,'failed':0,'skipped':0},'Capture success receipt required')
    expected=expected_capture_targets((root/'mobile-ios/App/AppHelpView.swift').read_text(encoding='utf-8'))
    require(set(manifest['screens'])==set(expected),'Missing, extra or duplicate actual capture')
    expected_inputs=expected_screen_inputs(root)
    require(set(manifest['screenInputs'])==expected_inputs,'Incomplete source provenance')
    current=source_input_hashes(root)
    for path,digest in manifest['screenInputs'].items():
        require(current[path]==digest,f'Guided screen changed; regenerate actual screenshots: {path}')
    for name,receipt in manifest['screens'].items():
        image=directory/(name+'.png');markers=directory/(name+'.json')
        require(receipt['targetID']==expected[name],f'Guide target changed: {name}')
        require(image.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'),'Actual PNG required')
        require(hashlib.sha256(markers.read_bytes()).hexdigest()==receipt['markerSHA256'],f'Number position changed: {name}')
        require(hashlib.sha256(image.read_bytes()).hexdigest()==receipt['sha256'],f'Capture changed: {name}')
        points=json.loads(markers.read_text())
        require(len(points)==1 and points[0]['number']==int(name.rsplit('-',1)[-1]),'Number must match guide step')
        require(all(0<=points[0][axis]<=1 for axis in ['x','y']),'Marker is outside screenshot')
        require(receipt['fixture']=='synthetic-offline' and receipt['simulatorUUID'],'Synthetic capture provenance required')
        language=name.split('-')[-2]
        expected_test='LocalizationHelpUITests/testCapture'+('Korean' if language=='ko' else 'English')+'GuideScreens()'
        require(receipt['test']==expected_test and receipt['timestamp']>0,'Language capture receipt required')
    # Imported only by the complete gate; --audit-source remains source-only.
    from help_capture_provenance import verify_capture_run
    capture_test=root/'mobile-ios/UITests/LocalizationHelpUITests.swift'
    require(capture_test.is_file(),'Capture test source required for same-run evidence')
    capture_test_hash=hashlib.sha256(capture_test.read_bytes().replace(b'\r\n',b'\n')).hexdigest()
    try:
        verify_capture_run(manifest.get('captureRun'),manifest['screens'],current,expected,capture_test_hash)
    except ValueError as error:
        require(False,str(error))
    print('APP HELP CAPTURES PASS:28 ko/en images; source/bytes/anchors and same-run product receipts match')

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-source',action='store_true',
                        help='Print a read-only source-input comparison; this does not verify captures')
    args=parser.parse_args(argv)
    root=Path(__file__).resolve().parents[1]
    if args.audit_source:
        report=audit_source_provenance(root)
        print(json.dumps(report,indent=2,sort_keys=True))
        return 0 if report['sourceInputsMatch'] else 1
    verify(root)
    return 0

if __name__=='__main__':raise SystemExit(main())
