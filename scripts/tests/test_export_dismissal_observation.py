import json
import hashlib
from pathlib import Path
import sys
import tempfile
import subprocess
import unittest
from unittest.mock import patch, Mock
from contextlib import ExitStack

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import export_dismissal_observation as audit
import export_dismissal_fixture as fixture
import verify_offline_replay as runner


class ExportObservationTests(unittest.TestCase):
    def test_collector_copies_only_bounded_regular_trace_and_does_not_follow_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            container = root / 'owned'; results = root / 'results'; results.mkdir()
            target = audit.audit_directory(container); target.mkdir(parents=True)
            run_id = '11111111-1111-4111-8111-111111111111'
            (target / audit.MARKER_NAME).write_text(json.dumps({'scope': 'qualified-synthetic-fixture', 'runID': run_id}))
            trace = target / audit.TRACE_NAME
            trace.write_text(json.dumps({'runID': run_id, 'ownerID': run_id, 'sequence': 1,
                'event': 'presented', 'presented': True, 'uptime': 1, 'epoch': 1}) + '\n')
            audit.collect_trace(container, results)
            self.assertEqual((results / audit.TRACE_NAME).read_bytes(), trace.read_bytes())
            (results / audit.TRACE_NAME).unlink(); trace.unlink()
            foreign = root / 'foreign'; foreign.write_text('private-user-data')
            trace.symlink_to(foreign)
            audit.collect_trace(container, results)
            self.assertFalse((results / audit.TRACE_NAME).exists())
            trace.unlink(); trace.write_bytes(b'x' * (audit.MAX_BYTES + 1))
            audit.collect_trace(container, results)
            self.assertFalse((results / audit.TRACE_NAME).exists())

    def test_optional_collection_failure_preserves_original_test_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            primary = RuntimeError('original UI assertion')
            with patch.object(Path, 'write_text', side_effect=OSError('diagnostic failure')):
                with self.assertRaises(RuntimeError) as caught:
                    try:
                        raise primary
                    finally:
                        audit.collect_trace(Path(directory), Path(directory))
            self.assertIs(caught.exception, primary)

    def test_heartbeat_observation_error_does_not_replace_test_error_or_launch_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            primary = RuntimeError('original UI verdict')
            with patch.object(audit.os, 'getloadavg', side_effect=OSError('unsupported')), \
                    patch.object(subprocess, 'Popen', side_effect=AssertionError('no external process')):
                with self.assertRaises(RuntimeError) as caught:
                    with audit.RunnerHeartbeat(Path(directory) / 'runner-heartbeat.json', interval=0.01):
                        raise primary
            self.assertIs(caught.exception, primary)
            record = json.loads((Path(directory) / 'runner-heartbeat.json').read_text())
            self.assertTrue(record['samples'])
            self.assertIn('observationErrorType', record['samples'][0])

    def test_marker_is_explicit_synthetic_run_and_never_rewrites_existing_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            container = Path(directory)
            audit.install_marker(container, 'a' * 40)
            marker = audit.audit_directory(container) / audit.MARKER_NAME
            value = json.loads(marker.read_text())
            self.assertEqual(value['scope'], 'qualified-synthetic-fixture')
            self.assertEqual(value['commit'], 'a' * 40)
            before = marker.read_bytes()
            with self.assertRaises(FileExistsError): audit.install_marker(container, 'b' * 40)
            self.assertEqual(marker.read_bytes(), before)


    def test_duplicate_secret_fields_and_wrong_run_are_never_copied(self):
        with tempfile.TemporaryDirectory() as directory:
            container = Path(directory) / 'owned'; results = Path(directory) / 'results'; results.mkdir()
            audit.install_marker(container, 'a' * 40)
            target = audit.audit_directory(container)
            run_id = json.loads((target / audit.MARKER_NAME).read_text())['runID']
            row = {'runID': run_id, 'ownerID': run_id, 'sequence': 1, 'event': 'begin', 'presented': False, 'uptime': 1, 'epoch': 1}
            for value in [json.dumps(row).replace('"event": "begin"', '"event":"PRIVATE_SECRET", "event":"begin"'),
                          json.dumps({**row, 'runID': '22222222-2222-4222-8222-222222222222'}),
                          json.dumps({**row, 'payload': 'PRIVATE_SECRET'}),
                          json.dumps({**row, 'epoch': float('nan')})]:
                with self.subTest(value=value):
                    (target / audit.TRACE_NAME).write_text(value+'\n')
                    audit.collect_trace(container, results)
                    self.assertFalse((results / audit.TRACE_NAME).exists())
                    self.assertNotIn('PRIVATE_SECRET', (results / 'export-audit-collection.json').read_text())


    def test_owned_collection_resolves_post_update_container_and_rejects_foreign_or_timed_out_resolution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); results = root/'results'; results.mkdir()
            device = '11111111-1111-4111-8111-111111111111'
            container = root/'Devices'/device/'data/Containers/Data/Application/22222222-2222-4222-8222-222222222222'
            audit.install_marker(container, 'a'*40)
            target = audit.audit_directory(container)
            run_id = json.loads((target/audit.MARKER_NAME).read_text())['runID']
            row = {'runID':run_id,'ownerID':run_id,'sequence':1,'event':'begin','presented':False,'uptime':1,'epoch':1}
            (target/audit.TRACE_NAME).write_text(json.dumps(row)+'\n')
            expected = ['xcrun','simctl','get_app_container',device,'local.webdashboard.Telemetry','data']
            with patch.object(audit.subprocess, 'run', return_value=subprocess.CompletedProcess(expected,0,str(container)+'\n')) as query:
                audit.collect_owned_trace(device,results)
            self.assertEqual(query.call_args.args[0],expected)
            self.assertEqual(query.call_args.kwargs['timeout'],2)
            self.assertEqual(json.loads((results/'export-audit-collection.json').read_text())['status'],'collected')
            (results/audit.TRACE_NAME).unlink()
            foreign = str(container).replace(device,'33333333-3333-4333-8333-333333333333')
            for response in [subprocess.CompletedProcess(expected,0,foreign),subprocess.CompletedProcess(expected,0,str(container).replace('/Containers/','/Other/')),subprocess.TimeoutExpired(expected,2,output='PRIVATE_SECRET')]:
                with self.subTest(response=type(response).__name__):
                    options = {'side_effect':response} if isinstance(response,Exception) else {'return_value':response}
                    with patch.object(audit.subprocess,'run',**options), patch.object(audit,'bounded_regular') as read:
                        audit.collect_owned_trace(device,results)
                    read.assert_not_called()
                    receipt = (results/'export-audit-collection.json').read_text()
                    self.assertEqual(json.loads(receipt)['collectionStage'],'container-resolution')
                    self.assertNotIn('PRIVATE_SECRET',receipt)
                    self.assertFalse((results/audit.TRACE_NAME).exists())

    def test_missing_admission_and_trace_have_distinct_collection_stages(self):
        with tempfile.TemporaryDirectory() as directory:
            container=Path(directory)/'owned';results=Path(directory)/'results';results.mkdir()
            audit.collect_trace(container,results)
            self.assertEqual(json.loads((results/'export-audit-collection.json').read_text())['collectionStage'],'admission-read')
            audit.install_marker(container,'a'*40)
            audit.collect_trace(container,results)
            self.assertEqual(json.loads((results/'export-audit-collection.json').read_text())['collectionStage'],'trace-read')
            self.assertFalse((results/audit.TRACE_NAME).exists())

    def test_fixture_transform_preserves_production_source_and_rejects_source_boundary_drift(self):
        root = Path(__file__).resolve().parents[2]
        originals = {name:(root/'mobile-ios'/name).read_bytes() for name in ['App/MeasurementExportRequest.swift','App/SessionsView.swift']}
        with tempfile.TemporaryDirectory() as directory:
            staged = Path(directory); (staged/'App').mkdir()
            for name,data in originals.items(): (staged/name).write_bytes(data)
            receipt = fixture.instrument_export_sources(root,staged)
            for name,data in originals.items():
                self.assertEqual((root/'mobile-ios'/name).read_bytes(),data)
                self.assertEqual(receipt['inputs'][name]['sourceSHA256'],hashlib.sha256(data).hexdigest())
                self.assertEqual(receipt['inputs'][name]['stagedSHA256'],hashlib.sha256((staged/name).read_bytes()).hexdigest())
                self.assertNotEqual((staged/name).read_bytes(),data)
            with self.assertRaises(ValueError): fixture.instrument_export_sources(root,staged)
            self.assertEqual((root/'mobile-ios/App/MeasurementExportRequest.swift').read_bytes(),originals['App/MeasurementExportRequest.swift'])


