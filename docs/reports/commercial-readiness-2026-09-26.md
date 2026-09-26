# Commercial Readiness Checkpoint: iOS CAN/GPS Dashboard

Checked: 2026-09-26; engineering follow-up: 2026-09-27. Branch: `codex/native-telemetry-productization`.
This is an evidence checkpoint, not a release approval.
Current native development version: `0.10.0` (build `1`).

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
- In-app JSON export through SwiftUI FileDocument, backed by the same
  SQLite-backed measurement session.
- iOS `LocationService` extraction and local measurement recorder status.
- Explicit BLE and Wi-Fi transport adapters. BT4N UUIDs are not guessed; BLE
  connection fails closed until service/write/notify characteristics are known.
- Versioned adapter profile import and live adapter controller. Startup has a bounded
  connection timeout, pending prompt cancellation, explicit BLE write/notify property
  checks, and profile-defined multi-signal decode/recording. This remains a transport
  implementation result, not BT4N hardware evidence.
- `bluetooth-central` is declared alongside location background mode for the explicitly
  started session. Background scheduling, state restoration, and locked-screen endurance
  remain physical-device gates.
- Compile-gated, status-only CarPlay projection now receives live adapter, recording,
  profile, elapsed-session and limited primary-value state through a bridge. No
  entitlement key or CarPlay scene manifest was invented.
- CarPlay projection bridge now reuses one scene-owned CPListTemplate, updates
  discrete adapter/recording/profile changes immediately, and throttles numeric
  list updates to one second instead of resetting the root template per CAN frame.
- Versioned dashboard profile JSON with typed numeric widgets, persisted profile
  loading, legacy default-grid migration, page lifecycle, rect/z-order editing,
  drag/resize grid canvas, page selection, duplicate/delete/snap operations, and a
  SwiftUI editor view.
- Dashboard widget rendering now distinguishes numeric/circular/semi-circular gauges,
  horizontal/vertical bars, LED/status, raw CAN/bit text, time-series, GPS and map
  information cards, including stale state and configured warning/critical colors.
- SwiftUI cockpit redesign now adds a dark glanceable live shell, primary signal
  hierarchy, adaptive wheel metric rail, chart/GPS/session cards, shared visual
  tokens, and live-only 100 ms invalidation scope. Evidence:
  docs/reports/swiftui-cockpit-redesign-2026-09-26.md.
- Windows `start.ps1`/`start.cmd` bootstrap path with requirements hash tracking,
  and default-deny CORS with explicit `ALLOWED_ORIGINS` opt-in.
- Simulator software vertical slice: `MockCANTransport -> ELM327Session ->
  CANFrame -> SignalDecoder -> numeric UI -> local recorder`, with direct
  accessibility evidence for `RAW 0x123`, decoded signal values, active recorder,
  and explicit stop.
- Versioned `AdapterProfile` JSON now validates transport-specific Wi-Fi endpoint
  or observed BLE peripheral/service/write/notify identifiers and rejects duplicate
  signal IDs before a live connection can start.
- Read-only BLE discovery now records observed peripheral, service, characteristic,
  RSSI, and GATT property data for profile creation without sending adapter writes.
- Server CAN snapshots are validated at the JSON boundary for version, timestamp,
  sequence/drop counters, signal key/value limits, and finite numeric values.
- ELM327 Classical CAN monitor parsing accepts the common `ID DLC DATA...` form and
  retains payload-only compatibility; raw frames are recorded even when no configured
  signal matches.
- Recoverable live adapter failures recreate the transport/session with bounded
  exponential backoff instead of terminating the monitoring task.
- Direct demo/live adapter decoded signals now share the validated CAN snapshot and
  chart buffer used by the cockpit, so native adapter data is visible in gauges and
  graphs instead of being recorder-only.
- `CANSignalPipeline` is now the shared Core decoder boundary for live/replay paths;
  it produces typed decoded samples and rejects duplicate signal catalogs before
  monitoring starts.
- `CANMeasurementPipeline` now has an end-to-end MockCANTransport test covering
  ELM327 session parsing, signal decode, TelemetryStore ingestion, and SQLite rows.
