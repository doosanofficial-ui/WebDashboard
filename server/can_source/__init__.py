from __future__ import annotations

from .base import CANSource
from .dummy import DummyCANSource


def create_can_source(kind: str) -> CANSource:
    normalized = kind.strip().lower()
    if normalized == "dummy":
        return DummyCANSource()

    raise ValueError(
        f"Unsupported CAN_SOURCE='{kind}'. Only 'dummy' is bundled in MVP. "
        "See can_source/adapters.md for integration options."
    )


__all__ = ["CANSource", "DummyCANSource", "create_can_source"]
