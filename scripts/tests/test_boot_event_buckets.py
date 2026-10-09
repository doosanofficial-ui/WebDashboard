"""Bounded received-event evidence, never whole-Simulator readiness."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import owned_simulator_boot_log as module
import test_owned_simulator_boot_log as existing_boot_tests

DEVICE = '11111111-1111-4111-8111-111111111111'
RENDERER = '/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/SimRenderingServices.simdeviceio/Contents/XPCServices/SimRenderServer.xpc/Contents/MacOS/SimRenderServer'


class BootEventBucketTests(unittest.TestCase):
    def buckets(self):
        factory = getattr(module, 'BootEventBuckets', None)
        self.assertTrue(callable(factory), 'Missing fixed received-event bucket evidence')
        return factory(DEVICE, 100., 240)

    def event(self, stamp='2026-10-09 01:00:00.000000+0000'):
        return {'eventMessage': 'deviceDidBoot: ' + DEVICE + ' finished booting PRIVATE_TOKEN',
                'timestamp': stamp, 'processImagePath': RENDERER,
                'senderImagePath': '/PRIVATE_PATH', 'private': 'PRIVATE_TOKEN'}

    def test_all_24_receive_buckets_keep_counts_and_outside_window_is_not_clamped(self):
        buckets = self.buckets()
        for index in range(24):
            buckets.record(buckets.prepare(self.event(), 100 + index * 10))
            buckets.record(buckets.prepare(self.event(), 109.999 + index * 10))
        buckets.record(buckets.prepare(self.event(), 99.999))
        buckets.record(buckets.prepare(self.event(), 340.))
        state = buckets.snapshot()
        self.assertEqual(len(state['buckets']), 24)
        self.assertEqual([b['eventCount'] for b in state['buckets']], [2] * 24)
        self.assertEqual(state['outsideWindowEvents'], 2)
        self.assertEqual(state['buckets'][23]['lastReceiveMonotonic'], 339.999)

    def test_reported_first_ci_sender_paths_are_classified_without_retaining_paths(self):
        buckets = self.buckets()
        runtime = '/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v24.1.434.0.fixture/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot'
        # Sanitized actual Replay head6/106/358 and Route tail18; receive time is synthetic.
        events = [
            ('rendererBootCallback', {'timestamp': '2026-10-09 00:57:33.781712+0000',
                'eventMessage': f'deviceDidBoot: Device {DEVICE} finished booting.',
                'processImagePath': RENDERER, 'senderImagePath': RENDERER, 'subsystem': ''}),
            ('mcmMigration', {'timestamp': '2026-10-09 00:57:41.117544+0000',
                'eventMessage': f'Wrote [🔒/Users/runner/Library/Developer/CoreSimulator/Devices/{DEVICE}/data/Library/MobileContainerManager/System/mcm_migration_status.plist], length = 155, options = 0x1, permissions = {{501:20:u+rw}}',
                'processImagePath': runtime + '/usr/libexec/containermanagerd_system',
                'senderImagePath': runtime + '/System/Library/PrivateFrameworks/ContainerManagerCommon.framework/ContainerManagerCommon',
                'subsystem': 'com.apple.containermanager'}),
            ('launchServices', {'timestamp': '2026-10-09 00:57:49.438168+0000',
                'eventMessage': f'Successfully removed recovery file /Users/runner/Library/Developer/CoreSimulator/Devices/{DEVICE}/data/var/db/lsd/com.apple.LaunchServices.error',
                'processImagePath': runtime + '/usr/libexec/lsd',
                'senderImagePath': runtime + '/System/Library/Frameworks/CoreServices.framework/CoreServices',
                'subsystem': 'com.apple.launchservices'}),
            ('remindersMigration', {'timestamp': '2026-10-09 01:07:16.477073+0000',
                'eventMessage': f'JSONPropertiesMigration BEGIN {{store: <NSSQLCore: 0xFIXTURE> (URL: file:///Users/runner/Library/Developer/CoreSimulator/Devices/{DEVICE}/data/Containers/Shared/AppGroup/{DEVICE}/Container_v1/Stores/Data-{DEVICE}.sqlite)}}',
                'processImagePath': runtime + '/usr/libexec/remindd',
                'senderImagePath': runtime + '/usr/libexec/remindd',
                'subsystem': 'com.apple.reminderkit.store'})]
        for category, event in events:
            buckets.record(buckets.prepare(event, 101.))
        row = buckets.snapshot()['buckets'][0]
        for category, *_ in events:
            self.assertEqual(row['senderEvents'][category], 1, category)
        self.assertNotIn('/private/', json.dumps(buckets.snapshot()))

    def test_launchservices_subsystem_on_actual_core_services_sender(self):
        buckets = self.buckets()
        event = {'eventMessage': 'activitiesMap: ' + DEVICE,
            'subsystem': 'com.apple.launchservices',
            'senderImagePath': '/System/Library/Frameworks/CoreServices.framework/CoreServices'}
        buckets.record(buckets.prepare(event, 101.))
        self.assertEqual(buckets.snapshot()['buckets'][0]['senderEvents']['launchServices'], 1)
        event['subsystem'] = 'PRIVATE_OTHER'
        buckets.record(buckets.prepare(event, 102.))
        self.assertEqual(buckets.snapshot()['buckets'][0]['senderEvents']['otherOwned'], 1)

    def test_nonmonotonic_event_utc_extrema_do_not_reorder_receive_observations(self):
        buckets = self.buckets()
        buckets.record(buckets.prepare(self.event('2026-10-09 01:00:49.768838+0000'), 101.))
        buckets.record(buckets.prepare(self.event('2026-10-09 01:01:15.235889+0000'), 102.))
        buckets.record(buckets.prepare(self.event('2026-10-09 01:00:16.960947+0000'), 103.))
        row = buckets.snapshot()['buckets'][0]
        self.assertEqual(row['eventUTCMin'], '2026-10-09T01:00:16.960947Z')
        self.assertEqual(row['eventUTCMax'], '2026-10-09T01:01:15.235889Z')
        self.assertEqual(row['firstReceiveMonotonic'], 101.)
        self.assertEqual(row['lastReceiveMonotonic'], 103.)

    def test_fixed_sender_counts_and_invalid_utc_exclude_private_values(self):
        buckets = self.buckets()
        buckets.record(buckets.prepare(self.event(), 101.))
        invalid = self.event('PRIVATE_TIMESTAMP')
        invalid['processImagePath'] = '/PRIVATE/SimRenderServer'
        buckets.record(buckets.prepare(invalid, 102.))
        foreign = self.event(); foreign['eventMessage'] = '22222222-2222-4222-8222-222222222222'
        buckets.record(buckets.prepare(foreign, 103.))
        state = buckets.snapshot(); row = state['buckets'][0]
        self.assertEqual(row['eventCount'], 2)
        self.assertEqual(row['invalidEventUTC'], 1)
        self.assertEqual(row['senderEvents']['rendererBootCallback'], 1)
        self.assertEqual(row['senderEvents']['otherOwned'], 1)
        self.assertEqual(row['drops']['foreignOrMalformed'], 1)
        encoded = json.dumps(state)
        self.assertNotIn('PRIVATE', encoded)
        self.assertNotIn('22222222', encoded)
        self.assertIsNone(state['subscriptionReady'])

    def test_quiet_unobserved_and_stopped_buckets_keep_readiness_unknown(self):
        buckets = self.buckets()
        buckets.reader_progress(115.)
        buckets.drop('invalidJSON', 115.5)
        buckets.stop_observed(121.)
        state = buckets.snapshot()
        self.assertEqual(state['buckets'][1]['readerFirstMonotonic'], 115.)
        self.assertEqual(state['buckets'][1]['eventCount'], 0)
        self.assertEqual(state['buckets'][1]['drops']['invalidJSON'], 1)
        self.assertIsNone(state['buckets'][0]['readerFirstMonotonic'])
        self.assertIsNone(state['buckets'][2]['readerFirstMonotonic'])
        self.assertEqual(state['collectorStopObservedMonotonic'], 121.)
        self.assertIsNone(state['subscriptionReady'])

    def test_summary_size_and_fixed_shape_do_not_grow_with_received_noise(self):
        buckets = self.buckets()
        for index in range(12000):
            event = self.event(); event['dynamic-' + str(index)] = 'PRIVATE' * 100
            buckets.record(buckets.prepare(event, 100. + (index % 2400) / 10))
        state = buckets.snapshot()
        self.assertEqual(sum(b['eventCount'] for b in state['buckets']), 12000)
        self.assertLess(len(json.dumps(state).encode()), 32 * 1024)
        self.assertNotIn('dynamic-', json.dumps(state))


@unittest.skipUnless(os.name == 'posix', 'Owned stream process groups')
class BootEventBucketIntegrationTests(unittest.TestCase):
    def test_summary_survives_raw_middle_eviction_and_retained_line_bytes_are_unchanged(self):
        rows = [json.dumps({'eventMessage': f'owned-{i} {DEVICE}', 'timestamp': 'PRIVATE_TIMESTAMP', 'padding': 'x' * 50}).encode() for i in range(80)]
        source = 'import sys;sys.stdout.buffer.write(' + repr(b'\n'.join(rows) + b'\n') + ');sys.stdout.flush()'
        helper = existing_boot_tests.BootLogBoundaryTests()
        receipt, head = helper.trial(source, byte_limit=1024)
        self.assertIn('eventBuckets', receipt, 'Middle input needs bounded summary evidence')
        self.assertEqual(sum(b['eventCount'] for b in receipt['eventBuckets']['buckets']), 80)
        self.assertGreater(receipt['tailEvictedEvents'], 0)
        self.assertTrue(all(line in rows for line in (head + helper.tail_data).splitlines()))
        self.assertNotIn('PRIVATE', json.dumps(receipt['eventBuckets']))
        self.assertTrue(receipt['collectorCleaned'])
        self.assertEqual(receipt['windowSeconds'], 2)
        self.assertEqual(receipt['byteLimit'], 1024)

    def test_summary_fault_cannot_drop_valid_raw_events_or_skip_owned_cleanup(self):
        factory = getattr(module, 'BootEventBuckets', None)
        self.assertTrue(callable(factory), 'Missing independent optional summary boundary')
        row = json.dumps({'eventMessage': 'owned ' + DEVICE}).encode()
        source = 'import sys;sys.stdout.buffer.write(' + repr(row + b'\n') + ');sys.stdout.flush()'
        helper = existing_boot_tests.BootLogBoundaryTests()
        with patch.object(factory, 'prepare', side_effect=RuntimeError('PRIVATE_FAULT')):
            receipt, head = helper.trial(source)
        self.assertEqual(head, row + b'\n')
        self.assertEqual(receipt['bucketSummaryErrors'], 1)
        self.assertTrue(receipt['collectorCleaned'])
        self.assertNotIn('PRIVATE_FAULT', json.dumps(receipt))

    def test_full_tail_and_receipt_staging_overlap_stays_within_payload_cap(self):
        native_popen, native_replace = subprocess.Popen, os.replace
        blocked, release = threading.Event(), threading.Event()
        peaks = []
        children = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            row = json.dumps({'eventMessage': 'owned ' + DEVICE, 'padding': 'x' * 4000}).encode() + b'\n'
            source = ('import sys,time;sys.stdout.buffer.write(' + repr(row) + '*600);sys.stdout.flush();'
                      'time.sleep(1.3);sys.stdout.buffer.write(' + repr(row) + ');sys.stdout.flush()')
            def launch(command, **kwargs):
                child = native_popen([sys.executable, '-B', '-c', source], **kwargs)
                children.append(child)
                return child
            def replace(source, destination):
                destination = Path(destination)
                if (destination.name == 'simulator-boot-stream-tail.ndjson' and
                        destination.exists() and destination.stat().st_size > 500000 and
                        Path(source).stat().st_size > 500000):
                    blocked.set()
                    if not release.wait(3):
                        raise RuntimeError('Fixture receipt overlap not released')
                peaks.append(sum(p.stat().st_size for p in root.iterdir()
                    if p.name.startswith('simulator-boot-stream')))
                return native_replace(source, destination)
            with patch.object(subprocess, 'Popen', side_effect=launch), patch.object(os, 'replace', side_effect=replace):
                collector = module.OwnedSimulatorBootLog(DEVICE, root, window=4)
                try:
                    self.assertTrue(blocked.wait(3), 'Need actual old/full temporary tail overlap')
                    result = collector.finalize(join_timeout=.01)
                    self.assertFalse(result['workerStopped'])
                    self.assertFalse(result['collectorCleaned'])
                    # Publish a second receipt while the previous receipt and full tail staging coexist.
                    collector.finalize(join_timeout=.01)
                    self.assertGreater(max(peaks), 1900000)
                    self.assertLessEqual(max(peaks), result['retainedPayloadByteLimit'])
                finally:
                    release.set()
                    collector.worker.join(timeout=3)
                final = collector.finalize()
                self.assertTrue(final['collectorCleaned'])
                self.assertLessEqual(max(peaks), final['retainedPayloadByteLimit'])
                print('OWNED_BOOT_PAYLOAD_PEAK_BYTES=' + str(max(peaks)))
                self.assertFalse(list(root.glob('*.tmp')))
                for file in root.glob('*.ndjson'):
                    self.assertTrue(all(line + b'\n' == row for line in file.read_bytes().splitlines()))
                self.assertTrue(all(child.returncode is not None for child in children))

    def test_full_receipt_and_atomic_staging_obey_combined_cap_and_failed_replace_preserves_prior(self):
        native_popen, native_replace = subprocess.Popen, os.replace
        peaks = []; kinds = []; children = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = 'import json;print(json.dumps({"eventMessage":"owned ' + DEVICE + '"}))'
            def launch(command, **kwargs):
                child = native_popen([sys.executable, '-B', '-c', source], **kwargs)
                children.append(child)
                return child
            def replace(source, destination):
                size = sum(p.stat().st_size for p in root.iterdir() if p.name.startswith('simulator-boot-stream'))
                peaks.append(size); kinds.append(Path(destination).name)
                return native_replace(source, destination)
            with patch.object(subprocess, 'Popen', side_effect=launch), patch.object(os, 'replace', side_effect=replace):
                collector = module.OwnedSimulatorBootLog(DEVICE, root, window=2)
                collector.worker.join(timeout=3)
                result = collector.finalize()
                self.assertTrue(result['collectorCleaned'])
                self.assertIn('simulator-boot-stream.json', kinds, 'Receipt needs atomic bounded publication')
                receipt_path = root / 'simulator-boot-stream.json'
                original = receipt_path.read_bytes()
                self.assertLessEqual(len(original), result['receiptByteLimit'])
                self.assertLessEqual(result['headByteLimit'] + result['tailByteLimit'] + result['tailTemporaryByteLimit'] + 2 * result['receiptByteLimit'], 2 * 1024 * 1024)
                self.assertTrue(all(size <= 2 * 1024 * 1024 for size in peaks))
                collector.state['unexpectedPrivateBlob'] = 'PRIVATE' * 15000
                compact = collector.finalize()
                self.assertTrue(compact['receiptTruncated'])
                self.assertTrue(compact['collectorCleaned'])
                self.assertNotIn('PRIVATE', receipt_path.read_text())
                prior = receipt_path.read_bytes()
                def fail_receipt(source, destination):
                    if Path(destination).name == 'simulator-boot-stream.json':
                        raise OSError('synthetic receipt replace interrupted')
                    return native_replace(source, destination)
                with patch.object(os, 'replace', side_effect=fail_receipt):
                    with self.assertRaises(OSError):
                        collector.finalize()
                self.assertEqual(receipt_path.read_bytes(), prior)
                self.assertFalse(list(root.glob('*.tmp')))
            self.assertTrue(all(child.returncode is not None for child in children))


if __name__ == '__main__':
    unittest.main()