- `TelemetryStore` is now fed by native demo/live CAN frames and GPS samples; profile
  timeouts are configured at runtime and disconnect transitions are explicit.
- BLE discovery permission is deferred until the scan action; scanning only lists
  advertisements and GATT inspection connects only to the explicitly selected device.
- Dashboard widgets now apply adapter-profile timeout values per signal, rather than
  treating every signal in a frame as equally fresh.
- WebSocket URL construction now fails closed with a connection status instead of
  force-unwrapping malformed URL components.
- SQLite outbox payload reads now fail closed on NULL/corrupt rows instead of
  constructing a C string from an invalid pointer.
- Foreground GPS now starts with When In Use authorization; Always remains the
  explicit requirement for locked-screen collection. Native MapKit track rendering
  uses a bounded in-memory coordinate history.
- SQLite measurement/outbox files use first-unlock file protection, and normal
  application termination attempts to close the active measurement session.
- Native measurement export now includes a versioned JSON session envelope and CSV
  output with session metadata and ordered raw/decoded/location/system rows.
- Adapter lifecycle transitions are normalized into stable system events in the
  local recorder for post-run diagnosis.
- Dashboard Editor can create each supported widget type directly, including GPS,
  MapKit track, raw CAN, bit view, gauges, bars, LED, status, and time-series widgets.
- Dashboard Editor includes a widget inspector for signal binding, label/unit,
  decimal precision, range, warning, and critical thresholds.
- Signal Catalog Editor lets operators create and validate CAN signal definitions
  in-app, including ID, bit layout, byte order, signedness, scaling, range, unit,
  and timeout.
- Dashboard Editor alignment operations are now available for selected widgets:
  left/center/right and top/center/bottom within the page canvas.
- LED/status condition engine supports equality, greater/less-than, range, bit-set,
  hysteresis, hold time, and stale-data policy.
- Condition state is now evaluated on incoming server/local CAN snapshots and LED
  widgets render `ACTIVE`, `CLEAR`, or `STALE` instead of only threshold colors.
- BLE permission discovery now starts scanning automatically after the first user
  tap completes Bluetooth manager initialization.
- Recording can be explicitly stopped and restarted from the cockpit; a completed
  session remains exportable while a new recording session gets a new session ID.
- Windows/server CSV recording isolation, bounded queues, write receipts, fault
  health, and web/native recording-health UI.

## Fresh verification

