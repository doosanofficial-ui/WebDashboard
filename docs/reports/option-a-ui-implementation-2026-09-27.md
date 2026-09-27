# Option A UI Implementation Checkpoint

Checked: 2026-09-27

## Decision

The user approved Option A from the CarPlay/iPhone UI pattern research:
Cockpit + State Rail.

The native app is now version 0.14.0 (build 5) with the following
operator-facing navigation:

- Live: primary signal, wheel quick metrics, dynamics charts, GPS, persisted
  dashboard profile, and a fixed bottom MARK / REC action rail.
- Signals: acquisition health, server/profile signal catalog, freshness state,
  raw CAN read-only view, and developer/adapter controls.
- Sessions: explicit local recording lifecycle, duration, MARK, queue/GPS
  status, and JSON/CSV export.
- Setup: server URL, HTTPS/credential setup, background-location guidance,
  adapter profile import, signal catalog editing, and BLE observation.

The transport, decoding, SQLite, outbox, GPS, and CarPlay projection boundaries
were not rewritten by this UI change. CarPlay remains status-only and
entitlement-gated.

## Source Changes

- mobile-ios/App/DashboardView.swift: four-tab shell; Connection renamed to
  Setup.
- mobile-ios/App/LiveCockpitView.swift: removes adapter controls from the
  driving view and places MARK/REC in a safe-area bottom rail.
- mobile-ios/App/SignalsView.swift: new signal-quality and raw-CAN surface.
- mobile-ios/App/SessionsView.swift: new session-control and export surface.
- mobile-ios/App/TelemetryModel.swift: read-only recording elapsed-time
  projection for the session screen.
- mobile-ios/project.yml: version 0.14.0, build 5, and the verified
  Personal Team identifier for automatic device signing.
- mobile-ios/README.md: navigation and build instructions updated.

## Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Repository verification | PASS | ./mobile-ios/scripts/verify.sh build; Core 84 tests, 0 failures; app BUILD SUCCEEDED; /tmp/telemetry-ios-verify.WmvfxJ |
| Simulator install/launch | PASS | iPhone 17 simulator, iOS 26.2; app launch PID recorded by simctl; screenshot /tmp/telemetry-option-a-live.png |
| Live accessibility surface | PASS | Simulator AX tree exposed live-status-strip, mark-event, toggle-recording, and four tabs |
| Signals screen | PASS | AX tree exposed signals-health-card, seven server-snapshot rows, raw-can-card, and adapter controls |
| Sessions screen | PASS | AX tree exposed recording, MARK, duration, pending/GPS status, JSON and CSV actions |
| Recording interaction | PASS | Simulator action changed READY TO RECORD to RECORDING, 00:00, then returned to READY TO RECORD after Stop |
| Physical arm64 build | PASS (SDK boundary) | Xcode 26.3, iOS 26.2 SDK; /tmp/telemetry-ios-device-v014-any/Build/Products/Debug-iphoneos/Telemetry.app; Apple Development identity |
| Physical v0.14 install/launch | PASS (SDK boundary) | iPhone 17 iOS 27.0; standard verifier exit 0; /tmp/telemetry-ios-device-run.4SCCnV |

## Known Environment Constraint

The canonical workspace path contains a non-breaking space in its parent
directory. Xcode/SwiftPM response files can split that path while compiling the
local TelemetryCore package. The repository verification script intentionally
stages an identical source copy under an ASCII /tmp path and is the supported
shell verification route. No second editable checkout was created.

## Remaining Gates

- Run physical GPS permission, screen-lock, adapter disconnect, recording, and
  30-minute endurance checks.
- Capture the NANICAR BT4N GATT profile and validate one Santa Fe MX5 HEV signal.
- Resolve the unreliable XCTest runner separately; direct simulator AX evidence
  is retained as a different evidence class.
- Obtain Apple CarPlay category entitlement before adding any entitlement key or
  claiming CarPlay app rendering.


## Physical device follow-up (2026-09-27)

The device became available again and the signed 0.14.0 build was verified on
the target hardware:

- Device: iPhone 17 / iOS 27.0 build 24A437
- CoreDevice: 2C0892EB-662D-5D9A-A908-96EA723DEEB4
- Bundle: local.webdashboard.Telemetry, version 0.14.0, build 5
- Artifact: /tmp/telemetry-ios-device-v014-any/Build/Products/Debug-iphoneos/Telemetry.app
- Standard verifier: exit 0
- Install: PASS
- Launch: PASS
- Process: Telemetry.app/Telemetry observed after launch and after 5 seconds
- Verifier artifacts: /tmp/telemetry-ios-device-run.4SCCnV

This is a physical iOS 27 runtime/install result using the Xcode 26.3 /
iOS 26.2 SDK. It does not establish an iOS 27 SDK compile result, GPS permission
behavior, BT4N GATT compatibility, vehicle CAN visibility, background endurance,
or CarPlay entitlement/runtime.
