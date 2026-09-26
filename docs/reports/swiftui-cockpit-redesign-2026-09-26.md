# SwiftUI Cockpit Redesign Checkpoint

Checked: 2026-09-26. This is a UI implementation checkpoint, not a physical
iPhone/iOS 27 or production release approval.

## Implemented

- Replaced the generic live screen shell with a dark, high-contrast cockpit
  layout intended for moving-vehicle glanceability.
- Added shared visual tokens in mobile-ios/App/TelemetryTheme.swift.
- Extracted live composition into:
  - mobile-ios/App/LiveCockpitView.swift
  - mobile-ios/App/TelemetryMetricCard.swift
  - mobile-ios/App/TelemetryChartCard.swift
- Kept TelemetryModel, TelemetryCore, signal decoding, recorder, profile JSON,
  and status-only CarPlay bridge contracts unchanged.
- Added adaptive wheel metric cards, primary signal hierarchy, stale/live badges,
  60-second chart cards, GPS card, session MARK bar, adapter controls, and profile
  canvas styling.
- Moved the 100 ms TimelineView dependency into the live cockpit subtree;
  Connection settings remain outside that live refresh path.
- Preserved existing UI identifiers and added explicit anchors:
  live-status-strip, primary-metric, session-mark, location-card,
  local-recording-status, start-adapter-demo, and edit-dashboard.

## Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Platform docs validation | PASS | python3 scripts/validate_platform_docs.py |
| Swift Core tests | PASS, 59 tests | mobile-ios/scripts/verify.sh build; latest artifact /tmp/telemetry-ios-verify.T9DSef |
| iOS app compile | PASS | Xcode 26.3, iOS 26.2 Simulator SDK; latest artifact /tmp/telemetry-ios-verify.T9DSef |
| Direct install/launch | PASS | Bundle local.webdashboard.Telemetry installed and launched on iPhone 17 Pro simulator 5BDA4708-2F38-4018-A3A9-023C7DC661A2 |
| Visual smoke | PASS | evidence/swiftui-cockpit-2026-09-26.png; SHA-256 80e82cc348b4ff283047b3c73511ccf7c1834a68714ef7c3c8ef31d10e8c8aa1 |
| Semantic XcodeBuildMCP snapshot | UNVERIFIED | Runtime snapshot returned No translation object returned for simulator; direct screenshot remains the visual evidence |
| XCTest UI runner | UNVERIFIED | Existing xcodebuild test runner stopped in the known environment hang after building the test runner; no assertion result was promoted to PASS |

## Evidence boundary

The screenshot proves the new visual hierarchy and stale-state rendering on an
iPhone 17 Pro iOS 26.2 simulator. It does not prove physical iPhone 17/iOS 27
compatibility, live BT4N CAN frames, GPS permission behavior, 30-minute
background execution, CarPlay entitlement approval, or vehicle-head-unit
rendering.

## Remaining product gates

- Resolve or replace the simulator XCTest runner hang so the new accessibility
  anchors receive an automated assertion result.
- Repeat the same build on Xcode 27/iOS 27 SDK and the physical iPhone 17.
- Validate portrait/landscape and iPad regular-width screenshots.
- Validate live CAN, GPS, recorder, and screen-lock behavior on hardware.
- Complete Apple Developer team/App ID/CarPlay capability approval before adding
  the scene manifest or entitlement.
