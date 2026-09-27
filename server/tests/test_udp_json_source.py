from __future__ import annotations

import json
import socket
import time
import unittest

from can_source.frame import CANRawFrame
from can_source.udp_json import UDPJsonCANSource


def free_udp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_until(predicate, timeout: float = 1.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


class UDPJsonCANSourceTests(unittest.TestCase):
    def send(self, port: int, payload: object) -> None:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.sendto(json.dumps(payload).encode("utf-8"), ("127.0.0.1", port))

    def test_valid_classical_frame_publishes_decoded_and_raw_values(self):
        port = free_udp_port()
        source = UDPJsonCANSource("127.0.0.1", port, stale_after=1.0)
        self.addCleanup(source.close)
        raw = CANRawFrame(
            timestamp=1_700_000_000.1,
            arbitration_id=0x123,
            extended=False,
            is_fd=False,
            bitrate_switch=False,
            error_state_indicator=False,
            dlc=2,
            data=b"\x01\x02",
            source="canoe",
            channel="CAN1",
        ).to_dict()
        self.send(port, {"v": 1, "t": 1_700_000_000.1, "sig": {"ws_fl": 42.5}, "raw": raw})
        self.assertTrue(wait_until(lambda: source.is_ready))
        self.assertEqual(source.next_frame(), {"ws_fl": 42.5})
        self.assertEqual(source.next_raw_frame().arbitration_id, 0x123)
        self.assertFalse(source.is_stale)

    def test_invalid_datagrams_never_become_ready(self):
        port = free_udp_port()
        source = UDPJsonCANSource("127.0.0.1", port, stale_after=1.0)
        self.addCleanup(source.close)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.sendto(b"not-json", ("127.0.0.1", port))
        self.send(port, {"v": 1, "t": 1_700_000_000.1, "sig": {"ws_fl": "nan"}})
        self.assertTrue(wait_until(lambda: source.invalid_datagrams >= 2))
        self.assertFalse(source.is_ready)
        self.assertEqual(source.next_frame(), {})

    def test_source_becomes_stale_without_fake_zero_frame(self):
        port = free_udp_port()
        source = UDPJsonCANSource("127.0.0.1", port, stale_after=0.05)
        self.addCleanup(source.close)
        self.send(port, {"v": 1, "t": 1_700_000_000.1, "sig": {"yaw": 3.0}})
        self.assertTrue(wait_until(lambda: source.is_ready))
        self.assertTrue(wait_until(lambda: source.is_stale, timeout=0.5))
        self.assertEqual(source.next_frame(), {})


if __name__ == "__main__":
    unittest.main()
