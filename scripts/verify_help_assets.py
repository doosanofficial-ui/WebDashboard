#!/usr/bin/env python3
"""Fail closed when bundled actual guide captures or their source provenance drift."""
import hashlib,json,re
from pathlib import Path

def verify(root):
    directory=root/'mobile-ios/App/Resources/HelpScreenshots'
    manifest=json.loads((directory/'manifest.json').read_text())
    assert manifest['captureSummary']=={'passed':2,'failed':0,'skipped':0},'Capture success receipt required'
    guide_source=(root/'mobile-ios/App/AppHelpView.swift').read_text(encoding='utf-8')
    guides=list(re.finditer(r'\.init\(id:\s*"(\w+)",\s*title:',guide_source))
    expected={}
    for index,guide in enumerate(guides):
        block=guide_source[guide.end():guides[index+1].start() if index+1<len(guides) else guide_source.index('struct AppHelpView:')]
        for target,number in re.findall(r'\.init\(id:\s*"([^"\n]+)",\s*number:\s*(\d+)',block):
            for language in ['ko','en']:expected[f'Help-{guide.group(1)}-{language}-{number}']=target
    assert len(expected)==28,'Guide step contract changed; update captures and tests together'
    assert set(manifest['screens'])==set(expected),'Missing, extra or duplicate actual capture'
    expected_inputs={p.relative_to(root).as_posix() for p in (root/'mobile-ios/App').glob('*.swift') if p.name!='AppHelpView.swift'}
    expected_inputs|={p.relative_to(root).as_posix() for p in (root/'mobile-ios/App/Resources').glob('*.json')}
    expected_inputs|={p.relative_to(root).as_posix() for p in (root/'mobile-ios/App/Resources').glob('*.lproj/*.strings')}
    assert set(manifest['screenInputs'])==expected_inputs,'Incomplete source provenance'
    for path,digest in manifest['screenInputs'].items():
        assert hashlib.sha256((root/path).read_bytes().replace(b'\r\n',b'\n')).hexdigest()==digest,f'Guided screen changed; regenerate actual screenshots: {path}'
    for name,receipt in manifest['screens'].items():
        image=directory/(name+'.png');markers=directory/(name+'.json')
        assert receipt['targetID']==expected[name],f'Guide target changed: {name}'
        assert image.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'),'Actual PNG required'
        assert hashlib.sha256(markers.read_bytes()).hexdigest()==receipt['markerSHA256'],f'Number position changed: {name}'
        assert hashlib.sha256(image.read_bytes()).hexdigest()==receipt['sha256'],f'Capture changed: {name}'
        points=json.loads(markers.read_text())
        assert len(points)==1 and points[0]['number']==int(name.rsplit('-',1)[-1]),'Number must match guide step'
        assert all(0<=points[0][axis]<=1 for axis in ['x','y']),'Marker is outside screenshot'
        assert receipt['fixture']=='synthetic-offline' and receipt['simulatorUUID'],'Synthetic capture provenance required'
        language=name.split('-')[-2]
        expected_test='LocalizationHelpUITests/testCapture'+('Korean' if language=='ko' else 'English')+'GuideScreens()'
        assert receipt['test']==expected_test and receipt['timestamp']>0,'Language capture receipt required'
    print('APP HELP CAPTURES PASS:28 actual ko/en step images; source/bytes/anchors/provenance match')

if __name__=='__main__':verify(Path(__file__).resolve().parents[1])
