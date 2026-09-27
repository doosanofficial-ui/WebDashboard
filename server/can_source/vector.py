from __future__ import annotations

import math
import os
import threading
import time
from typing import Any

from .base import CANSource
from .frame import CANRawFrame
from .signal_decoder import CANSignalDecoder


def _bool_env(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


class VectorCANSource(CANSource):
    """Optional python-can Vector backend for VN1600/VN1640A raw capture."""

    def __init__(
        self,
        *,
        bus: Any | None = None,
        decoder: CANSignalDecoder | None = None,
        channel: int | str = 0,
        stale_after: float = 2.0,
    ) -> None:
        if not math.isfinite(stale_after) or stale_after <= 0:
            raise ValueError("VECTOR_STALE_AFTER must be positive")
        self.decoder = decoder or CANSignalDecoder([])
        self.channel = channel
        self.stale_after = stale_after
        self._bus = bus if bus is not None else self._open_bus(channel)
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._latest_raw: CANRawFrame | None = None
        self._latest_sig: dict[str, float] = {}
        self._last_received_monotonic: float | None = None
        self._invalid_frames = 0
        self._thread = threading.Thread(target=self._receive_loop, name="telemetry-vector-can", daemon=True)
        self._thread.start()

    @classmethod
    def from_environment(cls) -> VectorCANSource:
        channel_raw = os.getenv("VECTOR_CHANNEL", "0")
        channel: int | str = int(channel_raw) if channel_raw.isdigit() else channel_raw
        return cls(
            channel=channel,
            stale_after=float(os.getenv("VECTOR_STALE_AFTER", "2.0")),
        )

    @staticmethod
    def _open_bus(channel: int | str) -> Any:
        try:
            import can
        except ImportError as exc:
            raise RuntimeError("python-can is required for CAN_SOURCE=vector") from exc
        kwargs: dict[str, Any] = {
            "interface": "vector",
            "channel": channel,
            "app_name": os.getenv("VECTOR_APP_NAME", "TelemetryDashboard"),
            "bitrate": int(os.getenv("VECTOR_BITRATE", "500000")),
        }
        if _bool_env("VECTOR_FD"):
            kwargs["fd"] = True
            kwargs["data_bitrate"] = int(os.getenv("VECTOR_DATA_BITRATE", "2000000"))
        return can.Bus(**kwargs)

    @property
    def is_ready(self) -> bool:
        with self._lock:
            return self._latest_raw is not None

    @property
    def is_stale(self) -> bool:
        with self._lock:
            return self._is_stale_locked()

    def next_frame(self) -> dict[str, float]:
        with self._lock:
            return {} if self._is_stale_locked() else dict(self._latest_sig)

    def next_raw_frame(self) -> CANRawFrame | None:
        with self._lock:
            return None if self._is_stale_locked() else self._latest_raw

    def status(self) -> dict[str, object]:
        with self._lock:
            age_ms = None if self._last_received_monotonic is None else round(
                (time.monotonic() - self._last_received_monotonic) * 1000
            )
            return {
                "ready": self._latest_raw is not None,
                "stale": self._is_stale_locked(),
                "invalid_frames": self._invalid_frames,
                "decoded_signals": len(self._latest_sig),
                "last_source_age_ms": age_ms,
                "channel": self.channel,
            }

    def close(self) -> None:
        self._stop.set()
        try:
            self._bus.shutdown()
        finally:
            self._thread.join(timeout=0.5)

    def _is_stale_locked(self) -> bool:
        return self._last_received_monotonic is None or (
            time.monotonic() - self._last_received_monotonic > self.stale_after
        )

    def _receive_loop(self) -> None:
        while not self._stop.is_set():
            try:
                message = self._bus.recv(timeout=0.1)
                if message is None:
                    continue
                raw = CANRawFrame.from_python_can(message, source="vector", channel=self.channel)
                decoded = self.decoder.decode(raw)
            except Exception:
                with self._lock:
                    self._invalid_frames = min(self._invalid_frames + 1, 2**31 - 1)
                continue
            with self._lock:
                self._latest_raw = raw
                self._latest_sig = decoded
                self._last_received_monotonic = time.monotonic()
