from __future__ import annotations

from .base import CANSource
from .dummy import DummyCANSource
from .frame import CANRawFrame
from .udp_json import UDPJsonCANSource
from .vector import VectorCANSource


def create_can_source(kind: str) -> CANSource:
    normalized = kind.strip().lower()
    if normalized == "dummy":
        return DummyCANSource()
    if normalized == "udp_json":
        return UDPJsonCANSource.from_environment()
    if normalized == "vector":
        return VectorCANSource.from_environment()

    raise ValueError(
        f"Unsupported CAN_SOURCE='{kind}'. Supported sources: 'dummy', 'udp_json', 'vector'. "
        "See can_source/adapters.md for integration options."
    )


__all__ = ["CANRawFrame", "CANSource", "DummyCANSource", "UDPJsonCANSource", "VectorCANSource", "create_can_source"]
