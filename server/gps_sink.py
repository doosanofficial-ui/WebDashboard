from __future__ import annotations

from typing import Any

from uplink import UplinkError, validate_uplink


def extract_gps_row(payload: dict[str, Any]) -> dict[str, Any] | None:
    try:
        kind, row = validate_uplink(payload)
    except UplinkError:
        return None
    return row if kind == "GPS" else None


def extract_event_row(payload: dict[str, Any]) -> dict[str, Any] | None:
    try:
        kind, row = validate_uplink(payload)
    except UplinkError:
        return None
    return row if kind == "MARK" else None
