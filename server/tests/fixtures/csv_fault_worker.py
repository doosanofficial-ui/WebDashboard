"""Test-only faults at the real worker's disk boundary; no production fault flags."""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from csv_worker import run
from logger import SessionCsvLogger

MODE = sys.argv[1]


class FaultWriter(SessionCsvLogger):
    def __init__(self, *args):
        if MODE == "init_bad":
            sys.stdout.buffer.write(b"X" * 100000 + b"\n")
            sys.stdout.buffer.flush()
        if MODE == "init_hang":
            while True:
                time.sleep(60)
        super().__init__(*args)

    def log_can(self, frame):
        if frame["status"]["seq"] == 0:
            if MODE == "gate":
                while not (Path(sys.argv[2]) / ".release").exists():
                    time.sleep(0.01)
            if MODE == "slow":
                time.sleep(0.7)
            if MODE == "hang":
                while True:
                    time.sleep(60)
            if MODE == "exit":
                raise SystemExit(9)
            if MODE == "bad_protocol":
                sys.stdout.buffer.write(b"X" * 100000 + b"\n")
                sys.stdout.buffer.flush()
        return super().log_can(frame)

    def log_event(self, row):
        if MODE == "fail":
            raise OSError("private-worker-canary")
        return super().log_event(row)

    def close(self):
        super().close()
        if MODE == "bad_close":
            raise SystemExit(9)


raise SystemExit(run(Path(sys.argv[2]), sys.argv[3], writer_factory=FaultWriter,
                     capacity=int(sys.argv[4]) if len(sys.argv) > 4 else 128))
