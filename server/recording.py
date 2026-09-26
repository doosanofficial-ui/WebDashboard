"""Bounded asynchronous CSV bridge with explicit write receipts and owned process lifetime."""
from __future__ import annotations

import asyncio
import json
import math
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from uuid import uuid4

from csv_worker import MAX_COMMAND_BYTES


class RecordingError(OSError):
    pass


class AsyncCsvRecorder:
    def __init__(self, log_dir: Path, *, capacity=128, lag_seconds=0.5, worker_command=None):
        if type(capacity) is not int or capacity < 1 or not math.isfinite(lag_seconds) or lag_seconds <= 0:
            raise ValueError("Invalid recorder limits")
        self.session_id = datetime.now().strftime("%Y%m%d_%H%M%S") + "_" + uuid4().hex
        self.log_dir = Path(log_dir)
        self.can_path = self.log_dir / f"can_{self.session_id}.csv"
        self.gps_path = self.log_dir / f"gps_{self.session_id}.csv"
        self.events_path = self.log_dir / f"events_{self.session_id}.csv"
        self.capacity = capacity
        self.lag_seconds = lag_seconds
        self._command = worker_command or [sys.executable, str(Path(__file__).with_name("csv_worker.py"))]
        self._process = None
        self._sender = None
        self._reader = None
        self._queue = asyncio.Queue(maxsize=capacity)
        self._pending = {}
        self._next_id = 0
        self._written = 0
        self._unconfirmed = 0
        self._rejected = 0
        self._last_can_seq = None
        self._error = None
        self._closing = False
        self._closed = False
        self._ready = False
        self._close_task = None
        self._forced = False
        self._creation = None
        self._handshake = None
        self._closed_receipt = False

    async def start(self, timeout=5.0):
        if self._creation is not None or self._closing:
            raise RecordingError("recorder_already_started")
        self._handshake = asyncio.get_running_loop().create_future()
        self._handshake.add_done_callback(lambda done: None if done.cancelled() else done.exception())
        self._creation = asyncio.create_task(asyncio.create_subprocess_exec(
                *self._command, str(self.log_dir), self.session_id, str(self.capacity),
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL, limit=4096,
                **({"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt"
                   else {"start_new_session": True})))
        try:
            self._process = await asyncio.shield(self._creation)
            if self._closing:
                raise RecordingError("closed_during_startup")
            self._reader = asyncio.create_task(self._receive())
            await asyncio.wait_for(asyncio.shield(self._handshake), timeout)
            if self._closing or self._error:
                raise RecordingError("startup_failed")
            self._ready = True
            self._sender = asyncio.create_task(self._send())
        except asyncio.CancelledError:
            self._fail("startup_cancelled")
            await self.close(timeout=0.1)
            raise
        except Exception:
            self._fail("startup_failed")
            await self.close(timeout=0.1)
            raise RecordingError("startup_failed") from None

    def snapshot(self):
        oldest = min((entry[1] for entry in self._pending.values()), default=time.monotonic())
        age = max(0, time.monotonic() - oldest)
        state = ("failed" if self._error else "closed" if self._closed else "starting" if not self._ready
                 else "delayed" if age > self.lag_seconds else "ready")
        return {"state": state, "error": self._error, "pending": len(self._pending),
                "written": self._written, "unconfirmed": self._unconfirmed, "rejected": self._rejected,
                "oldest_ms": round(age * 1000), "last_can_seq": self._last_can_seq,
                "worker_alive": self._process is not None and self._process.returncode is None,
                "forced": self._forced}

    def _fail(self, code, *, abandon=True):
        self._error = self._error or code
        if self._handshake and not self._handshake.done():
            self._handshake.set_exception(RecordingError(code))
        if abandon:
            pending, self._pending = self._pending, {}
            self._unconfirmed += len(pending)
            for future, _, _ in pending.values():
                if not future.done():
                    future.set_exception(RecordingError(code))

    def _submit(self, kind, value):
        if not self._ready or self._closing or self._error:
            self._rejected += 1
            raise RecordingError("recording_unavailable")
        if len(self._pending) >= self.capacity:
            self._rejected += 1
            self._fail("queue_full", abandon=False)
            raise RecordingError("queue_full")
        number = self._next_id + 1
        encoded = (json.dumps({"id": number, "kind": kind, "value": value},
                              separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
        if len(encoded) > MAX_COMMAND_BYTES:
            self._rejected += 1
            self._fail("payload_too_large", abandon=False)
            raise RecordingError("payload_too_large")
        future = asyncio.get_running_loop().create_future()
        # CAN has no waiting caller. Consume exceptions without changing await results.
        future.add_done_callback(lambda done: None if done.cancelled() else done.exception())
        seq = value.get("status", {}).get("seq") if kind == "CAN" else None
        self._queue.put_nowait(encoded)
        self._pending[number] = (future, time.monotonic(), seq)
        self._next_id = number
        return future

    def log_can(self, frame):
        return self._submit("CAN", frame)

    def log_gps(self, row):
        return self._submit("GPS", row)

    def log_event(self, row):
        return self._submit("MARK", row)

    async def confirm(self, future, *, timeout=1.0):
        try:
            return await asyncio.wait_for(asyncio.shield(future), timeout)
        except asyncio.TimeoutError:
            raise RecordingError("write_unconfirmed") from None

    async def _send(self):
        try:
            while True:
                encoded = await self._queue.get()
                self._process.stdin.write(encoded)
                await self._process.stdin.drain()
        except (OSError, ValueError):
            self._fail("worker_unavailable")

    async def _receive(self):
        try:
            while line := await self._process.stdout.readline():
                reply = json.loads(line)
                if reply == {"ready": True} and self._handshake and not self._handshake.done():
                    self._handshake.set_result(True)
                    continue
                if reply == {"closed": True} and self._closing and not self._pending:
                    self._closed_receipt = True
                    continue
                if reply.get("error"):
                    self._fail("write_failed")
                    break
                number = reply.get("id")
                if (set(reply) != {"id", "ok"} or type(number) is not int or not self._pending
                        or number != next(iter(self._pending)) or reply.get("ok") is not True):
                    self._fail("worker_protocol_error")
                    break
                future, _, seq = self._pending.pop(number)
                self._written += 1
                if seq is not None:
                    self._last_can_seq = seq
                if not future.done():
                    future.set_result(True)
            if not self._closed_receipt or self._pending:
                self._fail("worker_unavailable")
        except (OSError, ValueError, TypeError, AttributeError):
            self._fail("worker_protocol_error")
        if self._error:
            await self._drain_output()

    async def _drain_output(self):
        # Discard bounded chunks so bad output cannot leave a paused, unread pipe.
        try:
            while await self._process.stdout.read(4096):
                pass
        except (OSError, ValueError):
            pass

    async def close(self, *, timeout=2.0):
        self._closing = True
        if self._close_task is None:
            self._close_task = asyncio.create_task(self._close(timeout))
        return await asyncio.shield(self._close_task)

    async def _close(self, timeout):
        if self._closed:
            return self.snapshot()
        deadline = time.monotonic() + timeout
        if self._creation and self._process is None:
            try:
                self._process = await asyncio.shield(self._creation)
            except Exception:
                self._fail("startup_failed")
        if self._process and self._reader is None:
            self._reader = asyncio.create_task(self._drain_output())
        while self._pending and time.monotonic() < deadline:
            await asyncio.sleep(0.01)
        if self._pending:
            self._fail("shutdown_timeout")
        if self._sender:
            self._sender.cancel()
            await asyncio.gather(self._sender, return_exceptions=True)
        if self._process:
            self._process.stdin.close()
            try:
                await asyncio.wait_for(self._process.wait(), max(0.01, deadline - time.monotonic()))
            except asyncio.TimeoutError:
                self._fail("shutdown_timeout")
                self._forced = True
                if self._process.returncode is None:
                    self._process.terminate()
                try:
                    await asyncio.wait_for(self._process.wait(), 0.5)
                except asyncio.TimeoutError:
                    if self._process.returncode is None:
                        self._process.kill()
                    try:
                        await asyncio.wait_for(self._process.wait(), 0.5)
                    except asyncio.TimeoutError:
                        self._fail("worker_still_running")
        if self._reader:
            if self._process and self._process.returncode is not None:
                # Let EOF/closed receipts be observed before deciding shutdown success.
                try:
                    await asyncio.wait_for(asyncio.shield(self._reader), 0.5)
                except asyncio.TimeoutError:
                    self._reader.cancel()
            else:
                self._reader.cancel()
            await asyncio.gather(self._reader, return_exceptions=True)
        if self._process and (self._process.returncode != 0 or not self._closed_receipt):
            self._fail("worker_unavailable")
        self._closed = True
        return self.snapshot()
