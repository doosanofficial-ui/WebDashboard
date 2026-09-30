# Local-first recording and multi-query snapshot audit

Baseline: `1d251cf0ea894cbad01ead598199ae79f2a21535`. Follow-up: issue #24.
Scope: optional-upload failure isolation and latest local display values. No
vehicle requests, schema migrations, version bump, or physical qualification.

## Reproduced before the fix

The source-generated host harness executed the actual TelemetryModel methods,
with explicit test doubles at location, upload, store, and recorder boundaries.
Its first run had **10 failing assertions out of 20**. These are assertions,
not ten independent product defects.

- A GPS callback with no configured destination still enqueued upload data.
- A full optional upload queue called LocationService.stop(), set collecting to
  false and contaminated the local storage error state. The next GPS callback
  was consequently not admitted to local recording.
- Missing optional upload storage blocked GPS start and MARK display.
- A failed queue count overwrote local storage status.
- Alternating SOC/RPM callbacks and alternating raw CAN IDs replaced rather
  than merged the display values. Restart could retain old receive-time state.

## Changes

- Initialize local measurement storage before optional upload resources; handle
  optional-resource failures only in upload status.
- Enqueue uploads only with an already configured HTTPS endpoint and nonempty
  saved credential. Recheck configuration before asynchronous admission. No
  new destination, consent flow or upload integration is introduced.
- Preserve existing queued records; never stop local GPS or recording merely
  because upload storage is missing, full or unreadable. Real local storage
  errors retain their original guard.
- Update MARK visibility independently of optional upload admission.
- Merge latest local values with each signal's original receive timestamp.
  Reset on acquisition restart/stop or source change. Follow callback order,
  not wall-clock comparisons, so clock corrections do not discard samples.
- Keep recording inputs, chart points and condition inputs unmerged. Retaining
  an old SOC value for display must not manufacture a new SOC measurement when
  RPM arrives. The existing per-signal freshness checks use the retained times.
- Preserve the ServerCANFrame limit of 256 displayed signals, rejecting an
  over-capacity update atomically rather than silently evicting a signal.

## Reproducible software checks

```sh
swift test --package-path mobile-ios/TelemetryCore
python3 scripts/verify_telemetry_model.py
```

`LocalSignalSnapshotTests` adds 14 XCTest cases covering merging, timestamps,
clock adjustment, source reset, real zero/negative values, finite values, keys,
empty input and capacity. A focused Linux Swift 6.2.1 run passed all 14.

The final coordinator source harness checks **23 assertions** and passed with
zero failures on Linux Swift 6.2.1. It reads methods from the current production
file at execution time; it does not maintain a copy of the implementation in
fixtures. Its output includes the input source SHA256. Three additional checks
cover the newly separated optional-upload initialization failure path.

Native Reliability runs this harness after the full TelemetryCore test suite.
The integrating commit's Actions results are the authority for the complete
macOS suite and iOS Simulator build. The host harness is intentionally **not**
UIKit execution, real SQLite fault injection, BLE compatibility or device GPS
continuity evidence. Existing Core SQLite/queue tests run separately.

## Remaining separate verification

Actual BT4N GATT/ECU responses, iPhone GPS/CAN endurance, and CarPlay approval /
head-unit runtime remain unverified by this change. Native hosted app tests for
Start -> immediate Stop -> export/fast restart and late callbacks remain a
separate issue #24 item. Do not mark the entire project bug-free.
