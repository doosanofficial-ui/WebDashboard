# Manufacturer Diagnostic Signal E2E Plan

Date: 2026-09-30
Baseline: `main` at `2faa546`
Scope: iPhone/iOS 27, native Swift/SwiftUI, BLE ELM327, Hyundai Santa Fe MX5 HEV

## Goal

Complete one read-only manufacturer diagnostic signal from a real or captured
ELM327 response through query scheduling, parsing, decoding, TelemetryStore,
dashboard, durable recording, CSV, and replay. Expand only after the first
signal is independently verified.

## Acceptance Gates

| Gate | Acceptance |
| --- | --- |
| Software | Mode 01/21/22 query fixtures pass parser, response validation, decoder, store, recorder, CSV, and replay tests |
| First signal | HV SOC is selected when supported; otherwise a documented supported candidate is used |
| Runtime | The app's real Connect/Start/Stop path starts the query session; test-only injection is not accepted |
| Quality | Source, ECU, service, PID/DID, unit, scale, period, timeout, receive time, monotonic time, and quality are retained |
| Safety | Only allowlisted read requests execute; no ECU write, coding, DTC clear, control, or security bypass |
| UI | One signal is selectable and bound to Numeric plus Gauge/Bar/LED; saved layout restores after relaunch |
| Recording | Raw diagnostic response, decoded value, GPS, MARK, disconnect, timeout, and replay metadata survive CSV/export |
| Physical | A real BT4N/ELM327 + Santa Fe response is required for `PHYSICAL DIAGNOSTIC E2E: PASS` |
| Raw CAN | Raw CAN acceptance remains a separate gate and is not replaced by diagnostic polling |
| CarPlay | Existing glanceable CarPlay projection is regression-tested separately |

## Implementation Plan

### Task 1: Query and response contracts

Files: `TelemetryCore/Sources/TelemetryCore/OBDQuery.swift`,
`TelemetryCore/Sources/TelemetryCore/ELM327QuerySession.swift`, tests in
`TelemetryCore/Tests/TelemetryCoreTests/`.

- Define `OBDQueryDefinition` with request/response CAN IDs, service, PID/DID,
  protocol, flow-control flag, model filter, period, timeout, and source
  provenance.
- Define `OBDResponse` with receive epoch, monotonic time, ECU address,
  service, payload, sequence, and quality.
- Add a scheduler actor that owns query writes and never runs alongside `AT MA`.
- Add tests first for Mode 01, Service 21, Service 22, split ELM lines,
  unsupported response, wrong ECU/DID, `NO DATA`, `BUFFER FULL`, timeout, and
  cancellation.

### Task 2: OBDb/Santa Fe profile importer

Files: `TelemetryCore/Sources/TelemetryCore/OBDbProfile.swift`, a committed
small profile fixture under `mobile-ios/TelemetryCore/Tests/Fixtures/`, and
importer tests.

- Import only the selected Santa Fe Hybrid definitions, not the full OBDb
  organization.
- Map `hdr`/`rax`/`cmd`/`fcm1`/`freq` and `fmt.bix`/`len`/`blsb`/`sign`/
  `mul`/`div`/`add`/`min`/`max`/`map`.
- Preserve the original OBDb commit and source path in provenance.
- Start with `SANTAFEHYB_HVBAT_SOC`; keep wheel speed, TPMS, and battery module
  signals as optional catalog entries.
- Verify `dbgfilter` is not treated as runtime vehicle support without a
  captured response.

### Task 3: Product pipeline integration

Files: existing `LiveAdapterController.swift`, `TelemetryModel.swift`,
`TelemetryStore.swift`, `MeasurementRecorder.swift`, and focused tests.

- Connect the query session to the existing adapter profile and Start/Stop flow.
- Store raw diagnostic response and decoded sample separately from passive
  `CANFrame` records.
- Add `source = diagnostic` and preserve GPS/vehicle receive timestamps and
  monotonic time.
- Add independent replay input that cannot write to a vehicle or issue new
  requests.

### Task 4: Dashboard and export acceptance

Files: existing dashboard/editor/session views plus UI/core tests.

- Bind the selected diagnostic signal to Numeric and at least two of Gauge,
  Bar, or LED widgets.
- Preserve stale, timeout, disconnected, invalid, and valid states.
- Add CSV/replay assertions for raw response, physical value, unit, quality,
  GPS, MARK, and runtime events.
- Keep the existing raw-CAN dashboard bindings and CarPlay projection intact.

### Task 5: Physical verification and evidence

- Run software/replay tests first.
- On the physical iPhone 17, capture adapter profile, service/characteristic,
  request/response bytes, ECU, service, PID/DID, observed rate, timeout/drop,
  and reconnect evidence.
- Use a stationary vehicle test first, then a 10-minute GPS/app-transition/
  MARK/export/replay test.
- Run the required one-hour physical recording test only after the first
  signal is stable.
- Record `PASS`, `FAIL`, `BLOCKED`, or `NOT TESTED` separately for diagnostic
  E2E, raw CAN, and CarPlay.

## Risk Boundaries

- Demo/replay values never satisfy physical acceptance.
- Car Scanner screenshots and OBDb definitions are references, not OEM proof.
- OBDb diagnostic responses are not passive raw CAN frames.
- The user's existing `mobile/` changes remain unstaged and unmodified.
- No new external server, token, OAuth, ABRP integration, or cloud storage is
  introduced.
