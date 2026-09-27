# Xcode 27 / iOS 27 Environment Checkpoint

Date: 2026-09-28
Baseline main before this report: `da9e3e0`
Application version: `0.21.0 (15)`

This checkpoint records the host toolchain refresh requested for the native
iPhone telemetry application. It separates installed SDK evidence, simulator
evidence, physical-device evidence, and UI-test failures.

## Environment

| Gate | Result | Evidence |
| --- | --- | --- |
| macOS | PASS | macOS `27.0`, build `26A428`, arm64; `sw_vers` |
| Active developer directory | PASS | `/Applications/Xcode.app/Contents/Developer` |
| Xcode | PASS | Xcode `27.0`, build `27A266a`; `xcodebuild -version` |
| Xcode license | PASS | License accepted by the user; subsequent Xcode commands no longer requested it |
| iOS device SDK | PASS | `iphoneos27.0` listed by `xcodebuild -showsdks` |
| iOS Simulator SDK | PASS | `iphonesimulator27.0` listed by `xcodebuild -showsdks` |
| iOS 27 Simulator runtime | PASS | iOS `27.0 (24A434)`, runtime `11EBC35F-4B1A-4067-92D0-329394D7BBF1` |
| iPhone 17 iOS 27 simulator | PASS | Created `Telemetry iPhone 17 iOS 27`, UDID `7A53C18B-E336-4856-8A56-6CBE51053D6F` |
| Xcode first launch | PASS | `xcodebuild -runFirstLaunch` completed successfully |

The previous Xcode 26.3 installation was not deleted. The App Store replaced
the active `/Applications/Xcode.app` installation with Xcode 27; the older
bundle remains outside the active path for rollback.

## Software Verification

| Gate | Result | Evidence |
| --- | --- | --- |
| Platform documentation validation | PASS | `python3 scripts/validate_platform_docs.py` |
| TelemetryCore tests | PASS | 89 tests, 0 failures; `/tmp/telemetry-ios-verify.Taljqq` |
| Xcode 27 generic iOS build | PASS | `/tmp/telemetry-ios-verify.Taljqq/result.xcresult` |
| SDK used by build | PASS | Build log references `/Applications/Xcode.app/.../iPhoneSimulator27.0.sdk` |
| Xcode 27 iOS 27 UI test run | FAIL | 17 tests, 11 failures; `/tmp/telemetry-ios-verify.huq7ih` |

The generic build and core tests prove the source compiles and the core
pipeline remains green with the iOS 27 SDK. They do not prove a physical
iPhone runtime or a vehicle CAN path.

## UI Test Failure Triage

The iOS 27 UI run launched the app and passed these areas, among others:

- Cockpit anchors and profile-defined `Speed` label
- BLE observation save control
- BLE scan automation identifier
- Dashboard widget creation menu
- Recording toggle visibility

The failures are not treated as an environment PASS. The observed causes are:

- Location tests depend on a simulator permission dialog and persisted
  authorization state. The run dismissed the first location prompt as
  `허용 안 함`, so later `Change to Always Allow` assertions failed.
- `TelemetryUITests.swift` expects `export-measurement-json` and
  `export-measurement-csv`, while `SessionsView.swift` currently exposes
  `sessions-export-json` and `sessions-export-csv`. This is an existing test
  contract mismatch, not an SDK installation failure.
- Several editor/session container identifiers were not exposed in the iOS 27
  accessibility hierarchy at the expected element type. These require a
  targeted SwiftUI accessibility review and a clean, permission-reset test
  run before changing production UI code.

No production code was changed to mask these failures in this environment
checkpoint.

## Physical Device

| Gate | Result | Evidence |
| --- | --- | --- |
| iPhone 17 hardware identity | NOT TESTED in this refresh | Previous known device: iPhone 17 / iPhone18,3 / iOS 27.0 build 24A437 |
| CoreDevice connection after Xcode update | BLOCKED | `xcrun devicectl list devices` no longer listed the previous physical device; the known CoreDevice ID returned `device was not found` |
| Physical iPhone build with Xcode 27 | BLOCKED | Requires the iPhone to be reconnected, unlocked, and trusted again |
| Physical BLE/ELM327/CAN | BLOCKED: PHYSICAL HARDWARE REQUIRED | No adapter or vehicle evidence was created by this host refresh |

This report does not convert the earlier iOS 27 physical evidence into Xcode
27 build evidence. Reconnect evidence must be collected again with the active
Xcode 27 toolchain.

## Repository Safety

The refresh changed host tools and simulator state only. Existing user-owned
uncommitted changes under `mobile/` were not staged, modified, or removed.

## Next Gates

1. Reconnect and unlock the physical iPhone 17, then confirm the new Xcode 27
   CoreDevice identifier.
2. Build, install, and launch the app on that physical device with Xcode 27.
3. Reset simulator permissions and run the UI suite again; fix only confirmed
   product/test contract failures.
4. Repeat physical screen-lock/background and BLE/ELM327 evidence separately.
