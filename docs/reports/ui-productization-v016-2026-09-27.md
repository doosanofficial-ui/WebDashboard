# UI Productization v0.16 Checkpoint

Date: 2026-09-27

## Approved Scope

The user approved the combined A+B+C direction:

- A: Operator Grid for Live
- B: Data Dense Signals
- C: Setup First-run Console

CANoe bridge and CAN-FD transport changes are intentionally not included in
this UI commit.

## Implemented

- Live cockpit uses a compact status rail, primary metric, wheel 2x2, charts,
  GPS summary, and a collapsed custom profile.
- MARK/REC/GPS actions use equal-width buttons and a separate status row.
- Signals adds signal search, stale-only filtering, no-source state, raw-frame
  read-only surface, and collapsed developer adapter controls.
- Setup replaces the monolithic Form with server, Connect/GPS/REC checklist,
  permissions, adapter profile, and collapsed developer/BLE sections.
- Dashboard Editor adds horizontal overflow protection and confirmation dialogs
  for page/widget deletion.
- Signal Catalog Editor uses full-width labeled numeric fields and confirmation
  before deleting definitions.
- Native version is 0.16.0, build 7.

## Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Core tests | PASS | 84 tests, 0 failures |
| App build | PASS | mobile-ios/scripts/verify.sh build; /tmp/telemetry-ios-verify.Y2U0xR |
| Live visual QA | PASS | iPhone 17 simulator screenshot /tmp/telemetry-v016-live.png |
| Live accessibility QA | PASS | AX exposed MARK, REC, Start GPS, collapsed custom profile |
| Signals accessibility QA | PASS | AX exposed search field, stale filter, no-source state, raw CAN, developer disclosure |
| Setup accessibility QA | PASS | AX exposed server card, first-run Connect/GPS/REC steps, permissions, adapter, developer disclosure |
| Device arm64 build | PASS (SDK boundary) | /tmp/webdashboard-device-v016.JLgQ9K; Xcode 26.3/iOS 26.2 SDK |
| Device install | PASS | iPhone 17/iOS 27.0; installed 0.16.0 build 7 |
| Device launch | BLOCKED BY DEVICE LOCK | standard verifier exit 12; artifact /tmp/telemetry-ios-device-run.kVGe2Q |

## Remaining Gates

- Unlock iPhone 17 and rerun the standard verifier for v0.16.0.
- Run physical GPS/REC/MARK and 30-minute screen-lock evidence.
- Implement and verify the separate CANoe bridge/CAN-FD design after approval.
- Capture actual NANICAR BT4N GATT and Santa Fe MX5 HEV signals.
- Obtain CarPlay entitlement before claiming CarPlay runtime support.
