"""Fault tests through the real app lifespan/HTTP health and actual CSV files."""
from __future__ import annotations

import subprocess
import sys
import textwrap
import unittest
from pathlib import Path
from dataclasses import replace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from config import settings


class RuntimeFaultTests(unittest.TestCase):
    def test_invalid_sample_rate_is_rejected_before_startup(self):
        for rate in [0, -1, float("nan"), float("inf")]:
            with self.subTest(rate=rate), self.assertRaises(ValueError):
                replace(settings, can_hz=rate)

    def run_case(self, body: str, *, drop: int = 0):
        script = '''
import asyncio, csv, tempfile
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch
import httpx, config

async def verify():
    with tempfile.TemporaryDirectory() as directory:
        config.settings = replace(config.settings, log_dir=Path(directory), can_hz=10,
                                  simulate_drop_every=DROP, ingest_token=None)
        import app as runtime
        async def health():
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=runtime.app),
                                         base_url="http://localhost") as client:
                return await client.get("/api/ping")
BODY
asyncio.run(verify())
'''.replace("DROP", str(drop)).replace("BODY", textwrap.indent(textwrap.dedent(body), "        "))
        result = subprocess.run([sys.executable, "-B", "-c", script],
                                cwd=Path(__file__).resolve().parents[1],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_repeated_lifespan_opens_new_session_and_preserves_old_files(self):
        self.run_case('''
            sessions = []
            for _ in range(2):
                async with runtime.lifespan(runtime.app):
                    await asyncio.sleep(0.25)
                    response = await health()
                    assert response.status_code == 200
                    sessions.append(response.json()["session"])
            assert len(set(sessions)) == 2, "Restart reused a closed CSV session"
            files = list(Path(directory).glob("can_*.csv"))
            assert len(files) == 2
            for path in files:
                with path.open() as stream:
                    rows = list(csv.DictReader(stream))
                assert len(rows) >= 2 and int(rows[0]["seq"]) == 0
        ''')

    def test_csv_failure_is_unhealthy_and_does_not_disclose_exception(self):
        self.run_case('''
            async with runtime.lifespan(runtime.app):
                with patch.object(runtime.logger, "log_can", side_effect=OSError("private-canary-value")):
                    await asyncio.sleep(0.2)
                    response = await health()
                    assert response.status_code == 503, "Dead recorder reported healthy"
                    assert response.json()["error"]["code"] == "recording_failed"
                    assert "private-canary-value" not in response.text
        ''')

    def test_source_failure_is_unhealthy_and_can_shutdown_cleanly(self):
        self.run_case('''
            async with runtime.lifespan(runtime.app):
                with patch.object(runtime.can_source, "next_frame", side_effect=RuntimeError("private-canary-value")):
                    await asyncio.sleep(0.2)
                    response = await health()
                    assert response.status_code == 503, "Dead CAN source reported healthy"
                    assert response.json()["error"]["code"] == "source_failed"
                    assert "private-canary-value" not in response.text
            assert runtime.broadcast_task is None
        ''')

    def test_simulated_send_drop_does_not_remove_recorded_samples(self):
        self.run_case('''
            async with runtime.lifespan(runtime.app):
                await asyncio.sleep(0.55)
                path = runtime.logger.can_path
                seq = runtime.stream_state["seq"]
                assert runtime.stream_state["drop"] >= 1
            with path.open() as stream:
                rows = list(csv.DictReader(stream))
            assert [int(row["seq"]) for row in rows] == list(range(seq)), "Simulated send drop removed CAN capture"
        ''', drop=2)

    def test_nonfinite_source_values_are_not_published_as_healthy_data(self):
        self.run_case('''
            async with runtime.lifespan(runtime.app):
                with patch.object(runtime.can_source, "next_frame", return_value={"ws_fl":float("nan")}):
                    await asyncio.sleep(0.2)
                    response = await health()
                    assert response.status_code == 503
                    assert response.json()["error"]["code"] == "source_failed"
        ''')

    def test_producer_cancelled_before_first_sample_does_not_hang_startup(self):
        self.run_case('''
            class CancelledSource:
                def next_frame(self):
                    raise asyncio.CancelledError()
            async def start_and_check():
                async with runtime.lifespan(runtime.app):
                    response = await health()
                    assert response.status_code == 503
                    assert response.json()["error"]["code"] == "stream_unavailable"
            with patch.object(runtime, "create_can_source", return_value=CancelledSource()):
                await asyncio.wait_for(start_and_check(), 1)
            assert runtime.broadcast_task is None
        ''')


if __name__ == "__main__":
    unittest.main()
