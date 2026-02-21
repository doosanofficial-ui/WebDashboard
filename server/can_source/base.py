from __future__ import annotations

from abc import ABC, abstractmethod


class CANSource(ABC):
    """Abstract CAN source. Replace implementation only, keep frame contract stable."""

    @abstractmethod
    def next_frame(self) -> dict[str, float]:
        """Return the next signal snapshot used in WS payload `sig` field."""
        raise NotImplementedError
