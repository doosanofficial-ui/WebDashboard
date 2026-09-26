# Commercial Readiness Checkpoint: iOS CAN/GPS Dashboard

Checked: 2026-09-26. Branch: `codex/native-telemetry-productization`.
This is an evidence checkpoint, not a release approval.

## Implemented in this checkpoint

- Pure Classical CAN model with standard/extended identifiers, DLC/payload
  validation, Intel/Motorola decoding, signed values, scaling, limits, and enum
  labels.
- Read-only ELM327 session state machine with allowlisted `H1`, `CAF0`, `CSM1`,
  and `MA` setup; fragmented prompt handling; CR/LF frame parsing; `BUFFER FULL`,
  unsupported command, malformed frame, and disconnect recovery.
- Actor-isolated latest telemetry store with `VALID`, `STALE`, `INVALID`, and
  `DISCONNECTED` state handling.
- SQLite WAL measurement recorder preserving source time, phone receive time,
  monotonic time, event order, and JSON export.
- iOS `LocationService` extraction and local measurement recorder status.
- Explicit BLE and Wi-Fi transport adapters. BT4N UUIDs are not guessed; BLE
  connection fails closed until service/write/notify characteristics are known.
- Compile-gated, status-only CarPlay projection. No entitlement key or CarPlay
  scene manifest was invented.
- Versioned dashboard profile JSON with typed numeric widgets, persisted profile
  loading, editor duplicate/delete/snap operations, and a SwiftUI editor view.
- Windows `start.ps1`/`start.cmd` bootstrap path with requirements hash tracking,
  and default-deny CORS with explicit `ALLOWED_ORIGINS` opt-in.
- Simulator software vertical slice: `MockCANTransport -> ELM327Session ->
  CANFrame -> SignalDecoder -> numeric UI -> local recorder`, with direct
  accessibility evidence for `RAW 0x123`, decoded signal values, active recorder,
  and explicit stop.
- Versioned `AdapterProfile` JSON now validates transport-specific Wi-Fi endpoint
  or observed BLE peripheral/service/write/notify identifiers and rejects duplicate
  signal IDs before a live connection can start.
- Windows/server CSV recording isolation, bounded queues, write receipts, fault
  health, and web/native recording-health UI.

## Fresh verification

| Area | Result | Evidence |
| --- | --- | --- |
| Swift Core tests | PASS, 53 tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path mobile-ios/TelemetryCore` |
| iOS application build | PASS | Xcode 26.3, iOS 26.2 Simulator SDK, `/tmp/telemetry-ios-verify.IFVJob` |
| Server tests | PASS, 65 tests | `/tmp/webdashboard-verify-20260924.Z9wDKb/python/bin/python -m unittest discover -s server/tests -p 'test*.py'` |
| GPS/web contract tests | PASS, 28 tests | `node --experimental-vm-modules --test scripts/tests/gps-data-integrity.test.mjs` |
| Service worker tests | PASS, 8 tests | `node scripts/tests/service-worker.test.mjs` |
| GitHub smoke | PASS, server/client/mobile | PR #23 run `36240489396` |
| UI runtime smoke | PASS | Direct install/launch on iPhone 17 Pro iOS 26.2 showed `Local recorder ready`, profile-defined Speed/FR/RL/RR/Yaw/Ay widgets, Dashboard Editor, and a duplicated Speed widget; XCTest runner remains unreliable |
| iOS 27 build | NOT RUN | Host has Xcode 26.3 / iOS 26.2 SDK |
| Software ELM vertical slice | PASS | Direct simulator demo adapter path; not a BT4N or vehicle result |
| BT4N live profile | NOT RUN | No observed GATT/serial profile or firmware capture |
| Santa Fe MX5 HEV vehicle capture | NOT RUN | Model year/market and raw CAN access remain unverified |
| CarPlay entitlement/runtime | NOT RUN | Apple entitlement not requested or granted |

## Release blockers

- Install Xcode 27 and verify the exact iPhone 17 iOS 27 build on hardware.
- Discover and record the NANICAR ELM327-BT4N transport, services, characteristics,
  framing, protocol, and supported commands without storing secrets or VIN data.
- Verify one stationary CAN ID and one signal against a trusted reference on the
  Hyundai Santa Fe MX5 HEV.
- Run foreground, screen-lock, Bluetooth disconnect, network disconnect, and
  30-minute recorder/ACK tests on the same signed build.
- Request the Apple CarPlay category entitlement and only then register the
  approved scene configuration.
- Resolve the simulator UI runner issue and obtain a readable assertion result.
- Finish Windows clean-machine packaging, rollback, and real Vector/CANoe bridge
  acceptance.
- Add the configurable multi-widget dashboard editor after the vertical slice.

## Evidence boundary

The current software tests establish deterministic parsing, storage, and error
handling. They do not establish BT4N compatibility, vehicle CAN visibility,
iOS 27 compatibility, background execution guarantees, CarPlay approval, or
power-loss durability. Those gates remain explicitly open.

The direct simulator smoke is not a physical iPhone or iOS 27 result. The
XCTest runner was separately interrupted by the simulator worker before its
assertion, so the direct accessibility observation and XCTest result are kept
as separate evidence classes.
