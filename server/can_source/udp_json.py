from __future__ import annotations

import json
import math
import os
import socket
import threading
import time
from typing import Any

from .base import CANSource
from .frame import CANRawFrame, FrameContractError


def _unique_fields(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_field")
        result[key] = value
    return result


def _reject_constant(_: str) -> None:
    raise ValueError("nonfinite_json_constant")


class UDPJsonCANSource(CANSource):
    """Receives complete decoded/raw samples from a local CANoe/MATLAB bridge."""

    def __init__(
        self,
        bind_host: str,
        port: int,
        *,
        stale_after: float = 2.0,
        max_datagram_bytes: int = 64 * 1024,
    ) -> None:
        if not isinstance(bind_host, str) or not bind_host:
            raise ValueError("CAN_UDP_HOST must be a non-empty string")
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError("CAN_UDP_PORT must be between 1 and 65535")
        if not math.isfinite(stale_after) or stale_after <= 0:
            raise ValueError("CAN_SOURCE_STALE_AFTER must be positive")
        if type(max_datagram_bytes) is not int or not 1024 <= max_datagram_bytes <= 1024 * 1024:
            raise ValueError("CAN_UDP_MAX_DATAGRAM_BYTES is out of range")

        self.bind_host = bind_host
        self.port = port
        self.stale_after = stale_after
        self.max_datagram_bytes = max_datagram_bytes
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._latest_sig: dict[str, float] | None = None
        self._latest_raw: CANRawFrame | None = None
        self._last_received_monotonic: float | None = None
        self._last_source_timestamp: float | None = None
        self._invalid_datagrams = 0
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._socket.bind((bind_host, port))
        self._socket.settimeout(0.1)
        self._thread = threading.Thread(target=self._receive_loop, name="telemetry-udp-can", daemon=True)
        self._thread.start()

    @classmethod
    def from_environment(cls) -> UDPJsonCANSource:
        host = os.getenv("CAN_UDP_HOST", "127.0.0.1")
        port = int(os.getenv("CAN_UDP_PORT", "29999"))
        stale_after = float(os.getenv("CAN_SOURCE_STALE_AFTER", "2.0"))
        max_datagram_bytes = int(os.getenv("CAN_UDP_MAX_DATAGRAM_BYTES", str(64 * 1024)))
        return cls(host, port, stale_after=stale_after, max_datagram_bytes=max_datagram_bytes)

    @property
    def is_ready(self) -> bool:
        with self._lock:
            return self._latest_sig is not None

    @property
    def is_stale(self) -> bool:
        with self._lock:
            return self._is_stale_locked()

    @property
    def waits_for_first_frame(self) -> bool:
        return False

    @property
    def invalid_datagrams(self) -> int:
        with self._lock:
            return self._invalid_datagrams

    def next_frame(self) -> dict[str, float]:
        with self._lock:
            if self._latest_sig is None or self._is_stale_locked():
                return {}
            return dict(self._latest_sig)

    def next_raw_frame(self) -> CANRawFrame | None:
        with self._lock:
            if self._latest_sig is None or self._is_stale_locked():
                return None
            return self._latest_raw

    def status(self) -> dict[str, object]:
        with self._lock:
            age_ms = None
            if self._last_received_monotonic is not None:
                age_ms = round((time.monotonic() - self._last_received_monotonic) * 1000)
            return {
                "ready": self._latest_sig is not None,
                "stale": self._is_stale_locked(),
                "invalid_datagrams": self._invalid_datagrams,
                "last_source_age_ms": age_ms,
                "last_source_t": self._last_source_timestamp,
                "bind_host": self.bind_host,
                "port": self.port,
            }

    def close(self) -> None:
        self._stop.set()
        try:
            self._socket.close()
        finally:
            self._thread.join(timeout=0.5)

    def _is_stale_locked(self) -> bool:
        return (
            self._last_received_monotonic is None
            or time.monotonic() - self._last_received_monotonic > self.stale_after
        )

    def _receive_loop(self) -> None:
        while not self._stop.is_set():
            try:
                data, _ = self._socket.recvfrom(self.max_datagram_bytes + 1)
            except socket.timeout:
                continue
            except OSError:
                return
            if len(data) > self.max_datagram_bytes:
                self._mark_invalid()
                continue
            try:
                sample = self._decode(data)
            except (FrameContractError, UnicodeError, ValueError, TypeError, KeyError):
                self._mark_invalid()
                continue
            with self._lock:
                self._latest_sig, self._latest_raw, self._last_source_timestamp = sample
                self._last_received_monotonic = time.monotonic()

    def _decode(self, data: bytes) -> tuple[dict[str, float], CANRawFrame | None, float]:
        payload = json.loads(data.decode("utf-8"), object_pairs_hook=_unique_fields,
                             parse_constant=_reject_constant)
        if not isinstance(payload, dict) or payload.get("v") != 1:
            raise ValueError("unsupported_version")
        timestamp = payload["t"]
        if type(timestamp) not in (int, float) or not math.isfinite(timestamp) or timestamp <= 0:
            raise ValueError("invalid_timestamp")
        raw_sig = payload.get("sig")
        if not isinstance(raw_sig, dict) or not raw_sig:
            raise ValueError("invalid_signal_snapshot")
        sig: dict[str, float] = {}
        for key, value in raw_sig.items():
            if not isinstance(key, str) or not key or len(key.encode("utf-8")) > 128:
                raise ValueError("invalid_signal_name")
            if type(value) not in (int, float) or not math.isfinite(value):
                raise ValueError("invalid_signal_value")
            sig[key] = float(value)
        raw_payload = payload.get("raw")
        raw = None if raw_payload is None else CANRawFrame.from_dict(raw_payload)
        return sig, raw, float(timestamp)

    def _mark_invalid(self) -> None:
        with self._lock:
            self._invalid_datagrams = min(self._invalid_datagrams + 1, 2**31 - 1)
