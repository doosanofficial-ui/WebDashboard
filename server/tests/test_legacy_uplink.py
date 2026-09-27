from __future__ import annotations

import subprocess
import sys
import textwrap
import unittest
from pathlib import Path


class LegacyUplinkTests(unittest.TestCase):
    def run_case(self, body: str):
        script = '''
import csv, json, tempfile, time
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch
from fastapi.testclient import TestClient
import config

def receive_type(ws, kind):
    for _ in range(30):
        payload = ws.receive_json()
        if payload.get("type") == kind:
            return payload
    raise AssertionError("Expected bounded response: " + kind)

with tempfile.TemporaryDirectory() as directory:
    config.settings = replace(config.settings, log_dir=Path(directory), ingest_token=None,
                              can_hz=10, simulate_drop_every=0)
    import app as runtime
    with TestClient(runtime.app) as client:
        client.headers["Content-Type"] = "application/json"
BODY
'''.replace("BODY", textwrap.indent(textwrap.dedent(body), "        "))
        result = subprocess.run([sys.executable, "-B", "-c", script],
                                cwd=Path(__file__).resolve().parents[1],
                                capture_output=True, text=True, timeout=25)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_http_rejects_invalid_gps_without_writing_rows(self):
        self.run_case('''
            base = {"v":1,"t":1700000000,"gps":{"lat":0,"lon":0,"spd":None,"hdg":None}}
            mutations = [
                {"gps":{"lat":91,"lon":0}}, {"gps":{"lat":0,"lon":181}},
                {"gps":{"lat":True,"lon":0}}, {"gps":{"lat":"37","lon":127}},
                {"gps":{"lat":0,"lon":0,"hdg":360}}, {"gps":{"lat":0,"lon":0,"spd":-1}},
                {"gps":{"lat":0,"lon":0,"acc":-1}}, {"gps":{"lat":0}},
                {"v":True}, {"v":2}, {"t":0}, {"t":"private-canary"},
                {"meta":{"device":[]}}, {"meta":{"os":"x"*129}},
                {"meta":{"bg_state":"invalid"}}, {"queued_at":-1},
                {"type":"MARK"}, {"unexpected":"private-canary"},
            ]
            for mutation in mutations:
                response = client.post("/api/gps", json={**base, **mutation})
                assert response.status_code == 422, (mutation, response.status_code)
                assert response.json()["error"]["code"] in ("invalid_payload", "unsupported_version")
                assert "private-canary" not in response.text
            for raw in ['[]', 'null', '{"v":1,"v":2}', '{"v":1,"t":NaN,"gps":{"lat":0,"lon":0}}']:
                response = client.post("/api/gps", content=raw)
                assert response.status_code in (400, 422)
                assert "error" in response.json()
            with runtime.logger.gps_path.open() as stream:
                assert list(csv.DictReader(stream)) == []
        ''')

    def test_http_body_limit_and_mark_validation_preserve_normal_writes(self):
        self.run_case('''
            oversized = '{"v":1,"t":1,"type":"MARK","note":"' + 'X' * 20000 + '"}'
            response = client.post("/api/event", content=oversized)
            assert response.status_code == 413
            assert response.json()["error"]["code"] == "payload_too_large"
            for note in [None, 123, "x"*501, "bad\\x00note", "\\ud800"]:
                response = client.post("/api/event", content=json.dumps({"v":1,"t":1,"type":"MARK","note":note}))
                assert response.status_code == 422
            assert client.post("/api/event", json={"v":1,"t":1700000000,"type":"MARK","note":"valid", "queued_at":1700000001}).status_code == 200
            valid = {"v":1,"t":1700000000,"gps":{"lat":0,"lon":0,"spd":0,"hdg":None,"acc":0,"alt":None},"queued_at":1700000001}
            assert client.post("/api/gps", json=valid).status_code == 200
            with runtime.logger.events_path.open() as stream:
                assert [r["note"] for r in csv.DictReader(stream)] == ["valid"]
            with runtime.logger.gps_path.open() as stream:
                rows = list(csv.DictReader(stream))
                assert len(rows) == 1 and float(rows[0]["spd"]) == 0 and rows[0]["hdg"] == ""
        ''')

    def test_websocket_rejects_bad_frames_and_keeps_can_ping_mark_alive(self):
        self.run_case('''
            with client.websocket_connect("/ws") as ws:
                first_seq = ws.receive_json()["status"]["seq"]
                for raw in ['[]', 'null', 'not-json', '{"type":"ping","t":NaN}',
                            '{"type":"MARK","v":1,"t":1,"note":null}',
                            '{"type":"MARK","v":1,"t":1,"note":"' + "X"*20000 + '"}']:
                    ws.send_text(raw)
                    error = receive_type(ws, "error")
                    assert error["v"] == 1 and error["error"]["code"] in ("invalid_payload", "invalid_json", "payload_too_large")
                ws.send_bytes(b"not-text-json")
                assert receive_type(ws, "error")["error"]["code"] == "text_frame_required"
                ws.send_json({"v":1,"t":1700000000,"type":"MARK","note":"after-errors"})
                ws.send_json({"type":"ping","t":1700000001})
                assert receive_type(ws, "pong")["t"] == 1700000001
                for _ in range(10):
                    frame = ws.receive_json()
                    if "sig" in frame:
                        assert frame["status"]["seq"] > first_seq
                        break
                else:
                    raise AssertionError("No healthy CAN frame after invalid input")
            with runtime.logger.events_path.open() as stream:
                assert [row["note"] for row in csv.DictReader(stream)] == ["after-errors"]
        ''')

    def test_csv_write_failure_returns_safe_error_without_false_success(self):
        self.run_case('''
            payload = {"v":1,"t":1700000000,"type":"MARK","note":"normal"}
            with patch.object(runtime.logger, "log_event", side_effect=OSError("private-canary")):
                response = client.post("/api/event", json=payload)
                assert response.status_code == 503
                assert response.json()["error"]["code"] == "storage_unavailable"
                assert "private-canary" not in response.text
                with client.websocket_connect("/ws") as ws:
                    ws.send_json(payload)
                    error = receive_type(ws, "error")
                    assert error["error"]["code"] == "storage_unavailable"
                    assert "private-canary" not in json.dumps(error)
                    ws.send_json({"type":"ping","t":1700000001})
                    assert receive_type(ws,"pong")["t"] == 1700000001
        ''')

    def test_csv_neutralizes_formula_text_but_not_numeric_coordinates(self):
        self.run_case('''
            notes = ["=1+1", " +1", "-1", "@command", "\\t=1", "plain"]
            for note in notes:
                assert client.post("/api/event", json={"v":1,"t":1700000000,"type":"MARK","note":note}).status_code == 200
            payload = {"v":1,"t":1700000000,"gps":{"lat":-1,"lon":-2},"meta":{"device":"=DEVICE", "source":"web"}}
            assert client.post("/api/gps", json=payload).status_code == 200
            with runtime.logger.events_path.open() as stream:
                rows = list(csv.DictReader(stream))
                assert [r["note"] for r in rows] == ["'" + n for n in notes[:-1]] + ["plain"]
            with runtime.logger.gps_path.open() as stream:
                row = list(csv.DictReader(stream))[0]
                assert float(row["lat"]) == -1 and row["device"] == "'=DEVICE"
        ''')

    def test_http_rejects_invalid_encoding_deep_json_and_nested_duplicate_fields(self):
        self.run_case('''
            invalid_json = [b"\\xff", b'{"v":1,"t":1,"gps":{"lat":0,"lat":2,"lon":0}}']
            for raw in invalid_json:
                response = client.post("/api/gps", content=raw)
                assert response.status_code == 400
                assert response.json()["error"]["code"] == "invalid_json"
            response = client.post("/api/gps", content=b"["*2000+b"0"+b"]"*2000)
            # Parser recursion limits vary. A parsed array is invalid schema, not invalid JSON.
            assert response.status_code in (400, 422)
            assert response.json()["error"]["code"] in ("invalid_json", "invalid_payload")
            raw = b'{"v":1,"t":1,"gps":{"lat":0,"lon":0,"spd":1e999}}'
            response = client.post("/api/gps", content=raw)
            assert response.status_code == 422
            assert response.json()["error"]["code"] == "invalid_payload"
            assert client.get("/api/ping").status_code == 200
            with runtime.logger.gps_path.open() as stream:
                assert list(csv.DictReader(stream)) == []
        ''')

    def test_http_requires_explicit_json_media_type(self):
        self.run_case('''
            raw = '{"v":1,"t":1700000000,"type":"MARK","note":"plain-form"}'
            for media in ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data", ""]:
                response = client.post("/api/event", content=raw, headers={"Content-Type":media})
                assert response.status_code == 415, (media, response.status_code)
                assert response.json()["error"]["code"] == "unsupported_media_type"
            with runtime.logger.events_path.open() as stream:
                assert list(csv.DictReader(stream)) == []
            response = client.post("/api/event", content=raw, headers={"Content-Type":"application/json; charset=utf-8"})
            assert response.status_code == 200
        ''')


if __name__ == "__main__":
    unittest.main()
