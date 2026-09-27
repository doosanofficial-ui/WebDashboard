from __future__ import annotations

import queue
import time
import unittest

from can_source.frame import CANRawFrame
from can_source.signal_decoder import CANSignalDecoder, SignalRule
from can_source.vector import VectorCANSource


class FakeMessage:
    timestamp = 1.0
    arbitration_id = 0x123
    is_extended_id = False
    is_fd = False
    bitrate_switch = False
    error_state_indicator = False
    raw_dlc = 2
    channel = 0
    data = bytes([0x34, 0x12])


class FakeBus:
    def __init__(self):
        self.messages = queue.Queue()
        self.closed = False

    def recv(self, timeout):
        try:
            return self.messages.get(timeout=timeout)
        except queue.Empty:
            return None

    def shutdown(self):
        self.closed = True


class VectorCANSourceTests(unittest.TestCase):
    def test_injected_bus_publishes_raw_frame_and_decoded_signals(self):
        bus = FakeBus()
        decoder = CANSignalDecoder([
            SignalRule("speed_raw", "speed_raw", 0x123, False, 0, 16, "intel", False),
        ])
        source = VectorCANSource(bus=bus, decoder=decoder, stale_after=1.0)
        self.addCleanup(source.close)
        bus.messages.put(FakeMessage())
        deadline = time.monotonic() + 1
        while not source.is_ready and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(source.is_ready)
        self.assertEqual(source.next_frame(), {"speed_raw": 0x1234})
        self.assertEqual(source.next_raw_frame().arbitration_id, 0x123)
        source.close()
        self.assertTrue(bus.closed)
