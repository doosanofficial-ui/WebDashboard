"""Versioned, idempotent GPS/event journal. An ACK follows a durable commit."""
from __future__ import annotations

import csv
import json
import math
import re
import sqlite3
import time
from contextlib import closing
from pathlib import Path
from typing import Any, TextIO
from uuid import UUID

from csv_safety import csv_cell

MAX_BATCH_EVENTS = 200
MAX_BATCH_BYTES = 256 * 1024
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")


class IngestValidationError(ValueError):
    """Safe to report: messages contain field names, never supplied values."""


class IngestConflict(ValueError):
    """An event ID was reused with a different payload."""


def _object(value: Any, allowed: set[str], required: set[str]) -> dict:
    if not isinstance(value, dict) or not required <= value.keys() or value.keys() - allowed:
        raise IngestValidationError("Invalid object fields")
    return value


def _number(value: Any, name: str, *, low=None, high=None, nullable=False):
    if value is None and nullable:
        return None
    if type(value) not in (int, float):
        raise IngestValidationError(f"Invalid {name}")
    try:
        number = float(value)
    except (ValueError, OverflowError):
        raise IngestValidationError(f"Invalid {name}") from None
    if not math.isfinite(number) or (low is not None and number < low) or (high is not None and number > high):
        raise IngestValidationError(f"Invalid {name}")
    return number


def _text(value: Any, name: str, limit: int) -> str:
    if not isinstance(value, str) or len(value) > limit or "\x00" in value:
        raise IngestValidationError(f"Invalid {name}")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise IngestValidationError(f"Invalid {name}") from None
    return value


def _event(value: Any) -> dict:
    event = _object(value, {"id", "type", "captured_t", "data", "meta"}, {"id", "type", "captured_t", "data"})
    event_id = _text(event["id"], "id", 36)
    try:
        if str(UUID(event_id)) != event_id:
            raise ValueError()
    except ValueError:
        raise IngestValidationError("Invalid id") from None
    captured = _number(event["captured_t"], "captured_t", low=0)
    if captured == 0:
        raise IngestValidationError("Invalid captured_t")
    kind = event["type"]
    if kind == "GPS":
        raw = _object(event["data"], {"lat", "lon", "spd", "hdg", "acc", "alt"}, {"lat", "lon"})
        data = {
            "lat": _number(raw["lat"], "lat", low=-90, high=90),
            "lon": _number(raw["lon"], "lon", low=-180, high=180),
            "spd": _number(raw.get("spd"), "spd", low=0, nullable=True),
            "hdg": _number(raw.get("hdg"), "hdg", low=0, high=360, nullable=True),
            "acc": _number(raw.get("acc"), "acc", low=0, nullable=True),
            "alt": _number(raw.get("alt"), "alt", nullable=True),
        }
        if data["hdg"] == 360:
            raise IngestValidationError("Invalid hdg")
    elif kind == "MARK":
        raw = _object(event["data"], {"note"}, set())
        data = {"note": _text(raw.get("note", ""), "note", 500)}
    elif kind == "STATE":
        raw = _object(event["data"], {"state"}, {"state"})
        if raw["state"] not in ("foreground", "background", "stopped"):
            raise IngestValidationError("Invalid state")
        data = {"state": raw["state"]}
    else:
        raise IngestValidationError("Invalid event type")
    meta = _object(event.get("meta", {}), {"bg_state", "os", "app_ver", "device"}, set())
    for key, item in meta.items():
        _text(item, key, 128)
    if "bg_state" in meta and meta["bg_state"] not in ("foreground", "background"):
        raise IngestValidationError("Invalid bg_state")
    return {"id": event_id, "type": kind, "captured_t": captured, "data": data, "meta": dict(meta)}


def _batch(payload: Any) -> tuple[str, list[tuple[dict, str]]]:
    envelope = _object(payload, {"v", "client_id", "events"}, {"v", "client_id", "events"})
    if type(envelope["v"]) is not int or envelope["v"] != 2:
        raise IngestValidationError("Unsupported protocol version")
    client_id = _text(envelope["client_id"], "client_id", 128)
    if not IDENTIFIER.fullmatch(client_id):
        raise IngestValidationError("Invalid client_id")
    events = envelope["events"]
    if not isinstance(events, list) or not 1 <= len(events) <= MAX_BATCH_EVENTS:
        raise IngestValidationError("Invalid batch size")
    normalized = []
    total_bytes = 0
    for raw in events:
        event = _event(raw)
        encoded = json.dumps(event, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
        total_bytes += len(encoded.encode("utf-8"))
        if total_bytes > MAX_BATCH_BYTES:
            raise IngestValidationError("Batch exceeds size limit")
        normalized.append((event, encoded))
    return client_id, normalized


class TelemetryJournal:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with closing(self._connect()) as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("""CREATE TABLE IF NOT EXISTS events (
                client_id TEXT NOT NULL, event_id TEXT NOT NULL,
                captured_t REAL NOT NULL, received_t REAL NOT NULL,
                type TEXT NOT NULL, payload TEXT NOT NULL,
                PRIMARY KEY (client_id, event_id)
            ) WITHOUT ROWID""")
            db.commit()

    def _connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        db.execute("PRAGMA synchronous=FULL")
        return db

    def ingest(self, payload: Any, *, received_t: float | None = None) -> dict:
        client_id, events = _batch(payload)
        received = _number(time.time() if received_t is None else received_t, "received_t", low=0)
        acked = []
        with closing(self._connect()) as db:
            with db:
                db.execute("BEGIN IMMEDIATE")
                for event, encoded in events:
                    old = db.execute("SELECT payload FROM events WHERE client_id=? AND event_id=?",
                                     (client_id, event["id"])).fetchone()
                    if old:
                        if old[0] != encoded:
                            raise IngestConflict("Event ID already has different content")
                    else:
                        db.execute("INSERT INTO events VALUES (?, ?, ?, ?, ?, ?)",
                                   (client_id, event["id"], event["captured_t"], received, event["type"], encoded))
                    if event["id"] not in acked:
                        acked.append(event["id"])
        # The transaction context has committed before any caller can send this ACK.
        return {"v": 2, "client_id": client_id, "acked": acked}

    def export_csv(self, output: TextIO, *, client_id: str | None = None) -> int:
        columns = ["client_id", "event_id", "type", "client_t", "received_t", "bg_state",
                   "lat", "lon", "spd", "hdg", "acc", "alt", "note", "state"]
        writer = csv.DictWriter(output, fieldnames=columns)
        writer.writeheader()
        count = 0
        with closing(self._connect()) as db:
            sql = "SELECT client_id, event_id, type, captured_t, received_t, payload FROM events"
            params = ()
            if client_id is not None:
                sql += " WHERE client_id=?"
                params = (client_id,)
            sql += " ORDER BY captured_t, client_id, event_id"
            for client, event_id, kind, captured, received, encoded in db.execute(sql, params):
                event = json.loads(encoded)
                row = {"client_id": client, "event_id": event_id, "type": kind,
                       "client_t": captured, "received_t": received,
                       "bg_state": event["meta"].get("bg_state"), **event["data"]}
                writer.writerow({key: csv_cell(value) for key, value in row.items()})
                count += 1
        return count
