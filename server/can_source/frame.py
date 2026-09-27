from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any

CAN_FD_DLC_LENGTHS = (0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64)


class FrameContractError(ValueError):
    """Raised when a raw CAN/CAN-FD frame violates the bridge contract."""


def dlc_to_length(dlc: int, is_fd: bool) -> int:
    if type(dlc) is not int:
        raise FrameContractError("dlc_must_be_integer")
    if not 0 <= dlc <= 15:
        raise FrameContractError("dlc_out_of_range")
    if is_fd:
        return CAN_FD_DLC_LENGTHS[dlc]
    if dlc > 8:
        raise FrameContractError("classical_can_dlc_out_of_range")
    return dlc


def length_to_dlc(length: int, is_fd: bool) -> int:
    if type(length) is not int or length < 0:
        raise FrameContractError("data_length_out_of_range")
    if not is_fd:
        if length > 8:
            raise FrameContractError("classical_can_data_too_long")
        return length
    try:
        return CAN_FD_DLC_LENGTHS.index(length)
    except ValueError as exc:
        raise FrameContractError("invalid_can_fd_data_length") from exc


@dataclass(frozen=True)
class CANRawFrame:
    timestamp: float
    arbitration_id: int
    extended: bool
    is_fd: bool
    bitrate_switch: bool
    error_state_indicator: bool
    dlc: int
    data: bytes
    source: str
    channel: int | str | None

    def __post_init__(self) -> None:
        if type(self.timestamp) not in (int, float) or not math.isfinite(self.timestamp):
            raise FrameContractError("timestamp_not_finite")
        if type(self.arbitration_id) is not int or self.arbitration_id < 0:
            raise FrameContractError("arbitration_id_invalid")
        maximum_id = 0x1FFF_FFFF if self.extended else 0x7FF
        if self.arbitration_id > maximum_id:
            raise FrameContractError("arbitration_id_out_of_range")
        if type(self.extended) is not bool or type(self.is_fd) is not bool:
            raise FrameContractError("frame_flags_invalid")
        if type(self.bitrate_switch) is not bool or type(self.error_state_indicator) is not bool:
            raise FrameContractError("fd_flags_invalid")
        if not self.is_fd and (self.bitrate_switch or self.error_state_indicator):
            raise FrameContractError("fd_flags_on_classical_frame")
        expected_length = dlc_to_length(self.dlc, self.is_fd)
        if type(self.data) is not bytes:
            raise FrameContractError("data_must_be_bytes")
        if len(self.data) != expected_length:
            raise FrameContractError("data_length_mismatch")
        if not isinstance(self.source, str) or not self.source or len(self.source.encode("utf-8")) > 128:
            raise FrameContractError("source_invalid")
        if self.channel is not None and (
            type(self.channel) not in (str, int)
            or (isinstance(self.channel, str) and len(self.channel.encode("utf-8")) > 128)
        ):
            raise FrameContractError("channel_invalid")

    @property
    def data_length(self) -> int:
        return len(self.data)

    def to_dict(self) -> dict[str, Any]:
        return {
            "t": self.timestamp,
            "channel": self.channel,
            "source": self.source,
            "arbitration_id": self.arbitration_id,
            "extended": self.extended,
            "fd": self.is_fd,
            "brs": self.bitrate_switch,
            "esi": self.error_state_indicator,
            "dlc": self.dlc,
            "data_length": self.data_length,
            "data": list(self.data),
        }

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> CANRawFrame:
        if not isinstance(payload, dict):
            raise FrameContractError("raw_frame_must_be_object")
        data = payload.get("data")
        if not isinstance(data, list) or any(type(item) is not int or not 0 <= item <= 255 for item in data):
            raise FrameContractError("data_must_be_byte_array")
        required = ("t", "source", "arbitration_id", "dlc")
        if any(key not in payload for key in required):
            raise FrameContractError("raw_frame_required_field_missing")
        boolean_fields = ("extended", "fd", "brs", "esi")
        for key in boolean_fields:
            if key in payload and type(payload[key]) is not bool:
                raise FrameContractError("frame_flags_invalid")
        data_length = payload.get("data_length")
        if data_length is not None and type(data_length) is not int:
            raise FrameContractError("data_length_out_of_range")
        if data_length is not None and data_length != len(data):
            raise FrameContractError("data_length_mismatch")
        return cls(
            timestamp=payload["t"],
            channel=payload.get("channel"),
            source=payload["source"],
            arbitration_id=payload["arbitration_id"],
            extended=payload.get("extended", False),
            is_fd=payload.get("fd", False),
            bitrate_switch=payload.get("brs", False),
            error_state_indicator=payload.get("esi", False),
            dlc=payload["dlc"],
            data=bytes(data),
        )

    @classmethod
    def from_python_can(
        cls,
        message: Any,
        *,
        source: str,
        channel: int | str | None = None,
    ) -> CANRawFrame:
        data = bytes(message.data)
        is_fd = bool(getattr(message, "is_fd", False))
        raw_dlc = getattr(message, "raw_dlc", None)
        if raw_dlc is None:
            raw_dlc = length_to_dlc(len(data), is_fd)
        return cls(
            timestamp=float(message.timestamp),
            channel=channel if channel is not None else getattr(message, "channel", None),
            source=source,
            arbitration_id=int(message.arbitration_id),
            extended=bool(getattr(message, "is_extended_id", False)),
            is_fd=is_fd,
            bitrate_switch=bool(getattr(message, "bitrate_switch", False)),
            error_state_indicator=bool(getattr(message, "error_state_indicator", False)),
            dlc=int(raw_dlc),
            data=data,
        )
