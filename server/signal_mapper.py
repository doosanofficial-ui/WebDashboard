from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

log = logging.getLogger("signal-mapper")


def _to_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _load_json(path: Path) -> dict[str, Any] | None:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        log.warning("signals config not found: %s (raw passthrough mode)", path)
        return None
    except OSError as exc:
        log.warning("failed to read signals config %s: %s", path, exc)
        return None

    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        log.warning("invalid JSON in signals config %s: %s", path, exc)
        return None

    if not isinstance(payload, dict):
        log.warning("signals config root must be object: %s", path)
        return None
    return payload


class SignalMapper:
    """Maps raw CAN signal dict using signals.json rules.

    If config is missing or invalid, mapper falls back to raw float passthrough.
    """

    def __init__(self, config_path: Path) -> None:
        self.config_path = config_path
        self.rules: dict[str, dict[str, Any]] = {}
        self.reload()

    def reload(self) -> None:
        payload = _load_json(self.config_path)
        if not payload:
            self.rules = {}
            return

        raw_signals = payload.get("signals")
        if not isinstance(raw_signals, dict):
            log.warning("signals config missing 'signals' object: %s", self.config_path)
            self.rules = {}
            return

        rules: dict[str, dict[str, Any]] = {}
        for output_key, rule in raw_signals.items():
            if not isinstance(output_key, str):
                continue
            if not isinstance(rule, dict):
                continue

            source = rule.get("source", output_key)
            if not isinstance(source, str) or not source:
                source = output_key

            enabled = bool(rule.get("enabled", True))
            scale = _to_float(rule.get("scale"))
            offset = _to_float(rule.get("offset"))
            min_value = _to_float(rule.get("min"))
            max_value = _to_float(rule.get("max"))

            decimals_raw = rule.get("decimals")
            decimals: int | None
            if decimals_raw is None:
                decimals = None
            elif isinstance(decimals_raw, int):
                decimals = max(0, min(6, decimals_raw))
            else:
                coerced = _to_float(decimals_raw)
                decimals = max(0, min(6, int(coerced))) if coerced is not None else None

            rules[output_key] = {
                "source": source,
                "enabled": enabled,
                "scale": scale if scale is not None else 1.0,
                "offset": offset if offset is not None else 0.0,
                "min": min_value,
                "max": max_value,
                "decimals": decimals,
            }

        self.rules = rules
        log.info("signals config loaded: %s (%d signals)", self.config_path, len(self.rules))

    def apply(self, raw_signals: dict[str, Any]) -> dict[str, float]:
        if not isinstance(raw_signals, dict):
            return {}

        # Fallback path: no config loaded -> pass through numeric values.
        if not self.rules:
            mapped: dict[str, float] = {}
            for key, value in raw_signals.items():
                if not isinstance(key, str):
                    continue
                number = _to_float(value)
                if number is None:
                    continue
                mapped[key] = number
            return mapped

        mapped: dict[str, float] = {}
        for output_key, rule in self.rules.items():
            if not rule.get("enabled", True):
                continue

            source = rule["source"]
            raw = raw_signals.get(source)
            value = _to_float(raw)
            if value is None:
                continue

            value = value * rule["scale"] + rule["offset"]

            min_value = rule["min"]
            max_value = rule["max"]
            if min_value is not None:
                value = max(min_value, value)
            if max_value is not None:
                value = min(max_value, value)

            decimals = rule["decimals"]
            if decimals is not None:
                value = round(value, decimals)

            mapped[output_key] = value

        return mapped