| Area | Result | Evidence |
| --- | --- | --- |
| Swift Core tests | PASS, 75 tests | `mobile-ios/scripts/verify.sh build`; `0.10.0` artifact `/tmp/telemetry-ios-verify.AebMny` |
| Server CAN contract tests | PASS, 3 tests | `ServerCANFrameTests` in the same artifact |
| CAN pipeline tests | PASS, 3 tests | `CANSignalPipelineTests` in the same artifact |
| End-to-end CAN measurement pipeline | PASS, 1 test | `CANMeasurementPipelineTests` covers MockCANTransport -> ELM327Session -> Store -> SQLite |
| ELM327 DLC/recovery tests | PASS, 7 session tests | `ELM327SessionTests` in the same artifact |
| Native app build after hardening | PASS | XcodeGen-generated `0.10.0` project, Xcode 26.3/iOS 26.2 Simulator SDK; `/tmp/telemetry-ios-verify.AebMny` |
| MapKit track widget compile | PASS | Native target includes `MapKit`, `MapPolyline`, and bounded GPS track model; runtime GPS fix not run |
| BLE discovery probe compile | PASS | Native target compile; physical BT4N GATT observation not run |
| Current cockpit visual smoke | PASS (simulator render) | `0.4.0` iPhone 17 Pro simulator screenshot: `docs/reports/evidence/swiftui-cockpit-v040-2026-09-27.png`; disconnected/stale state rendered safely |
| iOS application build | PASS | XcodeGen-generated `0.4.0`, Xcode 26.3/iOS 26.2 Simulator SDK, `/tmp/telemetry-ios-verify.5iGwT4`; bundle version `0.4.0 (1)` |
| Server tests | PASS, 65 tests | `/tmp/webdashboard-verify-20260924.Z9wDKb/python/bin/python -m unittest discover -s server/tests -p 'test*.py'` |
| GPS/web contract tests | PASS, 28 tests | `node --experimental-vm-modules --test scripts/tests/gps-data-integrity.test.mjs` |
| Service worker tests | PASS, 8 tests | `node scripts/tests/service-worker.test.mjs` |
| GitHub smoke | PASS, server/client/mobile | PR #23 run `36255650936` |
| Native Reliability | PASS, Core + native app + Linux/Windows contracts | PR #23 run `36259751689`; native-app job generated XcodeGen project and built the iOS target |
| UI runtime smoke | PASS | Direct install/launch on the iPhone 17 Pro **simulator** with iOS 26.2 showed non-overlapping migrated Speed/FR/RL/RR/Yaw/Ay grid widgets, local recorder, and Dashboard Editor controls; this is not the target physical iPhone 17/iOS 27 result, and XCTest runner remains unreliable |
| SwiftUI cockpit visual smoke | PASS | Direct install/launch on the iPhone 17 Pro iOS 26.2 simulator; screenshot evidence is stored under docs/reports/evidence/ |
| iOS 27 build | NOT RUN | Host has Xcode 26.3 / iOS 26.2 SDK |
| iPhone 17 physical build | PASS (SDK boundary) | Fresh `0.10.0` Personal Team build `/tmp/telemetry-ios-device-condition-live2.wI9BNU` with Xcode 26.3/iOS 26.2 SDK; not an iOS 27 SDK result |
| iPhone 17 physical install | PASS | `0.10.0` build `1` installed by `devicectl` |
| iPhone 17 physical launch | BLOCKED BY DEVICE LOCK | `verify_device.sh` returned exit `12`; log `/tmp/telemetry-v100-device-check.log`; unlock the iPhone and rerun |
| Software ELM vertical slice | PASS | Direct simulator demo adapter start/monitor/stop; not a BT4N or vehicle result |
| CarPlay external display host | PASS (display only) | Simulator `I/O > External Displays > CarPlay` opened the default CarPlay home screen; app rendering was not claimed |
| BT4N live profile | NOT RUN | No observed GATT/serial profile or firmware capture |
| Santa Fe MX5 HEV vehicle capture | NOT RUN | Model year/market and raw CAN access remain unverified |
| CarPlay entitlement/runtime | NOT RUN | Apple entitlement not requested or granted |

## Release blockers

- Install Xcode 27 and verify the exact iPhone 17 iOS 27 build on hardware; the current Personal Team build only proves signing/install with the 26.2 SDK.
- Collect first-run physical runtime evidence for GPS permission handling, live CAN/adapter state, recording, and app lifecycle; launch alone does not establish those behaviors.
- Run the new read-only BLE discovery probe against the NANICAR ELM327-BT4N and
  record services, characteristics, framing, protocol, and supported commands
  without storing secrets or VIN data.
- Verify one stationary CAN ID and one signal against a trusted reference on the
  Hyundai Santa Fe MX5 HEV.
- Run foreground, screen-lock, Bluetooth disconnect, network disconnect, and
  30-minute recorder/ACK tests on the same signed build.
- Verify Apple Developer membership/team/App ID, request the applicable CarPlay
  category entitlement as Account Holder, and only then register the approved
  scene configuration. The simulator display-only check is already recorded;
  entitlement approval and app rendering remain open.
- Resolve the simulator UI runner issue and obtain a readable assertion result.
- Finish Windows clean-machine packaging, rollback, and real Vector/CANoe bridge
  acceptance.
- Complete full production editor acceptance and physical MapKit/track rendering;
  the native MapKit track path now exists, while external map provider/roadview and
  advanced widget configuration UI remain.

## Evidence boundary

The current software tests establish deterministic parsing, storage, and error
handling. They do not establish BT4N compatibility, vehicle CAN visibility,
iOS 27 compatibility, background execution guarantees, CarPlay approval, or
power-loss durability. Those gates remain explicitly open.

The direct simulator smoke is not a physical iPhone or iOS 27 result. The
XCTest runner was separately interrupted by the simulator worker before its
assertion, so the direct accessibility observation and XCTest result are kept
as separate evidence classes.
