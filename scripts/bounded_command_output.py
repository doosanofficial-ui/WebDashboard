"""Internal stdout limiter; its caller must stop and verify the whole owned group.

The command inherits this worker's process group. This worker deliberately
does not create another group, including when it returns after an output cap.
"""
import os
import subprocess
import sys


def main(arguments):
    try:
        limit = int(arguments[0])
        if limit <= 0 or len(arguments) < 2:
            return 2
        child = subprocess.Popen(arguments[1:], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        remaining = limit
        while True:
            chunk = child.stdout.read(min(65536, remaining + 1))
            if not chunk:
                return child.wait()
            accepted = chunk[:remaining]
            view = memoryview(accepted)
            while view:
                written = os.write(sys.stdout.fileno(), view)
                view = view[written:]
            remaining -= len(accepted)
            if len(chunk) > len(accepted):
                return 122  # The owner terminates any remaining command descendants.
    except (OSError, ValueError, IndexError):
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
