"""Bounded JSON and schema validation for the legacy v1 telemetry uplink."""
from __future__ import annotations

import json
import math
from typing import Any

MAX_UPLINK_BYTES = 16 * 1024
ERRORS = {
    "invalid_json": (400, "Expected UTF-8 JSON with unique fields and finite numbers"),
    "invalid_payload": (422, "Invalid telemetry fields, types or ranges"),
    "unsupported_version": (422, "Unsupported telemetry version"),
    "payload_too_large": (413, "Telemetry message exceeds the size limit"),
    "text_frame_required": (422, "Send JSON in a WebSocket text frame"),
    "unsupported_media_type": (415, "Content-Type must be application/json"),
    "storage_unavailable": (503, "CSV write could not be confirmed"),
}


class UplinkError(ValueError):
    def __init__(self, code: str):
        self.code = code
        self.status, message = ERRORS[code]
        super().__init__(message)

    def payload(self) -> dict:
        return {"error": {"code": self.code, "message": str(self)}}


def _object(value: Any, allowed: set[str], required: set[str]) -> dict:
    if not isinstance(value, dict) or not required <= value.keys() or value.keys() - allowed:
        raise UplinkError("invalid_payload")
    return value


def _number(value: Any, *, low=None, high=None, nullable=False):
    if value is None and nullable:
        return None
    if type(value) not in (int, float):
        raise UplinkError("invalid_payload")
    try:
        number = float(value)
    except (ValueError, OverflowError):
        raise UplinkError("invalid_payload") from None
    if not math.isfinite(number) or (low is not None and number < low) or (high is not None and number > high):
        raise UplinkError("invalid_payload")
    return number


def _timestamp(value: Any) -> float:
    number = _number(value, low=0)
    if number == 0:
        raise UplinkError("invalid_payload")
    return number


def _text(value: Any, limit: int) -> str:
    if not isinstance(value, str) or len(value) > limit or "\x00" in value:
        raise UplinkError("invalid_payload")
    try:
        value.encode("utf-8")
    except UnicodeError:
        raise UplinkError("invalid_payload") from None
    return value


def validate_uplink(payload: Any) -> tuple[str, dict[str, Any]]:
    if not isinstance(payload, dict):
        raise UplinkError("invalid_payload")
    ping = payload.get("type") == "ping"
    version = payload.get("v", 1 if ping else None)
    if type(version) is not int or version != 1:
        raise UplinkError("unsupported_version")
    if ping:
        _object(payload, {"v", "type", "t"}, {"type", "t"})
        return "ping", {"t": _timestamp(payload["t"])}
    if "gps" in payload:
        _object(payload, {"v", "t", "gps", "meta", "queued_at"}, {"v", "t", "gps"})
        gps = _object(payload["gps"], {"lat", "lon", "spd", "hdg", "acc", "alt"}, {"lat", "lon"})
        meta = _object(payload.get("meta", {}), {"source", "bg_state", "os", "app_ver", "device"}, set())
        for item in meta.values():
            _text(item, 128)
        if "bg_state" in meta and meta["bg_state"] not in ("foreground", "background"):
            raise UplinkError("invalid_payload")
        row = {"t": _timestamp(payload["t"]),
               "lat": _number(gps["lat"], low=-90, high=90),
               "lon": _number(gps["lon"], low=-180, high=180),
               "spd": _number(gps.get("spd"), low=0, nullable=True),
               "hdg": _number(gps.get("hdg"), low=0, high=360, nullable=True),
               "acc": _number(gps.get("acc"), low=0, nullable=True),
               "alt": _number(gps.get("alt"), nullable=True), **meta}
        if row["hdg"] == 360:
            raise UplinkError("invalid_payload")
        kind = "GPS"
    elif payload.get("type") == "MARK":
        _object(payload, {"v", "t", "type", "note", "queued_at"}, {"v", "t", "type"})
        row = {"t": _timestamp(payload["t"]), "type": "MARK", "note": _text(payload.get("note", ""), 500)}
        kind = "MARK"
    else:
        raise UplinkError("invalid_payload")
    if "queued_at" in payload:
        _timestamp(payload["queued_at"])
    return kind, row


def _unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_field")
        result[key] = value
    return result


def _reject_constant(_):
    raise ValueError("nonfinite_json_constant")


def decode_uplink(raw: str | bytes | bytearray) -> tuple[str, dict[str, Any]]:
    try:
        encoded = raw.encode("utf-8") if isinstance(raw, str) else raw
    except UnicodeError:
        raise UplinkError("invalid_json") from None
    if len(encoded) > MAX_UPLINK_BYTES:
        raise UplinkError("payload_too_large")
    try:
        payload = json.loads(encoded.decode("utf-8"), object_pairs_hook=_unique_fields,
                             parse_constant=_reject_constant)
    except (ValueError, UnicodeError, RecursionError):
        raise UplinkError("invalid_json") from None
    return validate_uplink(payload)
