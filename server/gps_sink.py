from __future__ import annotations

from typing import Any


def extract_gps_row(payload: dict[str, Any]) -> dict[str, Any] | None:
    gps = payload.get("gps")
    if not isinstance(gps, dict):
        return None

    meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}

    return {
        "t": payload.get("t"),
        "lat": gps.get("lat"),
        "lon": gps.get("lon"),
        "spd": gps.get("spd"),
        "hdg": gps.get("hdg"),
        "acc": gps.get("acc"),
        "alt": gps.get("alt"),
        "source": meta.get("source"),
        "bg_state": meta.get("bg_state"),
        "os": meta.get("os"),
        "app_ver": meta.get("app_ver"),
        "device": meta.get("device"),
    }


def extract_event_row(payload: dict[str, Any]) -> dict[str, Any] | None:
    event_type = payload.get("type")
    if event_type is None:
        return None

    if str(event_type).upper() != "MARK":
        return None

    return {
        "t": payload.get("t"),
        "type": "MARK",
        "note": payload.get("note", ""),
    }
