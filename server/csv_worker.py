"""Private stdin/stdout worker. All session CSV filesystem I/O stays here."""
from __future__ import annotations

import json
import os
import queue
import sys
import threading
from pathlib import Path

from logger import SessionCsvLogger

MAX_COMMAND_BYTES = 64 * 1024


def _reply(payload: dict) -> None:
    sys.stdout.buffer.write(json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n")
    sys.stdout.buffer.flush()


def run(log_dir: Path, session_id: str, *, writer_factory=SessionCsvLogger, capacity=128) -> int:
    incoming = queue.Queue(maxsize=capacity)
    finished = threading.Event()

    def watch_input():
        pending = bytearray()
        try:
            while True:
                # Raw fd reads avoid a daemon thread holding a buffered-stdin lock
                # during interpreter shutdown after an unexpected write failure.
                chunk = os.read(sys.stdin.fileno(), 4096)
                if not chunk:
                    if pending:
                        incoming.put(bytes(pending))
                    break
                pending.extend(chunk)
                while (end := pending.find(b"\n")) >= 0:
                    incoming.put(bytes(pending[:end + 1]))
                    del pending[:end + 1]
                if len(pending) > MAX_COMMAND_BYTES:
                    incoming.put(bytes(pending))
                    break
        finally:
            # EOF also occurs if the owner crashes. A stuck filesystem call must not
            # leave a detached worker indefinitely; normal close is already drained.
            def abandoned_owner():
                if not finished.is_set():
                    os._exit(2)
            timer = threading.Timer(2, abandoned_owner)
            timer.daemon = True
            timer.start()
            incoming.put(None)

    threading.Thread(target=watch_input, daemon=True).start()
    writer = None
    try:
        writer = writer_factory(log_dir, session_id)
        _reply({"ready": True})
        methods = {"CAN": writer.log_can, "GPS": writer.log_gps, "MARK": writer.log_event}
        while True:
            line = incoming.get()
            if line is None:
                break
            if len(line) > MAX_COMMAND_BYTES or not line.endswith(b"\n"):
                raise ValueError("invalid_worker_command")
            command = json.loads(line)
            if set(command) != {"id", "kind", "value"} or type(command["id"]) is not int:
                raise ValueError("invalid_worker_command")
            methods[command["kind"]](command["value"])
            _reply({"id": command["id"], "ok": True})
        writer.close()
        writer = None
        _reply({"closed": True})
        return 0
    except Exception:
        _reply({"error": "write_failed" if writer else "startup_failed"})
        return 1
    finally:
        if writer is not None:
            try:
                writer.close()
            except Exception:
                pass
        finished.set()


if __name__ == "__main__":
    raise SystemExit(run(Path(sys.argv[1]), sys.argv[2], capacity=int(sys.argv[3])))
