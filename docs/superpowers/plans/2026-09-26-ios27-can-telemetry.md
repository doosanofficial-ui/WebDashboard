# iOS 27 CAN Telemetry Vertical Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement and verify the read-only CAN/GPS recording vertical slice without coupling the application to the unknown BT4N transport.

**Architecture:** Keep pure parsing, decoding, transport contracts, session state, telemetry state, and recording testable in `TelemetryCore`; keep Core Bluetooth, Core Location, SwiftUI, and CarPlay in the iOS app target. Acquire raw frames at the transport rate, update latest UI state at approximately 10 Hz, and record original samples separately.

**Tech Stack:** Swift 5.9+, Swift Concurrency actors, XCTest, SQLite/WAL through the existing `CSQLite` module, SwiftUI, Core Bluetooth, Core Location, and CarPlay only behind an entitlement-gated app boundary.

**Spec:** `docs/superpowers/specs/2026-09-26-ios27-can-telemetry-design.md`

## Global Constraints

- Classical CAN only; reject CAN FD and DLC values greater than 8.
- No arbitrary CAN transmission, ECU write, DTC clear, or programming API.
- Preserve adapter receive time separately from the vehicle bus timestamp, which is unavailable.
- Preserve `CLLocation.timestamp` separately from phone receive and monotonic times.
- Do not assume NANICAR BT4N UUIDs, firmware, protocol, or clone command parity.
- UI refresh is approximately 10 Hz; raw recording is not downsampled to UI frequency.
- CarPlay is optional and entitlement-gated; do not add an invented entitlement key.
- Do not modify the unrelated legacy `mobile/` React Native files in this plan.

## Review Focus

- Motorola DBC start-bit extraction must not silently use Intel numbering; test a multi-byte cross-boundary fixture in Task 1.
- ELM prompt and notification fragmentation must not create duplicate or partial frames; test fragmented input in Task 2.
- A slow or failed recorder must not block frame parsing or become a false healthy state; test actor isolation and failure transitions in Task 3.
- GPS original timestamps must not be replaced with display tick time; test source/receive time separation in Task 4.
- A CarPlay entitlement absence must not prevent the iPhone target from building; test compile-gated projection in Task 5.

### Task 1: CAN models and signal decoder

**Files:**
- Create: `mobile-ios/TelemetryCore/Sources/TelemetryCore/CAN.swift`
- Create: `mobile-ios/TelemetryCore/Tests/TelemetryCoreTests/CANDecoderTests.swift`
- Modify: `mobile-ios/TelemetryCore/Package.swift` only if target resources are needed

**Interfaces:**
- Consumes: no earlier task.
- Produces: `CANFrame`, `CANFrameError`, `ByteOrder`, `SignalDefinition`, `SignalDecodeError`, and `SignalDecoder.decode(frame:definition:)`.

- [ ] **Step 1: Write failing tests**
  - Validate 11-bit and 29-bit identifiers, DLC bounds, payload length, and raw byte preservation.
  - Validate Intel extraction, Motorola cross-byte extraction, signed two's-complement, factor/offset, range, and enum mapping.
