"""Exercise the actual ASGI app and lifespan with isolated storage and settings."""
from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path


class RuntimeSmokeTests(unittest.TestCase):
    def test_can_v1_and_durable_ingest_v2_coexist(self):
        script = r'''
import csv
import json
import secrets
import sqlite3
import tempfile
import time
from dataclasses import replace
from contextlib import closing
from pathlib import Path
from fastapi.testclient import TestClient
import config

with tempfile.TemporaryDirectory() as directory:
    token = secrets.token_urlsafe(32)
    config.settings = replace(config.settings, log_dir=Path(directory), ingest_token=token,
                              naver_maps_client_id=None, naver_maps_client_secret=None)
    from app import app
    with TestClient(app, base_url="https://testserver") as client:
        assert client.get("/api/ping").json()["ok"] is True
        assert client.get("/").status_code == 200
        assert token not in client.get("/api/public-config").text
        with client.websocket_connect("/ws") as ws:
            frames = []
            started = time.monotonic()
            for _ in range(10):
                frames.append(ws.receive_json())
            elapsed = time.monotonic() - started
            assert 0.5 < elapsed < 2.5
            assert frames[-1]["status"]["seq"] - frames[0]["status"]["seq"] == 9
            ws.send_json({"v":1,"type":"MARK","t":1700000000,"note":"smoke"})
            ws.send_json({"v":1,"type":"ping","t":1700000001})
            for _ in range(20):
                if ws.receive_json().get("type") == "pong":
                    break
            else:
                raise AssertionError("No pong received")
        event = {"id":"5c6a7f61-24c4-4ed9-8216-5fd0ffde1001","type":"GPS",
                 "captured_t":1700000000,"data":{"lat":37,"lon":127,"spd":None}}
        payload = {"v":2,"client_id":"runtime-smoke","events":[event]}
        headers = {"Authorization":"Bearer " + token}
        first = client.post("/api/v2/ingest", json=payload, headers=headers)
        replay = client.post("/api/v2/ingest", json=payload, headers=headers)
        assert first.status_code == replay.status_code == 200
        assert first.json()["acked"] == [event["id"]]
        assert client.post("/api/v2/ingest", json=payload).status_code == 401
    with closing(sqlite3.connect(Path(directory) / "telemetry.sqlite3")) as db, db:
        assert db.execute("SELECT count(*) FROM events").fetchone()[0] == 1
    with next(Path(directory).glob("events_*.csv")).open() as stream:
        assert list(csv.DictReader(stream))[0]["note"] == "smoke"
    print(json.dumps({"can_frames":10,"contiguous":True,"mark_logged":True,"durable_rows":1}))
'''
        result = subprocess.run([sys.executable, "-B", "-c", script],
                                cwd=Path(__file__).resolve().parents[1],
                                capture_output=True, text=True, timeout=25)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"durable_rows": 1', result.stdout)


if __name__ == "__main__":
    unittest.main()
