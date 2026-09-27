# GPS Action Rail Follow-up

Checked: 2026-09-27

## Finding

The telemetry model already exposed start/stop location methods, but the
productized Live screen had no user-facing control to call them. This made the
physical GPS/background acceptance path unreachable from the primary cockpit.

## Change

- Added an explicit GPS action to the Live bottom rail.
- The action exposes Start GPS / Stop GPS accessibility labels and identifier
  toggle-gps.
- The rail now distinguishes REC OFF, GPS ON, and GPS status text.
- Bumped the native app to version 0.15.0, build 6.

## Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Core and app verification | PASS | mobile-ios/scripts/verify.sh build; 84 Core tests, 0 failures; /tmp/telemetry-ios-verify.iuCYoW |
| Simulator GPS permission | PASS | iPhone 17 simulator showed When In Use and Always permission prompts |
| Simulator GPS control | PASS | AX state changed to Stop GPS / GPS ON / Waiting for location, then Stop GPS returned to Start GPS / STOPPED |
| Physical arm64 build | PASS (SDK boundary) | Xcode 26.3 with iOS 26.2 SDK; /tmp/webdashboard-device-v015.SH9Eas/derived/Build/Products/Debug-iphoneos/Telemetry.app |
| Physical install and launch | PASS | iPhone 17 iOS 27.0 build 24A437; standard verifier exit 0; /tmp/telemetry-ios-device-run.Rt9qmP |
| Installed version | PASS | devicectl reported local.webdashboard.Telemetry version 0.15.0, bundle version 6 |

## Remaining Boundaries

- The physical install/launch uses Xcode 26.3 and the iOS 26.2 SDK; it is not an
  iOS 27 SDK compile result.
- A simulator permission prompt and a launch result do not prove a 30-minute
  locked-screen GPS/OBD run.
- NANICAR BT4N GATT/framing and Santa Fe MX5 HEV vehicle signals remain
  unverified.
