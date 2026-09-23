from __future__ import annotations

import csv
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from logger import SessionCsvLogger


class FrozenClock:
    @staticmethod
    def now():
        return datetime(2026, 9, 23, 12, 0, 0)


class CsvSessionTests(unittest.TestCase):
    def test_partial_initialization_failure_releases_files_and_preserves_conflicting_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            existing = path / "events_fixed.csv"
            existing.write_text("preserved", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                SessionCsvLogger(path, session_id="fixed")
            self.assertEqual(existing.read_text(encoding="utf-8"), "preserved")
            # On Windows these operations fail if initialization leaked handles.
            (path / "can_fixed.csv").unlink()
            (path / "gps_fixed.csv").unlink()

    def test_rapid_restart_preserves_previous_session_bytes(self):
        with tempfile.TemporaryDirectory() as directory, patch("logger.datetime", FrozenClock):
            first = SessionCsvLogger(Path(directory))
            first.log_event({"t": 1234, "type": "MARK", "note": "original"})
            first.close()
            original = first.events_path.read_bytes()
            second = SessionCsvLogger(Path(directory))
            second.close()
            self.assertEqual(first.events_path.read_bytes(), original)
            self.assertNotEqual(first.session_id, second.session_id)

    def test_explicit_session_cannot_truncate_existing_data(self):
        with tempfile.TemporaryDirectory() as directory:
            first = SessionCsvLogger(Path(directory), session_id="fixed-session")
            first.log_event({"t": 1234, "type": "MARK", "note": "keep"})
            first.close()
            duplicate = None
            try:
                with self.assertRaises(FileExistsError):
                    duplicate = SessionCsvLogger(Path(directory), session_id="fixed-session")
            finally:
                if duplicate:
                    duplicate.close()
            with first.events_path.open() as stream:
                self.assertEqual(list(csv.DictReader(stream))[0]["note"], "keep")


class StreamingResilienceTests(unittest.TestCase):
    def test_blocked_real_asgi_subscriber_does_not_stop_capture_or_other_subscribers(self):
        script = r'''
import asyncio, csv, tempfile
from dataclasses import replace
from pathlib import Path
import config

async def verify():
    with tempfile.TemporaryDirectory() as directory:
        config.settings = replace(config.settings, log_dir=Path(directory), can_hz=10,
                                  simulate_drop_every=0, ingest_token=None)
        import app as runtime
        blocked = asyncio.Event()
        release = asyncio.Event()
        healthy = []
        tasks = []
        queues = []
        async with runtime.lifespan(runtime.app):
            try:
                for slow in (True, False):
                    queue = asyncio.Queue()
                    queues.append(queue)
                    await queue.put({"type":"websocket.connect"})
                    async def send(message, slow=slow):
                        if message["type"] == "websocket.send":
                            if slow:
                                blocked.set()
                                await release.wait()
                            else:
                                healthy.append(message["text"])
                    scope = {"type":"websocket", "asgi":{"version":"3.0", "spec_version":"2.1"},
                             "path":"/ws", "raw_path":b"/ws", "root_path":"", "scheme":"ws",
                             "query_string":b"", "headers":[], "subprotocols":[],
                             "client":("127.0.0.1",1234), "server":("127.0.0.1",8080)}
                    tasks.append(asyncio.create_task(runtime.app(scope, queue.get, send)))
                await asyncio.wait_for(blocked.wait(), 2)
                before = runtime.stream_state["seq"]
                await asyncio.sleep(0.4)
                after = runtime.stream_state["seq"]
                with runtime.logger.can_path.open() as stream:
                    logged = list(csv.DictReader(stream))
                assert after >= before + 2, "Slow subscriber stalled CAN sampling"
                assert len(healthy) >= 2, "Slow subscriber stalled healthy subscriber"
                assert len(logged) >= 3, "Slow subscriber stalled CAN CSV recording"
            finally:
                release.set()
                for queue in queues:
                    await queue.put({"type":"websocket.disconnect", "code":1000})
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
asyncio.run(verify())
'''
        result = subprocess.run([sys.executable, "-B", "-c", script],
                                cwd=Path(__file__).resolve().parents[1],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
