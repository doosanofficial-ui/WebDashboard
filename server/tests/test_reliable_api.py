from __future__ import annotations

import secrets
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient

from test_ingest import batch, gps
from ingest import MAX_BATCH_BYTES, TelemetryJournal
from reliable_api import router


class IngestApiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.db_path = Path(self.temp.name) / "telemetry.sqlite3"
        self.app = FastAPI()
        self.app.state.ingest_journal = TelemetryJournal(self.db_path)
        self.token = secrets.token_urlsafe(32)
        self.app.state.ingest_token = self.token
        self.app.include_router(router)
        self.client = TestClient(self.app, base_url="https://testserver")
        self.addCleanup(self.client.close)

    def post(self, payload):
        return self.client.post("/api/v2/ingest", json=payload,
                                headers={"Authorization": "Bearer " + self.token})

    def test_actual_response_ack_matches_committed_rows_and_replay(self):
        event = gps()
        response = self.post(batch(event))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"v": 2, "client_id": "device-1", "acked": [event["id"]]})
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(self.post(batch(event)).json(), response.json())
        with closing(sqlite3.connect(self.db_path)) as db, db:
            self.assertEqual(db.execute("SELECT count(*) FROM events").fetchone()[0], 1)

    def test_unpaired_request_is_rejected(self):
        response = self.client.post("/api/v2/ingest", json=batch(gps()))
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json()["error"]["code"], "unauthorized")

    def test_unconfigured_service_fails_closed(self):
        self.app.state.ingest_token = None
        response = self.post(batch(gps()))
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["error"]["code"], "ingest_unconfigured")

    def test_http_remote_request_cannot_send_credentials_or_data(self):
        with TestClient(self.app, base_url="http://testserver") as client:
            response = client.post("/api/v2/ingest", json=batch(gps()),
                                   headers={"Authorization": "Bearer " + self.token})
        self.assertEqual(response.status_code, 426)
        self.assertEqual(response.json()["error"]["code"], "https_required")

    def test_invalid_data_returns_safe_error_body_without_ack(self):
        event = gps()
        event["data"]["lat"] = "private-user-input"
        response = self.post(batch(event))
        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json()["error"]["code"], "invalid_batch")
        self.assertNotIn("acked", response.json())
        self.assertNotIn("private-user-input", response.text)
        self.assertFalse(self.token in response.text, "response leaked test auth material")

    def test_reused_id_has_409_body_and_preserves_original(self):
        event = gps()
        self.post(batch(event))
        event["data"]["spd"] = 20
        response = self.post(batch(event))
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["error"]["code"], "event_conflict")

    def test_database_failure_returns_no_ack_or_internal_error(self):
        with closing(sqlite3.connect(self.db_path)) as db, db:
            db.execute("CREATE TRIGGER fail_write BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'private-database-path'); END")
        response = self.post(batch(gps()))
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["error"]["code"], "storage_unavailable")
        self.assertNotIn("private-database-path", response.text)
        self.assertNotIn("acked", response.json())

    def test_body_limit_is_enforced(self):
        response = self.client.post("/api/v2/ingest", content=b" " * (MAX_BATCH_BYTES + 1),
                                    headers={"Authorization": "Bearer " + self.token})
        self.assertEqual(response.status_code, 413)
        self.assertEqual(response.json()["error"]["code"], "body_too_large")

    def test_duplicate_json_fields_and_nonobjects_are_rejected(self):
        for raw, status in [('not json', 400), ('{"v":2,"v":1}', 400), ('[]', 422), ('null', 422)]:
            with self.subTest(raw=raw):
                response = self.client.post("/api/v2/ingest", content=raw,
                                            headers={"Authorization": "Bearer " + self.token})
                self.assertEqual(response.status_code, status)
                self.assertIn("code", response.json()["error"])


if __name__ == "__main__":
    unittest.main()
