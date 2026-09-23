from __future__ import annotations

import copy
import csv
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ingest import IngestConflict, IngestValidationError, TelemetryJournal


def gps(event_id="5c6a7f61-24c4-4ed9-8216-5fd0ffde1001"):
    return {
        "id": event_id, "type": "GPS", "captured_t": 1700000000,
        "data": {"lat": 37.0, "lon": 127.0, "spd": None, "hdg": None, "acc": 5.0, "alt": None},
        "meta": {"bg_state": "background", "os": "iOS"},
    }


def batch(*events, client_id="device-1"):
    return {"v": 2, "client_id": client_id, "events": list(events)}


class JournalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "telemetry.sqlite3"
        self.journal = TelemetryJournal(self.path)

    def rows(self):
        with sqlite3.connect(self.path) as db:
            db.row_factory = sqlite3.Row
            return [dict(row) for row in db.execute("SELECT * FROM events ORDER BY event_id")]

    def test_ack_means_data_is_committed_and_survives_reopening(self):
        event = gps()
        ack = self.journal.ingest(batch(event), received_t=1700000100)
        self.assertEqual(ack, {"v": 2, "client_id": "device-1", "acked": [event["id"]]})
        reopened = TelemetryJournal(self.path)
        self.assertEqual(reopened.ingest(batch(event), received_t=1700000200), ack)
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["captured_t"], 1700000000)
        self.assertEqual(rows[0]["received_t"], 1700000100)
        self.assertIsNone(json.loads(rows[0]["payload"])["data"]["spd"])

    def test_same_id_with_different_content_conflicts_without_overwriting(self):
        event = gps()
        self.journal.ingest(batch(event))
        changed = copy.deepcopy(event)
        changed["data"]["lat"] = 38.0
        with self.assertRaises(IngestConflict):
            self.journal.ingest(batch(changed))
        self.assertEqual(json.loads(self.rows()[0]["payload"])["data"]["lat"], 37.0)

    def test_conflict_rolls_back_new_events_in_the_same_batch(self):
        event = gps()
        self.journal.ingest(batch(event))
        changed = copy.deepcopy(event)
        changed["data"]["spd"] = 15
        new = gps("5c6a7f61-24c4-4ed9-8216-5fd0ffde1002")
        with self.assertRaises(IngestConflict):
            self.journal.ingest(batch(new, changed))
        self.assertEqual(len(self.rows()), 1)

    def test_invalid_item_rejects_entire_batch(self):
        invalid = gps("5c6a7f61-24c4-4ed9-8216-5fd0ffde1002")
        invalid["data"]["lat"] = None
        with self.assertRaises(IngestValidationError):
            self.journal.ingest(batch(gps(), invalid))
        self.assertEqual(self.rows(), [])

    def test_broken_database_write_never_returns_success(self):
        with sqlite3.connect(self.path) as db:
            db.execute("CREATE TRIGGER deny_insert BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'test disk write failure'); END")
        with self.assertRaises(sqlite3.DatabaseError):
            self.journal.ingest(batch(gps()))
        self.assertEqual(self.rows(), [])

    def test_idempotency_is_scoped_to_client(self):
        event = gps()
        self.journal.ingest(batch(event, client_id="device-1"))
        self.journal.ingest(batch(event, client_id="device-2"))
        self.assertEqual(len(self.rows()), 2)

    def test_duplicates_inside_batch_ack_once(self):
        event = gps()
        ack = self.journal.ingest(batch(event, event))
        self.assertEqual(ack["acked"], [event["id"]])
        self.assertEqual(len(self.rows()), 1)

    def test_numeric_zero_and_unknown_are_distinct(self):
        event = gps()
        event["data"].update(lat=0, lon=0, spd=0, hdg=0, acc=0, alt=-50)
        self.journal.ingest(batch(event))
        data = json.loads(self.rows()[0]["payload"])["data"]
        self.assertEqual(data, {"lat": 0, "lon": 0, "spd": 0, "hdg": 0, "acc": 0, "alt": -50})

    def test_invalid_numbers_and_fields_are_rejected(self):
        for key, value in [("lat", 91), ("lon", -181), ("lat", True), ("lat", "37"),
                           ("lat", float("nan")), ("spd", -1), ("spd", float("inf")),
                           ("hdg", 360), ("acc", -1), ("alt", "0")]:
            with self.subTest(key=key, value=value):
                event = gps()
                event["data"][key] = value
                with self.assertRaises(IngestValidationError):
                    self.journal.ingest(batch(event))
        self.assertEqual(self.rows(), [])

    def test_envelope_and_metadata_are_bounded(self):
        valid = batch(gps())
        invalids = [None, [], {}, {**valid, "v": True}, {**valid, "v": 1},
                    {**valid, "client_id": "../outside"}, {**valid, "client_id": "x" * 129},
                    {**valid, "events": []}, {**valid, "events": [gps()] * 201}]
        for value in invalids:
            with self.subTest(value=type(value).__name__):
                with self.assertRaises(IngestValidationError):
                    self.journal.ingest(value)
        for update in [{"captured_t": 0}, {"captured_t": True}, {"captured_t": float("nan")},
                       {"id": "not-a-uuid"}, {"type": "EXEC"}, {"meta": {"bg_state": "fake"}},
                       {"meta": {"device": "x" * 129}}, {"unexpected": True}]:
            with self.assertRaises(IngestValidationError):
                self.journal.ingest(batch({**gps(), **update}))

    def test_csv_export_preserves_capture_time_and_quotes_formula_notes(self):
        marker = {"id": "5c6a7f61-24c4-4ed9-8216-5fd0ffde1002", "type": "MARK",
                  "captured_t": 1700000001, "data": {"note": "=1+1"}}
        state = {"id": "5c6a7f61-24c4-4ed9-8216-5fd0ffde1003", "type": "STATE",
                 "captured_t": 1700000002, "data": {"state": "background"}}
        self.journal.ingest(batch(gps(), marker, state), received_t=1700000100)
        self.journal.ingest(batch(gps(), client_id="device-2"))
        output = io.StringIO()
        self.assertEqual(self.journal.export_csv(output, client_id="device-1"), 3)
        rows = list(csv.DictReader(io.StringIO(output.getvalue())))
        self.assertEqual(float(rows[0]["client_t"]), 1700000000)
        self.assertEqual(rows[0]["spd"], "")
        self.assertEqual(rows[1]["note"], "'=1+1")
        self.assertEqual(rows[2]["state"], "background")


if __name__ == "__main__":
    unittest.main()
