from __future__ import annotations

import csv
from datetime import datetime
from pathlib import Path
from threading import Lock
from typing import Any


class SessionCsvLogger:
    def __init__(self, log_dir: Path, session_id: str | None = None) -> None:
        self._lock = Lock()
        self.log_dir = log_dir
        self.log_dir.mkdir(parents=True, exist_ok=True)

        self.session_id = session_id or datetime.now().strftime("%Y%m%d_%H%M%S")

        self.can_path = self.log_dir / f"can_{self.session_id}.csv"
        self.gps_path = self.log_dir / f"gps_{self.session_id}.csv"
        self.events_path = self.log_dir / f"events_{self.session_id}.csv"

        self._can_file, self._can_writer = self._open_writer(
            self.can_path,
            [
                "server_t",
                "seq",
                "drop",
                "ws_fl",
                "ws_fr",
                "ws_rl",
                "ws_rr",
                "yaw",
                "ax",
                "ay",
            ],
        )
        self._gps_file, self._gps_writer = self._open_writer(
            self.gps_path,
            ["client_t", "lat", "lon", "spd", "hdg", "acc", "alt"],
        )
        self._events_file, self._events_writer = self._open_writer(
            self.events_path,
            ["client_t", "type", "note"],
        )

    @staticmethod
    def _open_writer(path: Path, header: list[str]) -> tuple[Any, csv.writer]:
        fp = path.open("w", newline="", encoding="utf-8")
        writer = csv.writer(fp)
        writer.writerow(header)
        fp.flush()
        return fp, writer

    def log_can(self, frame: dict[str, Any]) -> None:
        sig = frame.get("sig", {})
        status = frame.get("status", {})
        with self._lock:
            self._can_writer.writerow(
                [
                    frame.get("t"),
                    status.get("seq"),
                    status.get("drop"),
                    sig.get("ws_fl"),
                    sig.get("ws_fr"),
                    sig.get("ws_rl"),
                    sig.get("ws_rr"),
                    sig.get("yaw"),
                    sig.get("ax"),
                    sig.get("ay"),
                ]
            )
            self._can_file.flush()

    def log_gps(self, row: dict[str, Any]) -> None:
        with self._lock:
            self._gps_writer.writerow(
                [
                    row.get("t"),
                    row.get("lat"),
                    row.get("lon"),
                    row.get("spd"),
                    row.get("hdg"),
                    row.get("acc"),
                    row.get("alt"),
                ]
            )
            self._gps_file.flush()

    def log_event(self, row: dict[str, Any]) -> None:
        with self._lock:
            self._events_writer.writerow([row.get("t"), row.get("type"), row.get("note", "")])
            self._events_file.flush()

    def close(self) -> None:
        with self._lock:
            self._can_file.close()
            self._gps_file.close()
            self._events_file.close()
