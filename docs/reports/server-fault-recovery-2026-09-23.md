# Server Fault Recovery Checkpoint - 2026-09-23

Base: `d6dc2fb`. Scope: actual CAN source/recording health, session lifetime and
simulation semantics. Not a commercial release, full C05 completion or mobile pass.

## Reproduced failures and corrections

- Reentering application lifespan reused a closed CSV logger. Each lifespan now owns
  a new source, mapper and CSV session; import alone creates no session files.
- CAN source or CSV write failure killed the producer while `/api/ping` returned 200.
  Health now returns 503 with a safe error code; no exception text is reflected.
- `SIM_DROP_EVERY` previously skipped collection/logging, not just transmission.
  All sampled sequence numbers are now recorded; only WS publishing is suppressed.
- Nonfinite CAN values could become zero during clamping. Raw source values are
  validated before mapping as well as checking mapped output for nonfinite values.
- Zero/negative/NaN/infinite CAN_HZ values are rejected before producer startup.
- Review found that cancellation before the first sample could leave startup awaiting
  readiness forever. An actual app regression reproduced it, then the startup wait
  was changed to observe readiness **or producer termination** and clean up its waiter.

Original source/CSV/drop/lifespan tests failed before changes. The NaN regression
also caught an incomplete first fix that validated only after clamping. It passed
only after moving input validation ahead of the mapper. The new startup cancellation
case failed with TimeoutError before the reviewed correction.

## Verified evidence

- Server unittest suite: **35 PASS**, including seven new runtime/config fault tests.
- Web/RN GPS integrity: **23 PASS**; service-worker regressions: **8 PASS**.
- Platform-doc validation, shell syntax check and Git whitespace check: PASS.
- Real loopback Uvicorn socket, ephemeral port, dummy source at 10Hz with every fifth
  eligible frame intentionally withheld: HTTP health 200, 12 wire CAN frames,
  16 contiguous recorded samples, observable wire gaps, MARK persisted and pong returned.
  Server and temporary logs were closed after the check. No LAN exposure or actual
  location/vehicle information was used.

Local test receipts:
- `/tmp/webdashboard-tests.CYmkcl/runtime-faults-red.log`
- `/tmp/webdashboard-tests.CYmkcl/runtime-nonfinite-red.log`
- `/tmp/webdashboard-tests.CYmkcl/startup-cancel-red.log`
- `/tmp/webdashboard-tests.CYmkcl/runtime-faults-reviewed.log`
- `/tmp/webdashboard-tests.CYmkcl/candidate-checkpoint-gps.log`
- `/tmp/webdashboard-tests.CYmkcl/candidate-checkpoint-sw.log`

The read-only reviewer returned one startup-cancellation finding and was closed.
The parent reproduced it through the real lifespan/health API and reran the full suite.
No delegated edits, detached worktree, hidden stash or unrelated RN changes were created.

## Known remaining work

- Legacy v1 HTTP/WS GPS/MARK input still needs size/type/range validation and safe
  failure handling. Do not treat these health fixes as uplink hardening.
- Synchronous disk IO can still block the event loop if a write hangs rather than
  raising. Isolation, bounded buffering/backpressure and shutdown behavior need a
  separate fault-tested design. CSV flush is not power-failure durability.
- Signal-map configuration validation, per-signal quality, pairing/security and
  physical 10Hz/end-to-end latency/duration evidence remain separate gates.
- The verified fault behavior stops publication, reports unhealthy and leaves
  reconnection/restart to the operator after correcting the cause. It does not silently
  skip failed records or claim an automatic recorder restart.

The separate [OBD SDK qualification](obd-candidate-qualification-2026-09-23.md)
has intentionally failing **external candidate** acceptance tests. Those candidates
are not production dependencies and those failures must not be relabeled as passing.
