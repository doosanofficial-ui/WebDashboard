"""Bounded, single-writer live delivery; slow viewers never block capture."""
from __future__ import annotations

import asyncio
from collections import deque
from contextlib import suppress
from typing import Any, Awaitable, Callable

import anyio
from fastapi import WebSocket


class StreamPeer:
    def __init__(self, socket: WebSocket, *, send_timeout: float = 1.0) -> None:
        self.socket = socket
        self.send_timeout = send_timeout
        self._latest: dict[str, Any] | None = None
        self._control: deque[dict[str, Any]] = deque()
        self._wake = asyncio.Event()
        self._stopping = False
        self._prefer_control = True
        self.coalesced = 0
        self.finished = asyncio.Event()

    def publish(self, frame: dict[str, Any]) -> None:
        if self._stopping:
            return
        if self._latest is not None:
            self.coalesced += 1
        self._latest = frame
        self._wake.set()

    def control(self, message: dict[str, Any]) -> None:
        if len(self._control) >= 16:
            raise OverflowError("control_queue_full")
        self._control.append(message)
        self._wake.set()

    def stop(self) -> None:
        self._stopping = True
        self._wake.set()

    async def _send(self) -> None:
        while not self._stopping:
            await self._wake.wait()
            if self._stopping:
                return
            if self._control and (self._prefer_control or self._latest is None):
                message = self._control.popleft()
                self._prefer_control = False
            elif self._latest is not None:
                frame, self._latest = self._latest, None
                message = {**frame, "status": {**frame["status"], "client_drop": self.coalesced}}
                self._prefer_control = True
            else:
                self._wake.clear()
                continue
            await asyncio.wait_for(self.socket.send_json(message), self.send_timeout)

    async def run(self, receive: Callable[[], Awaitable[None]]) -> None:
        writer = asyncio.create_task(self._send())
        reader = asyncio.create_task(receive())
        try:
            done, _ = await asyncio.wait((writer, reader), return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                if not task.cancelled():
                    task.result()
        finally:
            self.stop()
            writer.cancel()
            reader.cancel()
            try:
                # ASGI cancellation must not interrupt transport/task cleanup.
                with anyio.CancelScope(shield=True):
                    await asyncio.gather(writer, reader, return_exceptions=True)
                    with suppress(Exception):
                        await asyncio.wait_for(self.socket.close(), self.send_timeout)
            finally:
                self.finished.set()
