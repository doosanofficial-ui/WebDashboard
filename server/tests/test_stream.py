from __future__ import annotations

import asyncio
import json
import sys
import unittest
from pathlib import Path

from starlette.websockets import WebSocket

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from stream import StreamPeer


class StreamTests(unittest.IsolatedAsyncioTestCase):
    async def test_coalesces_latest_without_losing_pong_or_mutating_shared_frame(self):
        blocked, release, delivered = asyncio.Event(), asyncio.Event(), asyncio.Event()
        sent = []
        active = 0
        max_active = 0

        async def receive():
            return {"type": "websocket.connect"}

        async def send(message):
            nonlocal active, max_active
            if message["type"] != "websocket.send":
                return
            active += 1
            max_active = max(active, max_active)
            try:
                if not sent:
                    blocked.set()
                    await release.wait()
                sent.append(json.loads(message["text"]))
                if len(sent) == 3:
                    delivered.set()
            finally:
                active -= 1

        ws = WebSocket({"type": "websocket"}, receive, send)
        await ws.accept()
        peer = StreamPeer(ws)
        task = asyncio.create_task(peer.run(asyncio.Event().wait))
        try:
            peer.publish({"v": 1, "status": {"seq": 1, "drop": 0}})
            await asyncio.wait_for(blocked.wait(), 1)
            for seq in range(2, 101):
                frame = {"v": 1, "status": {"seq": seq, "drop": 0}}
                peer.publish(frame)
            peer.control({"v": 1, "type": "pong", "t": 12})
            release.set()
            await asyncio.wait_for(delivered.wait(), 1)
            self.assertEqual([x.get("status", {}).get("seq") for x in sent], [1, None, 100])
            self.assertEqual(sent[1]["type"], "pong")
            self.assertEqual(sent[2]["status"]["client_drop"], 98)
            self.assertEqual(sent[2]["status"]["drop"], 0)
            self.assertNotIn("client_drop", frame["status"])
            self.assertEqual(max_active, 1)
        finally:
            release.set()
            peer.stop()
            await asyncio.wait_for(task, 2)

    async def test_blocked_writer_times_out_and_cleans_up_reader_and_socket(self):
        reader_closed = asyncio.Event()
        closed = asyncio.Event()

        async def receive():
            return {"type": "websocket.connect"}

        async def send(message):
            if message["type"] == "websocket.send":
                await asyncio.Event().wait()
            elif message["type"] == "websocket.close":
                closed.set()

        async def reader():
            try:
                await asyncio.Event().wait()
            finally:
                reader_closed.set()

        ws = WebSocket({"type": "websocket"}, receive, send)
        await ws.accept()
        peer = StreamPeer(ws, send_timeout=0.05)
        peer.publish({"v": 1, "status": {"seq": 1, "drop": 0}})
        with self.assertRaises(TimeoutError):
            await asyncio.wait_for(peer.run(reader), 1)
        self.assertTrue(reader_closed.is_set())
        self.assertTrue(closed.is_set())
        self.assertTrue(peer.finished.is_set())

    async def test_control_flood_is_bounded(self):
        peer = StreamPeer(None)
        for _ in range(16):
            peer.control({"type": "pong"})
        with self.assertRaises(OverflowError):
            peer.control({"type": "pong"})


if __name__ == "__main__":
    unittest.main()
