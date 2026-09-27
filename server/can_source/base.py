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

    @property
    def is_ready(self) -> bool:
        """Whether at least one valid source sample is available."""
        return True

    @property
    def is_stale(self) -> bool:
        """Whether the latest source sample has exceeded its freshness limit."""
        return False

    @property
    def waits_for_first_frame(self) -> bool:
        """Whether server startup should wait for a first source sample."""
        return True

    def status(self) -> dict[str, object]:
        return {"ready": self.is_ready, "stale": self.is_stale}

    def close(self) -> None:
        """Release transport resources; sources without a transport are no-ops."""
        return None
