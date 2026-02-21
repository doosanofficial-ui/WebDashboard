from __future__ import annotations

import math
import random
import time

from .base import CANSource


class DummyCANSource(CANSource):
    """Generates deterministic-ish telemetry for MVP UI and reconnect/load testing."""

    def __init__(self, seed: int = 7) -> None:
        self._start = time.perf_counter()
        self._rng = random.Random(seed)

    def next_frame(self) -> dict[str, float]:
        t = time.perf_counter() - self._start

        base_speed_ms = 14.0 + 3.5 * math.sin(t * 0.37)
        wheel_mod = 0.45 * math.sin(t * 3.4)

        ws_fl = base_speed_ms + wheel_mod + self._noise(0.12)
        ws_fr = base_speed_ms - wheel_mod + self._noise(0.12)
        ws_rl = base_speed_ms + 0.25 * math.sin(t * 2.3) + self._noise(0.10)
        ws_rr = base_speed_ms - 0.25 * math.sin(t * 2.3) + self._noise(0.10)

        yaw_dps = 12.0 * math.sin(t * 0.9) + self._noise(0.5)
        ax_ms2 = 1.9 * math.sin(t * 0.55) + self._noise(0.1)
        ay_ms2 = 1.4 * math.cos(t * 0.8) + self._noise(0.1)

        return {
            "ws_fl": ws_fl * 3.6,
            "ws_fr": ws_fr * 3.6,
            "ws_rl": ws_rl * 3.6,
            "ws_rr": ws_rr * 3.6,
            "yaw": yaw_dps,
            "ax": ax_ms2,
            "ay": ay_ms2,
        }

    def _noise(self, scale: float) -> float:
        return self._rng.uniform(-scale, scale)
