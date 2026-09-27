from __future__ import annotations

from abc import ABC, abstractmethod

from .frame import CANRawFrame


class CANSource(ABC):
    """Abstract signal/raw source used by the 10 Hz publisher."""

    @abstractmethod
    def next_frame(self) -> dict[str, float]:
        """Return the latest decoded signal snapshot."""
        raise NotImplementedError

    def next_raw_frame(self) -> CANRawFrame | None:
        """Return the latest raw frame when the source can provide one."""
        return None

    def close(self) -> None:
        """Release transport resources; sources without a transport are no-ops."""
        return None
