# iOS Physical Telemetry and CarPlay Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate and harden the existing native iPhone telemetry pipeline from real ELM327/CAN input through dashboard recording, with CarPlay treated as a separate entitlement-gated surface.

**Architecture:** Reuse the existing Swift/SwiftUI, `TelemetryCore`, Core Location, BLE transport, recorder, and CarPlay projection boundaries. Make only the iPhone target-family configuration change first, then collect software, physical-device, hardware, and CarPlay evidence without promoting one gate to another.

**Tech Stack:** Swift 5, SwiftUI, Core Location, Core Bluetooth, XcodeGen, Swift Package Manager, CarPlay templates, ELM327 Classical CAN.

**Spec:** User-provided iPhone/iOS 27 physical E2E and CarPlay acceptance specification in the current task.

## Global Constraints

- `main` is the only working and integration branch.
- Active scope is iPhone, native iOS, Vehicle CAN, BLE/ELM327, Dashboard, Recording/Export, and CarPlay.
- iPad and Android are out of scope and are not acceptance gates.
- Existing architecture is reused; no replacement framework or broad refactor.
- Real hardware evidence is required before declaring the ELM327/CAN E2E complete.
- Compile, simulator, entitlement, and physical CarPlay results remain separate gates.

## Review Focus

- Target-family narrowing must exclude iPad without changing the iPhone app, Core package, or CarPlay projection contract.
- Xcode SDK/device compatibility must be reported separately from build success.
- BLE discovery must use observed GATT evidence, not guessed UUIDs.
- ELM327 receive timestamps must remain receive timestamps, not bus transmission timestamps.
- Stale GPS, dropped CAN frames, disconnects, and recorder failures must remain explicit states.

### Task 1: Narrow the native target to iPhone

**Files:**
- Modify: `mobile-ios/project.yml`
- Test: generated Xcode project settings

- [ ] Change `TARGETED_DEVICE_FAMILY` from `'1,2'` to `'1'` only after confirming no source, Core, or CarPlay contract depends on iPad.
- [ ] Generate the Xcode project and verify the application target contains `TARGETED_DEVICE_FAMILY = 1`.
- [ ] Keep the existing iPad/Android files untouched and out of acceptance evidence.

### Task 2: Run software-native regression

**Files:**
- Verify: `mobile-ios/TelemetryCore`
- Verify: `mobile-ios/project.yml`, `mobile-ios/App`, `mobile-ios/UITests`

- [ ] Run `swift test --package-path mobile-ios/TelemetryCore`.
- [ ] Run the existing XcodeGen/Xcode app build and available simulator tests.
- [ ] Record build, simulator, and test results separately from physical-device results.

### Task 3: Verify the physical iPhone runtime

**Files:**
- Verify: `mobile-ios/scripts/build_device.sh`
- Evidence: `docs/reports/`

- [ ] Build, install, and launch the current `main` build on the physical iPhone 17.
- [ ] Record iOS version, SDK version, app version/build, device identifier, and separate BUILD/INSTALL/LAUNCH results.
- [ ] Exercise foreground, screen lock, background, and foreground return; classify missing device or signing access as a human handoff.

### Task 4: Qualify physical BLE ELM327 and vehicle CAN

**Files:**
- Verify: `mobile-ios/App/BLETransport.swift`, `mobile-ios/App/BLEDiscoveryController.swift`, `mobile-ios/TelemetryCore/ELM327Session.swift`, `mobile-ios/TelemetryCore/CAN.swift`
- Evidence: adapter profile and captured regression fixture under `docs/reports/`

- [ ] Observe BT4N peripheral/GATT name, identifier, service, characteristic, properties, MTU/chunk behavior, and reconnect behavior.
- [ ] Validate supported ELM327 commands from actual responses without sending periodic commands that disrupt monitoring.
- [ ] Capture one real raw CAN frame and carry it through decode, dashboard, and recorder.

### Task 5: Validate recording and one-hour endurance

**Files:**
- Verify: `mobile-ios/App/TelemetryStore.swift`, `mobile-ios/App/MeasurementRecorder.swift`, `mobile-ios/App/LocationService.swift`, export paths
- Evidence: CSV/export and endurance report under `docs/reports/`

- [ ] Record real CAN, decoded signals, GPS timestamps/quality, and lifecycle events in one session.
- [ ] Verify CSV/JSON export reconstruction in MATLAB or Python.
- [ ] Run the one-hour physical endurance test and report rate, drop, GPS continuity, reconnects, latency, memory, CPU, battery, thermal, and disk growth.

### Task 6: Validate CarPlay as a separate gate

**Files:**
- Verify: `mobile-ios/App/CarPlay/CarPlayProjectionBridge.swift`, `mobile-ios/App/CarPlay/CarPlaySceneDelegate.swift`, current project configuration
- Evidence: CarPlay compile/simulator/entitlement/physical records under `docs/reports/`

- [ ] Confirm applicable category, entitlement, templates, interactions, and update limits from Apple official documentation.
- [ ] Verify compile, CarPlay simulator rendering, entitlement approval, and physical head-unit runtime independently.
- [ ] Keep the CarPlay surface glanceable and status-oriented; do not mirror the editable iPhone dashboard.
