from __future__ import annotations

import unittest

from can_source.frame import CANRawFrame
from can_source.signal_decoder import CANSignalDecoder, SignalRule


class CANSignalDecoderTests(unittest.TestCase):
    def test_invalid_rule_flags_fail_closed(self):
        with self.assertRaises(ValueError):
            SignalRule("x", "x", 1, "false", 0, 1, "intel", False)
        with self.assertRaises(ValueError):
            SignalRule("x", "x", 1, False, 0, 1, "intel", "false")

    def test_intel_unsigned_and_signed_values_are_decoded_from_classical_can(self):
        decoder = CANSignalDecoder([
            SignalRule("speed_raw", "speed_raw", 0x123, False, 0, 16, "intel", False),
            SignalRule("signed_raw", "signed_raw", 0x123, False, 16, 8, "intel", True),
        ])
        frame = CANRawFrame(1, 0x123, False, False, False, False, 3, bytes([0x34, 0x12, 0xFE]), "vector", 0)
        self.assertEqual(decoder.decode(frame), {"speed_raw": 0x1234, "signed_raw": -2.0})

    def test_motorola_cross_byte_value_and_can_fd_payload_are_supported(self):
        decoder = CANSignalDecoder([
            SignalRule("value", "value", 0x212, False, 15, 9, "motorola", False),
        ])
        frame = CANRawFrame(
            1, 0x212, False, True, True, False, 9,
            bytes([0x00, 0x01] + [0] * 10), "vector", "CAN1",
        )
        self.assertEqual(decoder.decode(frame), {"value": 2.0})

    def test_nonmatching_and_short_frames_produce_no_signal(self):
        decoder = CANSignalDecoder([
            SignalRule("value", "value", 0x212, False, 0, 16, "intel", False),
        ])
        self.assertEqual(decoder.decode(CANRawFrame(1, 0x211, False, False, False, False, 1, b"\x00", "vector", 0)), {})
        self.assertEqual(decoder.decode(CANRawFrame(1, 0x212, False, False, False, False, 1, b"\x00", "vector", 0)), {})