class RunnerAuditIntegrationTests(unittest.TestCase):
    def trial(self, failing_test):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);results=home/'results'
            container=home/'owned/Containers/Data/Application/fixture';container.mkdir(parents=True)
            device='11111111-1111-4111-8111-111111111111';events=[]
            primary=RuntimeError('original UI failure')
            def output(command, timeout=60):
                if command[1:4]==['simctl','list','runtimes']:
                    return json.dumps({'runtimes':[{'identifier':'ios27','version':'27.0','buildversion':'24A434'}]})
                if command[1:3]==['simctl','create']:return device
                if command[1:5]==['xcresulttool','get','test-results','summary']:
                    return json.dumps({'totalTestCount':1,'passedTests':1,'failedTests':0,'skippedTests':0})
                return ''
            def phase(command, log, receipt, timeout, **kwargs):
                if command[0]=='xcodebuild' and command[-1]=='test':
                    events.append('test')
                    if failing_test:raise primary
                elif len(command)>1 and command[1].endswith('export_dismissal_observation.py'):
                    events.append('collector');self.assertEqual(timeout,5);self.assertEqual(command[2],device)
                    raise subprocess.TimeoutExpired(command,timeout)
                elif command[1:3]==['simctl','shutdown']:events.append('shutdown')
                elif command[1:3]==['simctl','delete']:events.append('delete')
                return {}
            stream=Mock();stream.finalize.side_effect=lambda: events.append('finalize') or {'collectorCleaned':True}
            args=['fixture','--result-directory',str(results),'--seed-artifact',str(home/'seed'),
                  '--seed-manifest-sha256','a'*64,'--only-test','native-export-dismissal']
            with ExitStack() as stack:
                stack.enter_context(patch.object(sys,'argv',args))
                for name,value in [('record_toolchain',{}),('private_artifact',{'manifest':{}}),('run_artifact',None),
                                   ('stage_sources',None),('current_commit','a'*40),('install_fixture',None),
                                   ('prepare_simulator',None),('capture_simulator_bootstrap_failure',None)]:
                    stack.enter_context(patch.object(runner,name,return_value=value))
                stack.enter_context(patch.object(runner.export_fixture,'instrument_export_sources',return_value={}))
                stack.enter_context(patch.object(runner,'select_ui_destination',return_value=('ios27','iPhone17')))
                stack.enter_context(patch.object(runner,'output',side_effect=output))
                stack.enter_context(patch.object(runner.failure_observation,'simctl_output',return_value=str(container)))
                stack.enter_context(patch.object(runner,'run_owned_phase',side_effect=phase))
                stack.enter_context(patch.object(runner,'OwnedSimulatorBootLog',return_value=stream))
                stack.enter_context(patch.object(runner,'observe_first_failure',side_effect=lambda *a,**k: events.append('failureLatch')))
                if failing_test:
                    with self.assertRaises(RuntimeError) as caught: runner.main()
                    self.assertIs(caught.exception,primary)
                    self.assertLess(events.index('failureLatch'),events.index('collector'))
                else: runner.main()
            self.assertEqual(events[-4:],['collector','shutdown','delete','finalize'])
            self.assertTrue(json.loads((results/'simulator-cleanup.json').read_text())['success'])

    def test_collector_timeout_keeps_original_ui_exception_and_all_cleanup(self): self.trial(True)
    def test_collector_timeout_after_ui_success_keeps_verdict_and_all_cleanup(self): self.trial(False)


if __name__ == '__main__': unittest.main()
