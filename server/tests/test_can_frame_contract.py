from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from can_source.frame import CANRawFrame, FrameContractError


class CANRawFrameTests(unittest.TestCase):
    def test_classical_can_uses_payload_length_as_dlc(self):
        frame = CANRawFrame(
            timestamp=1_700_000_000.25,
            arbitration_id=0x123,
            extended=False,
            is_fd=False,
            bitrate_switch=False,
            error_state_indicator=False,
            dlc=8,
            data=bytes(range(8)),
            source="canoe",
            channel="CAN1",
        )
        self.assertEqual(frame.data_length, 8)
        self.assertEqual(frame.to_dict()["data_length"], 8)
        self.assertFalse(frame.to_dict()["fd"])

    def test_can_fd_dlc_15_represents_64_bytes(self):
        frame = CANRawFrame(
            timestamp=1_700_000_000.25,
            arbitration_id=0x18DAF110,
            extended=True,
            is_fd=True,
            bitrate_switch=True,
            error_state_indicator=False,
            dlc=15,
            data=bytes(range(64)),
            source="vector",
            channel=0,
        )
        payload = frame.to_dict()
        self.assertEqual(frame.data_length, 64)
        self.assertEqual(payload["dlc"], 15)
        self.assertEqual(payload["data_length"], 64)
        self.assertTrue(payload["brs"])

    def test_invalid_fd_length_and_classical_flags_fail_closed(self):
        with self.assertRaises(FrameContractError):
            CANRawFrame(
                timestamp=1,
                arbitration_id=1,
                extended=False,
                is_fd=True,
                bitrate_switch=False,
                error_state_indicator=False,
                dlc=9,
                data=bytes(9),
                source="test",
                channel=None,
            )
        with self.assertRaises(FrameContractError):
            CANRawFrame(
                timestamp=1,
                arbitration_id=1,
                extended=False,
                is_fd=False,
                bitrate_switch=True,
                error_state_indicator=False,
                dlc=1,
                data=b"\\x00",
                source="test",
                channel=None,
            )

    def test_from_dict_round_trips_bridge_envelope(self):
        original = CANRawFrame(
            timestamp=1_700_000_000.25,
            arbitration_id=0x212,
            extended=False,
            is_fd=True,
            bitrate_switch=True,
            error_state_indicator=True,
            dlc=10,
            data=bytes(range(16)),
            source="canoe",
            channel="CAN1",
        )
        self.assertEqual(CANRawFrame.from_dict(original.to_dict()), original)

    def test_from_dict_rejects_coerced_flags_and_length_mismatch(self):
        payload = CANRawFrame(
            timestamp=1,
            arbitration_id=1,
            extended=False,
            is_fd=False,
            bitrate_switch=False,
            error_state_indicator=False,
            dlc=1,
            data=b"\x00",
            source="test",
            channel=None,
        ).to_dict()
        payload["fd"] = "false"
        with self.assertRaises(FrameContractError):
            CANRawFrame.from_dict(payload)
        payload["fd"] = False
        payload["data_length"] = 8
        with self.assertRaises(FrameContractError):
            CANRawFrame.from_dict(payload)


if __name__ == "__main__":
    unittest.main()
