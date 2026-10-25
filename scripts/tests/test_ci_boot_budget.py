"""Finite slow-boot policy, using virtual time and no Apple/device calls."""
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bootstatus_observation as observation
import owned_simulator_boot_log as collector
import verify_offline_replay as replay

DEVICE = '11111111-1111-4111-8111-111111111111'
COMMAND = ['xcrun', 'simctl', 'bootstatus', DEVICE, '-b']


class CIBootBudgetTests(unittest.TestCase):
    def test_absolute_window_deadline_excludes_boundary_and_keeps_last_inside_bucket(self):
        for start in (500.11111111, 900.123456789):
            with self.subTest(start=start):
                buckets = collector.BootEventBuckets(DEVICE, start, 660)
                event = {'eventMessage': 'Owned event ' + DEVICE}
                deadline = start + 660
                buckets.record(buckets.prepare(event, math.nextafter(deadline, -math.inf)))
                buckets.record(buckets.prepare(event, deadline))
                state = buckets.snapshot()
                self.assertEqual(state['outsideWindowEvents'], 1)
                self.assertEqual(state['buckets'][65]['eventCount'], 1)
                self.assertEqual(sum(row['eventCount'] for row in state['buckets']), 1)

    def trial(self, ready_after):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            calls, failures = [], []
            def phase(command, log, receipt, timeout):
                calls.append((command, timeout))
                if command[2] == 'bootstatus' and ready_after > timeout:
                    log.write_text('Still waiting; log activity does not extend the deadline\n')
                    error = subprocess.TimeoutExpired(command, timeout, output=b'partial progress')
                    failures.append(error)
                    raise error
            with patch.object(replay, 'run_owned_phase', side_effect=phase), \
                    patch.object(replay, 'observe_first_failure'), \
                    patch.object(replay, 'capture_simulator_bootstrap_failure'):
                try:
                    replay.prepare_simulator(DEVICE, results)
                except subprocess.TimeoutExpired as error:
                    return calls, failures, error
            return calls, failures, None

    def test_boot_ready_at_virtual_500_seconds_is_not_cut_off_at180(self):
        calls, failures, error = self.trial(500)
        self.assertIsNone(error)
        self.assertEqual(failures, [])
        self.assertEqual(calls, [(['xcrun', 'simctl', 'boot', DEVICE], 60), (COMMAND, 600)])

    def test_boot_past600_remains_timeout_and_keeps_original_error(self):
        calls, failures, error = self.trial(601)
        self.assertIs(error, failures[0])
        self.assertEqual(error.timeout, 600)
        self.assertEqual(error.output, b'partial progress')
        self.assertEqual(len(calls), 2)

    def test_extended_hosted_boot_keeps_one150_second_checkpoint(self):
        child = types.SimpleNamespace(pid=12345, returncode=None)
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}), \
                patch.object(observation.sys, 'platform', 'darwin'), \
                patch.object(observation.subprocess, 'Popen') as native:
            point = observation.checkpoint_for(COMMAND, child, Path(directory), 100., 700., threading.Event())
            self.assertIsInstance(point, observation.BootstatusCheckpoint)
            self.assertEqual((point.scheduled, point.deadline), (250., 260.))
            for budget in (599, 601):
                self.assertIsNone(observation.checkpoint_for(COMMAND, child, Path(directory), 100., 100. + budget, threading.Event()))
            native.assert_not_called()

    def test_log_window_covers_boot60_plus_bootstatus600_and_stays_bounded(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(collector.time, 'monotonic', return_value=500.11111111), \
                patch.object(collector.threading.Thread, 'start'), \
                patch.object(collector.threading.Thread, 'join'), \
                patch.object(collector.threading.Thread, 'is_alive', return_value=False):
            log = collector.OwnedSimulatorBootLog(DEVICE, Path(directory))
            self.assertEqual(log.deadline, log.requested + 660)
            event = {'eventMessage': 'Owned event ' + DEVICE}
            for elapsed in (240, 599, 659.9, 660):
                log.buckets.record(log.buckets.prepare(event, log.requested + elapsed))
            receipt = log.finalize()
            buckets = receipt['eventBuckets']
            self.assertEqual(buckets['bucketCount'], 66)
            self.assertEqual(sum(row['eventCount'] for row in buckets['buckets']), 3)
            self.assertEqual(buckets['outsideWindowEvents'], 1)
            self.assertEqual(log.payload_limit, 2 * 1024 * 1024)
            self.assertLessEqual((Path(directory) / 'simulator-boot-stream.json').stat().st_size, 64 * 1024)
            with self.assertRaises(ValueError):
                collector.OwnedSimulatorBootLog(DEVICE, Path(directory), window=661)

    def test_full660_second_counter_receipt_keeps_the_existing64k_limit(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(collector.threading.Thread, 'start'), \
                patch.object(collector.threading.Thread, 'join'), \
                patch.object(collector.threading.Thread, 'is_alive', return_value=False):
            log = collector.OwnedSimulatorBootLog(DEVICE, Path(directory))
            for row in log.buckets.state['buckets']:
                for key, value in row.items():
                    if key == 'index':
                        continue
                    if isinstance(value, dict):
                        row[key] = dict.fromkeys(value, collector.BootEventBuckets.COUNTER_LIMIT)
                    elif value is None:
                        row[key] = ('2026-10-25T12:00:00.000000Z' if key.startswith('eventUTC')
                                    else 12345678.1234567)
                    elif isinstance(value, int):
                        row[key] = collector.BootEventBuckets.COUNTER_LIMIT
            receipt = log.finalize()
            self.assertEqual(len(receipt['eventBuckets']['buckets']), 66)
            self.assertFalse(receipt['receiptTruncated'])
            self.assertLessEqual((Path(directory) / 'simulator-boot-stream.json').stat().st_size, 65536)
