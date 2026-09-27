from __future__ import annotations

import asyncio
import socket
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

import httpx

import app as runtime
import config
from can_source.udp_json import UDPJsonCANSource


class UDPRuntimeTests(unittest.IsolatedAsyncioTestCase):
    async def test_health_stays_unready_until_valid_datagram_arrives(self):
        with tempfile.TemporaryDirectory() as directory:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                probe.bind(("127.0.0.1", 0))
                port = int(probe.getsockname()[1])
            source = UDPJsonCANSource("127.0.0.1", port, stale_after=1.0)
            old_settings = runtime.settings
            runtime.settings = replace(
                config.settings,
                log_dir=Path(directory),
                can_hz=20,
                can_source="udp_json",
                ingest_token=None,
            )
            try:
                with patch.object(runtime, "create_can_source", return_value=source):
                    async with runtime.lifespan(runtime.app):
                        async with httpx.AsyncClient(
                            transport=httpx.ASGITransport(app=runtime.app),
                            base_url="http://localhost",
                        ) as client:
                            before = await client.get("/api/ping")
                            self.assertEqual(before.status_code, 503)
                            self.assertEqual(before.json()["error"]["code"], "source_not_ready")

                            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
                                sender.sendto(
                                    b'{"v":1,"t":1700000000.1,"sig":{"ws_fl":42.0}}',
                                    ("127.0.0.1", port),
                                )
                            for _ in range(30):
                                await asyncio.sleep(0.02)
                                after = await client.get("/api/ping")
                                if after.status_code == 200:
                                    break
                            self.assertEqual(after.status_code, 200)
                            self.assertTrue(after.json()["source"]["ready"])
            finally:
                runtime.settings = old_settings


if __name__ == "__main__":
    unittest.main()
