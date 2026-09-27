from __future__ import annotations

import asyncio
import csv
import os
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from recording import AsyncCsvRecorder, RecordingError


def frame(seq):
    return {"v": 1, "t": 1700000000 + seq / 10, "sig": {"ws_fl": 42}, "status": {"seq": seq, "drop": 0}}


class RecordingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.recorders = []

    async def asyncTearDown(self):
        for recorder in self.recorders:
            await recorder.close(timeout=0.2)
        self.temp.cleanup()

    async def recorder(self, mode=None, **kwargs):
        command = None if mode is None else [sys.executable, str(Path(__file__).parent / "fixtures/csv_fault_worker.py"), mode]
        recorder = AsyncCsvRecorder(Path(self.temp.name), worker_command=command, **kwargs)
        self.recorders.append(recorder)
        await recorder.start()
        return recorder

    async def test_real_worker_writes_in_order_and_shutdown_drains(self):
        recorder = await self.recorder()
        tickets = [recorder.log_can(frame(seq)) for seq in range(10)]
        tickets.append(recorder.log_event({"t": 1700000000, "type": "MARK", "note": "ordered"}))
        report = await recorder.close()
        self.assertFalse(report["worker_alive"])
        self.assertEqual(report["written"], 11)
        self.assertEqual(report["unconfirmed"], 0)
        self.assertTrue(all(ticket.result() is True for ticket in tickets))
        with recorder.can_path.open() as stream:
            self.assertEqual([int(row["seq"]) for row in csv.DictReader(stream)], list(range(10)))

    async def test_ipc_fragmentation_and_mutation_do_not_change_an_accepted_record(self):
        recorder = await self.recorder()
        note = "\uac00" * 2000 + "\nnot a second command"
        row = {"t": 1700000000, "type": "MARK", "note": note}
        ticket = recorder.log_event(row)
        row["note"] = "changed after enqueue"
        await recorder.confirm(ticket)
        with recorder.events_path.open(encoding="utf-8", newline="") as stream:
            rows = list(csv.DictReader(stream))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["note"], note)

    async def test_slow_disk_does_not_block_loop_and_later_preserves_all_samples(self):
        recorder = await self.recorder("slow", lag_seconds=0.05)
        first = recorder.log_can(frame(0))
        started = time.monotonic()
        await asyncio.sleep(0.1)
        self.assertLess(time.monotonic() - started, 0.35)
        self.assertFalse(first.done())
        self.assertEqual(recorder.snapshot()["state"], "delayed")
        tickets = [first] + [recorder.log_can(frame(seq)) for seq in range(1, 6)]
        await asyncio.wait_for(asyncio.gather(*tickets), 3)
        self.assertEqual(recorder.snapshot()["state"], "ready")
        self.assertEqual(recorder.snapshot()["last_can_seq"], 5)
        with recorder.can_path.open() as stream:
            self.assertEqual([int(row["seq"]) for row in csv.DictReader(stream)], list(range(6)))

    async def test_timeout_does_not_cancel_an_accepted_write_or_claim_success(self):
        recorder = await self.recorder("slow")
        ticket = recorder.log_can(frame(0))
        with self.assertRaises(RecordingError):
            await recorder.confirm(ticket, timeout=0.02)
        self.assertFalse(ticket.cancelled())
        self.assertFalse(ticket.done())
        self.assertTrue(await asyncio.wait_for(ticket, 3))
        self.assertEqual(recorder.snapshot()["written"], 1)

    async def test_queue_bound_is_fail_closed_without_evicting_accepted_jobs(self):
        recorder = await self.recorder("slow", capacity=2)
        tickets = [recorder.log_can(frame(0)), recorder.log_can(frame(1))]
        with self.assertRaises(RecordingError):
            recorder.log_can(frame(2))
        self.assertEqual(recorder.snapshot()["error"], "queue_full")
        self.assertEqual(recorder.snapshot()["pending"], 2)
        self.assertEqual(recorder.snapshot()["rejected"], 1)
        await asyncio.wait_for(asyncio.gather(*tickets), 3)
        with recorder.can_path.open() as stream:
            self.assertEqual([int(row["seq"]) for row in csv.DictReader(stream)], [0, 1])

    async def test_child_error_rejects_receipt_without_exposing_exception(self):
        recorder = await self.recorder("fail")
        ticket = recorder.log_event({"t": 1, "type": "MARK", "note": "normal"})
        with self.assertRaises(RecordingError):
            await recorder.confirm(ticket)
        self.assertEqual(recorder.snapshot()["state"], "failed")
        self.assertNotIn("private-worker-canary", str(recorder.snapshot()))
        self.assertEqual(recorder.snapshot()["unconfirmed"], 1)

    async def test_child_exit_is_detected_and_future_fails(self):
        recorder = await self.recorder("exit")
        ticket = recorder.log_can(frame(0))
        with self.assertRaises(RecordingError):
            await asyncio.wait_for(ticket, 2)
        self.assertEqual(recorder.snapshot()["state"], "failed")

    async def test_hung_child_is_reaped_on_bounded_shutdown_and_never_acknowledged(self):
        recorder = await self.recorder("hang")
        ticket = recorder.log_can(frame(0))
        await asyncio.sleep(0.1)
        started = time.monotonic()
        report = await recorder.close(timeout=0.1)
        self.assertLess(time.monotonic() - started, 2.5)
        self.assertFalse(report["worker_alive"])
        self.assertEqual(report["unconfirmed"], 1)
        self.assertEqual(report["written"], 0)
        with self.assertRaises(RecordingError):
            ticket.result()

    async def test_start_cancellation_propagates_and_reaps_created_worker(self):
        command = [sys.executable, str(Path(__file__).parent / "fixtures/csv_fault_worker.py"), "init_hang"]
        recorder = AsyncCsvRecorder(Path(self.temp.name), worker_command=command)
        self.recorders.append(recorder)
        task = asyncio.create_task(recorder.start())
        for _ in range(100):
            if recorder.snapshot()["worker_alive"]:
                break
            await asyncio.sleep(0.01)
        self.assertTrue(recorder.snapshot()["worker_alive"])
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertFalse(recorder.snapshot()["worker_alive"])

    async def test_cancelling_close_caller_does_not_abandon_owned_cleanup(self):
        recorder = await self.recorder("hang")
        recorder.log_can(frame(0))
        task = asyncio.create_task(recorder.close(timeout=0.1))
        await asyncio.sleep(0.02)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        await asyncio.sleep(1)
        self.assertFalse(recorder.snapshot()["worker_alive"])

    async def test_invalid_large_worker_reply_fails_closed_and_can_be_reaped(self):
        recorder = await self.recorder("bad_protocol")
        ticket = recorder.log_can(frame(0))
        with self.assertRaises(RecordingError):
            await asyncio.wait_for(ticket, 2)
        report = await asyncio.wait_for(recorder.close(timeout=0.1), 2)
        self.assertFalse(report["worker_alive"])
        self.assertEqual(report["unconfirmed"], 1)

    async def test_invalid_startup_output_does_not_leave_unread_pipes_or_a_worker(self):
        command = [sys.executable, str(Path(__file__).parent / "fixtures/csv_fault_worker.py"), "init_bad"]
        recorder = AsyncCsvRecorder(Path(self.temp.name), worker_command=command)
        self.recorders.append(recorder)
        with self.assertRaises(RecordingError):
            await recorder.start(timeout=0.1)
        self.assertFalse(recorder.snapshot()["worker_alive"])
        self.assertNotEqual(recorder.snapshot()["error"], "worker_still_running")
        self.assertTrue(recorder._process.stdout.at_eof(), "Owned subprocess output was left open/unread")

    @unittest.skipIf(os.name == "nt", "Windows uses CREATE_NEW_PROCESS_GROUP; POSIX pgid is not available")
    async def test_parent_console_signals_do_not_kill_worker_before_drain(self):
        recorder = await self.recorder()
        self.assertNotEqual(os.getpgid(recorder._process.pid), os.getpgrp())

    async def test_parent_pipe_loss_reaps_even_a_blocked_writer(self):
        recorder = await self.recorder("hang")
        ticket = recorder.log_can(frame(0))
        await asyncio.sleep(0.1)
        recorder._process.stdin.close()
        await asyncio.wait_for(recorder._process.wait(), 3)
        self.assertFalse(recorder.snapshot()["worker_alive"])
        with self.assertRaises(RecordingError):
            await ticket

    async def test_close_during_process_creation_cannot_leave_a_late_child_running(self):
        recorder = AsyncCsvRecorder(Path(self.temp.name))
        self.recorders.append(recorder)
        real_create = asyncio.create_subprocess_exec
        async def delayed_create(*args, **kwargs):
            await asyncio.sleep(.1)
            return await real_create(*args, **kwargs)
        try:
            with patch("recording.asyncio.create_subprocess_exec", side_effect=delayed_create):
                start = asyncio.create_task(recorder.start())
                await asyncio.sleep(.02)
                report = await recorder.close(timeout=.5)
                try:
                    await start
                except RecordingError:
                    pass
                self.assertFalse(recorder.snapshot()["worker_alive"])
                self.assertFalse(report["worker_alive"])
        finally:
            if recorder._process and recorder._process.returncode is None:
                recorder._process.kill()
                await recorder._process.wait()

    async def test_abnormal_exit_without_close_receipt_is_not_a_clean_shutdown(self):
        recorder = await self.recorder("bad_close")
        report = await recorder.close()
        self.assertFalse(report["worker_alive"])
        self.assertEqual(report["state"], "failed")
        self.assertIsNotNone(report["error"])


if __name__ == "__main__":
    unittest.main()
