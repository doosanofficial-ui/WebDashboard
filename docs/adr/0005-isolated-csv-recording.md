# ADR-0005: Isolated CSV Recording

Date: 2026-09-23. Accepted for implementation under standing authorization; not a release.
Scope: C05's blocking CSV I/O risk, preserving 10Hz capture during bounded storage jitter.

## Decision

Use one owned subprocess per CSV session. Only that process opens/writes/closes CSV.
The server exchanges bounded JSON lines over subprocess stdin/stdout using concurrent
async sender/reader tasks; no shell, pickle, new port or dependency is needed.
Keep at most 128 accepted-but-unconfirmed jobs, each encoded command <=64 KiB.
This includes jobs waiting for the pipe or already inside the worker.

Threads were rejected for this boundary because cancellation of an await does not
cancel a blocked file write. multiprocessing queues add feeder/termination cleanup
risks that are unnecessary for a single worker. The asyncio subprocess APIs support
explicit process termination and asynchronous pipe handling; on Windows they require
a Proactor loop. See [Python subprocess documentation](https://docs.python.org/3.11/library/asyncio-subprocess.html).

## Contract

- `AsyncCsvRecorder.start()` awaits worker-ready with a 5-second startup deadline.
- `log_can/log_gps/log_event(payload)` enqueue a copy and return a receipt Future.
- CAN never waits on disk. GPS/MARK HTTP success and serial WS progression wait for
  the worker's write/flush result, up to 1 second. Timeout means unconfirmed, not lost
  or successful. It does not cancel an already accepted write.
- Oldest pending age over 500ms is delayed. A full queue, write failure or worker loss
  fails closed for new capture, with bounded error codes and counts. No silent overwrite
  or eviction. Already accepted jobs may drain after queue-full failure.
- Status separates accepted, pending, written, unconfirmed and rejected counts,
  plus last written CAN sequence. Written means CSV write/flush, NOT power-loss durability.
  Reliable v2 SQLite ACK semantics remain unchanged.
- Normal shutdown drains pending writes and closes the worker within 2 seconds.
  An unresponsive worker is terminated then killed if needed with bounded waits.
  Unconfirmed jobs and any surviving worker are reported, never relabeled as success.
  This does not promise recovery from an uninterruptible OS/kernel/storage failure.
- Every new server lifecycle gets a distinct session. No child or pipe is reused after
  failure. Do not automatically restart a failed recording session or hide a gap.

## Client visibility

CAN status carries a recording snapshot. State transitions also emit a separate v1
`recording_status` control message so errors are visible even if CAN capture stops.
Web and native iOS display server recording quality separately from connection/GPS
upload status. A control message must not refresh the last CAN measurement time.
Unknown server strings are never reflected as UI error text.

## Verification order

1. Reproduce event-loop blocking with the current logger.
2. Test real child + CSV behavior: delayed writes, FIFO completion, queue bound,
   error/exit, timeout without false receipt, shutdown drain/forced termination.
3. Exercise real app lifetime/API/WS with a stalled child; CAN cadence and HTTP remain
   responsive, recording state degrades, and recovery drains accepted samples.
4. Test safe web/native recording status decoding; compile native and inspect web UI.
5. Run full cross-platform CI and inspect process cleanup before commit/push report.

No hardware, iOS 27, full release or exact power-loss durability claim follows from
these tests. Remaining auth, retention, pairing, real CAN/OBD and device gates persist.

## Lifecycle refinements verified on 2026-09-24

- A shared process-creation task and single owned close task coordinate concurrent
  start/close. Cancellation of a caller does not discard the cleanup owner.
- Application cleanup uses an AsyncExitStack, shielded cleanup task and final global
  reset, so earlier cleanup failures/cancellation cannot skip CSV cleanup.
- Require the worker's closed receipt and exit code zero. Drain malformed output in
  bounded chunks; process exit alone does not prove pipes were closed or data confirmed.
- The worker has its own process group so a parent console signal does not kill it
  before draining. A bounded stdin monitor detects owner loss even during blocked
  CSV I/O and stops an abandoned worker after a grace period. Its raw fd reader
  avoids buffered-stdin locks during interpreter finalization.
- Windows process creation/termination runs in CI. The POSIX pgid assertion is skipped
  on Windows; actual interactive Windows console shutdown remains a deployment test.