- [ ] **Step 2: Run the focused XCTest and verify the expected missing-symbol failure**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path mobile-ios/TelemetryCore --filter CANDecoderTests
```

- [ ] **Step 3: Implement the minimal pure Swift models and decoder**
- [ ] **Step 4: Run focused tests, then the full Core XCTest**
- [ ] **Step 5: Commit:** `feat: add typed classical can signal decoding`

### Task 2: Transport contract and ELM327 session

**Files:**
- Create: `mobile-ios/TelemetryCore/Sources/TelemetryCore/Transport.swift`
- Create: `mobile-ios/TelemetryCore/Sources/TelemetryCore/ELM327Session.swift`
- Create: `mobile-ios/TelemetryCore/Tests/TelemetryCoreTests/ELM327SessionTests.swift`
- Modify: `mobile-ios/TelemetryCore/Sources/TelemetryCore/ELM327.swift` to share framing errors/types

**Interfaces:**
- Consumes: `CANFrame` and decoder types from Task 1.
- Produces: `CANTransport`, `TransportEvent`, `ELM327State`, `ELM327Command`, `ELM327Session` actor, and `MockCANTransport`.

- [ ] **Step 1: Write failing tests**
  - Assert command ordering, one in-flight initialization, `AT MA` monitoring, no periodic commands while monitoring, and recovery on `BUFFER FULL`/disconnect.
  - Assert fragmented prompt input and unsupported command behavior.
- [ ] **Step 2: Run focused tests and verify the missing-symbol failure**
- [ ] **Step 3: Implement the typed transport/session state machine with an allowlist**
- [ ] **Step 4: Run focused and full Core tests**
- [ ] **Step 5: Commit:** `feat: add read-only elm transport session`

### Task 3: Telemetry store and durable measurement recording

**Files:**
- Create: `mobile-ios/TelemetryCore/Sources/TelemetryCore/TelemetryStore.swift`
- Create: `mobile-ios/TelemetryCore/Sources/TelemetryCore/MeasurementRecorder.swift`
- Create: `mobile-ios/TelemetryCore/Tests/TelemetryCoreTests/TelemetryStoreTests.swift`
- Create: `mobile-ios/TelemetryCore/Tests/TelemetryCoreTests/MeasurementRecorderTests.swift`

**Interfaces:**
- Consumes: frames and decoded samples from Tasks 1 and 2.
- Produces: `SignalQuality`, `LatestSignalState`, `LocationSample`, `MeasurementEvent`, `TelemetryStore` actor, and `MeasurementRecorder` actor.

- [ ] **Step 1: Write failing tests** for latest-value updates, stale timeout, disconnect state, source/receive time preservation, ordered session events, and recorder reopen/export.
- [ ] **Step 2: Run focused tests and verify the expected missing-symbol failure**
- [ ] **Step 3: Implement actor isolation and SQLite transaction boundaries**
- [ ] **Step 4: Run focused and full Core tests**
- [ ] **Step 5: Commit:** `feat: add actor-isolated telemetry store and recorder`

### Task 4: iOS location, transport adapters, and numeric vertical slice

**Files:**
- Create: `mobile-ios/App/LocationService.swift`
- Create: `mobile-ios/App/BLETransport.swift`
- Create: `mobile-ios/App/WiFiTransport.swift`
- Modify: `mobile-ios/App/TelemetryModel.swift`
- Modify: `mobile-ios/App/DashboardView.swift`
- Modify: `mobile-ios/project.yml` for Bluetooth background capability only when the adapter profile is ready
- Create: `mobile-ios/UITests/VerticalSliceUITests.swift`

**Interfaces:**
- Consumes: `ELM327Session`, `TelemetryStore`, and recording interfaces.
- Produces: a user-triggered connection flow, explicit GPS permission flow, numeric signal view, raw frame view, recording state, and stale/error UI.

- [ ] **Step 1: Write failing UI/model tests** for permission denial, stale value rendering, numeric zero versus unknown, and session stop.
- [ ] **Step 2: Run the focused test and verify the missing behavior**
- [ ] **Step 3: Implement Core Location and transport adapters without guessed UUIDs**
- [ ] **Step 4: Run Core tests, UI tests on an available simulator, and the repository smoke checks**
- [ ] **Step 5: Commit:** `feat: connect ios telemetry vertical slice`

### Task 5: Hardware qualification and CarPlay-safe projection

**Files:**
- Create: `mobile-ios/App/CarPlay/CarPlayProjection.swift`
- Create: `mobile-ios/App/CarPlay/CarPlaySceneDelegate.swift`
- Create: `docs/reports/bt4n-live-profile-<date>.md` only after actual device observation
- Modify: `docs/production-plan.md` with evidence, never with assumptions

**Interfaces:**
- Consumes: validated `CarPlayProjectionState` and hardware profile from Tasks 2-4.
- Produces: no-entitlement iPhone build preservation, status-only CarPlay implementation when Apple grants the category, and a reproducible hardware evidence record.

- [ ] **Step 1: Write failing compile/configuration tests** for entitlement absence and projection state serialization.
- [ ] **Step 2: Run the tests and confirm the projection is unavailable before entitlement configuration**
- [ ] **Step 3: Implement the compile-gated status projection without adding a fabricated entitlement**
- [ ] **Step 4: Run Xcode 27/iOS 27 build, CarPlay Simulator, and real BT4N/vehicle acceptance only when hardware is available**
- [ ] **Step 5: Commit:** `feat: add entitlement-gated carplay status projection`

### Task 6: Versioned dashboard profile and editor model

**Files:**
- Create: `mobile-ios/TelemetryCore/Sources/TelemetryCore/DashboardModel.swift`
- Create: `mobile-ios/TelemetryCore/Tests/TelemetryCoreTests/DashboardModelTests.swift`

**Interfaces:**
- Consumes: `SignalDefinition` identifiers and `CarPlayProjectionState` naming conventions.
- Produces: versioned `DashboardProfile`, `DashboardPage`, `DashboardWidgetDefinition`, typed widget configuration, and pure editor operations for duplicate/delete/snap/grid alignment.

- [ ] **Step 1: Write failing tests** for JSON round-trip, unsupported schema version rejection, widget binding, duplicate/delete, and snap-to-grid.
- [ ] **Step 2: Run focused tests and verify the expected missing-symbol failure**
- [ ] **Step 3: Implement the pure versioned dashboard model and editor operations**
- [ ] **Step 4: Run focused and full Core tests**
- [ ] **Step 5: Commit:** `feat: add versioned dashboard profile model`

### Task 7: SwiftUI configurable dashboard integration

**Files:**
- Modify: `mobile-ios/App/TelemetryModel.swift`
- Modify: `mobile-ios/App/DashboardView.swift`
- Create: `mobile-ios/App/DashboardEditorView.swift`
- Modify: `mobile-ios/project.yml` only for profile resources if needed

**Interfaces:**
- Consumes: `DashboardProfile` and editor operations from Task 6 plus existing latest server signal values.
- Produces: profile selection, numeric widget rendering from configuration, edit mode for add/delete/duplicate, and clear unavailable/stale states.

- [ ] **Step 1: Add a failing UI assertion** that a profile-defined widget label/value appears independently of the old hard-coded gauge list.
- [ ] **Step 2: Run the focused UI test and record simulator-harness status**
- [ ] **Step 3: Implement profile loading/saving and the minimal editor UI**
- [ ] **Step 4: Run Core tests and an iOS build; rerun UI only when the simulator worker is healthy**
- [ ] **Step 5: Commit:** `feat: render configurable dashboard profiles`

## Verification gate

Every task must run its focused tests and then the complete applicable suite.
Final acceptance requires Xcode 27/iOS 27 evidence, actual BT4N profile evidence,
stationary Santa Fe MX5 HEV captures, lock/reconnect measurements, and CarPlay
entitlement/runtime evidence. The current Xcode 26.3/iOS 26.2 results remain
software-only evidence.
