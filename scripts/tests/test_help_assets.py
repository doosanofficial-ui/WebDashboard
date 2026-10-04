import importlib.util, json, shutil, tempfile, unittest
from pathlib import Path

spec=importlib.util.spec_from_file_location("help_assets",Path(__file__).resolve().parents[1]/"verify_help_assets.py")
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class HelpAssetGateTests(unittest.TestCase):
    def test_bundled_captures_and_provenance_are_complete(self):
        module.verify(Path(__file__).resolve().parents[2])
    def test_gate_rejects_image_marker_and_source_drift(self):
        root=Path(__file__).resolve().parents[2]
        manifest=json.loads((root/'mobile-ios/App/Resources/HelpScreenshots/manifest.json').read_text())
        for kind in ['image','marker','source','receipt']:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as directory:
                target=Path(directory)
                shutil.copytree(root/'mobile-ios/App',target/'mobile-ios/App')
                name=next(iter(manifest['screens']))
                if kind=='image': path=target/'mobile-ios/App/Resources/HelpScreenshots'/(name+'.png')
                elif kind=='marker': path=target/'mobile-ios/App/Resources/HelpScreenshots'/(name+'.json')
                elif kind=='source': path=target/next(iter(manifest['screenInputs']))
                else: path=target/'mobile-ios/App/Resources/HelpScreenshots/manifest.json'
                if kind=='receipt':
                    bad=json.loads(path.read_text());bad['captureSummary']['failed']=1;path.write_text(json.dumps(bad))
                else:path.write_bytes(path.read_bytes()+b' ')
                with self.assertRaises(AssertionError):module.verify(target)

    def test_source_line_endings_are_portable_without_changing_image_bytes(self):
        root=Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)
            shutil.copytree(root/'mobile-ios/App',target/'mobile-ios/App')
            manifest=json.loads((target/'mobile-ios/App/Resources/HelpScreenshots/manifest.json').read_text())
            for path in manifest['screenInputs']:
                source=target/path;source.write_bytes(source.read_bytes().replace(b'\n',b'\r\n'))
            module.verify(target)
