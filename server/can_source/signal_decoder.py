from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

from .frame import CANRawFrame


@dataclass(frozen=True)
class SignalRule:
    output: str
    source: str
    can_id: int
    extended: bool
    start_bit: int
    bit_length: int
    byte_order: str
    signed: bool

    def __post_init__(self) -> None:
        if not self.output or not self.source:
            raise ValueError("signal_name_required")
        maximum_id = 0x1FFF_FFFF if self.extended else 0x7FF
        if type(self.can_id) is not int or not 0 <= self.can_id <= maximum_id:
            raise ValueError("signal_can_id_invalid")
        if type(self.start_bit) is not int or self.start_bit < 0:
            raise ValueError("signal_start_bit_invalid")
        if type(self.bit_length) is not int or not 1 <= self.bit_length <= 64:
            raise ValueError("signal_bit_length_invalid")
        if self.byte_order not in {"intel", "motorola"}:
            raise ValueError("signal_byte_order_invalid")


class CANSignalDecoder:
    def __init__(self, rules: list[SignalRule]):
        self.rules = tuple(rules)

    @classmethod
    def from_json(cls, path: Path) -> CANSignalDecoder:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict) or not isinstance(payload.get("signals"), dict):
            raise ValueError("signal_config_invalid")
        rules: list[SignalRule] = []
        for output, config in payload["signals"].items():
            if not isinstance(output, str) or not isinstance(config, dict) or not config.get("enabled", True):
                continue
            if "can_id" not in config:
                continue
            rules.append(SignalRule(
                output=output,
                source=config.get("source", output),
                can_id=config["can_id"],
                extended=config.get("extended", False),
                start_bit=config["start_bit"],
                bit_length=config["bit_length"],
                byte_order=config.get("byte_order", "intel").lower(),
                signed=config.get("signed", config.get("is_signed", False)),
            ))
        return cls(rules)

    def decode(self, frame: CANRawFrame) -> dict[str, float]:
        decoded: dict[str, float] = {}
        for rule in self.rules:
            if frame.arbitration_id != rule.can_id or frame.extended != rule.extended:
                continue
            positions = self._bit_positions(rule)
            if not positions or max(positions) >= frame.data_length * 8:
                continue
            raw = 0
            if rule.byte_order == "intel":
                for offset, position in enumerate(positions):
                    raw |= ((frame.data[position // 8] >> (position % 8)) & 1) << offset
            else:
                for position in positions:
                    raw = (raw << 1) | ((frame.data[position // 8] >> (position % 8)) & 1)
            if rule.signed:
                sign_bit = 1 << (rule.bit_length - 1)
                if raw & sign_bit:
                    raw -= 1 << rule.bit_length
            decoded[rule.source] = float(raw)
        return decoded

    @staticmethod
    def _bit_positions(rule: SignalRule) -> list[int]:
        if rule.byte_order == "intel":
            return list(range(rule.start_bit, rule.start_bit + rule.bit_length))
        positions: list[int] = []
        bit = rule.start_bit
        for _ in range(rule.bit_length):
            positions.append(bit)
            bit_in_byte = bit % 8
            bit = bit + 15 if bit_in_byte == 0 else bit - 1
        return positions
