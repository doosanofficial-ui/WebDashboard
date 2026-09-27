from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path


class LegacyAuthTests(unittest.TestCase):
    def test_production_legacy_uplink_requires_bearer_and_ws_auth_handshake(self):
        script = r'''
import tempfile
from dataclasses import replace
from pathlib import Path
from fastapi.testclient import TestClient
import config

with tempfile.TemporaryDirectory() as directory:
    config.settings = replace(
        config.settings,
        log_dir=Path(directory),
        ingest_token="test-secret",
        require_legacy_uplink_auth=True,
    )
    from app import app
    with TestClient(app, base_url="https://testserver") as client:
        payload = {"v": 1, "t": 1700000000, "type": "MARK", "note": "secure"}
        denied = client.post("/api/event", json=payload)
        assert denied.status_code == 401
        assert "test-secret" not in denied.text
        accepted = client.post(
            "/api/event", json=payload,
            headers={"Authorization": "Bearer test-secret"},
        )
        assert accepted.status_code == 200, accepted.text
        with client.websocket_connect("/ws") as ws:
            ws.send_json({"v": 1, "type": "auth", "token": "test-secret"})
            for _ in range(20):
                message = ws.receive_json()
                if message.get("type") == "auth_ok":
                    break
            else:
                raise AssertionError("WebSocket authentication did not complete")
'''
        result = subprocess.run(
            [sys.executable, "-B", "-c", script],
            cwd=Path(__file__).resolve().parents[1],
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
