# iOS 27 Physical Telemetry Checkpoint

Date: 2026-09-27
Current main: `60e0e00`
App version/build: `0.21.0 (15)`
Scope: iPhone, native iOS, BLE/ELM327, Vehicle CAN, Recording/Export, CarPlay
Out of scope: iPad, Android

## Summary

The native application is now configured for iPhone-only targets. Software
tests, a generic iOS Simulator build, an iPhone 17 Simulator launch, and a
physical iPhone 17 build/install/launch passed using the available Xcode 26.3
toolchain. The Mac does not have an iOS 27 SDK, so this is compatibility
evidence, not an iOS 27 SDK build claim.

## Gates

| Gate | Status | Evidence / reason |
| --- | --- | --- |
| iPhone target family | PASS | `mobile-ios/project.yml` generates `TARGETED_DEVICE_FAMILY = 1` |
| Core regression | PASS | 89 `TelemetryCore` tests passed in `/tmp/telemetry-ios-verify.TNAhkx` |
| Native generic build | PASS | Xcode 26.3, iOS 26.2 SDK; `/tmp/telemetry-ios-verify.TNAhkx` |
| iPhone 17 Simulator build/install/launch | PASS | iOS 26.5 runtime; `/tmp/telemetry-ios-sim-runtime.MqtRnP` |
| Simulator dashboard smoke | PASS | Screenshot `/tmp/telemetry-ios-simulator-1790513017.png`; disconnected/stale states rendered explicitly |
| Physical iPhone build | PASS | iPhone 17, iOS 27.0 build 24A437; `/tmp/telemetry-ios-device-build.e8d1Bm` |
| Physical iPhone install | PASS | `devicectl` installed `local.webdashboard.Telemetry`; `/tmp/telemetry-ios-device-run.sS9S1r` |
| Physical iPhone launch | PASS | `devicectl` launched app and process was observed; same run evidence |
| Physical XCUITest runner | PASS | Existing UI test plus session-control test passed on iPhone 17; `/tmp/telemetry-ios-physical-ui-session4.CRCSoc` |
| BLE scan automation identifier | PASS | Reproduced the selector loss under the developer card, added an accessibility containment boundary, and passed `testBLEScanControlExposesStableAutomationIdentifier` on physical iPhone 17; `/tmp/telemetry-ios-ble-identifier-physical-green.L5akRI/result.xcresult` |
| Physical iPhone BLE scan | PASS | Temporary physical XCUITest started the app's read-only BLE scan for 15 s; `/tmp/telemetry-ios-ble-scan-smoke.vNi7bf/result2.xcresult` passed and the UI reported `Found 54 BLE peripheral(s)` |
| Current main simulator build/run | PASS | XcodeBuildMCP generated a clean project in `/tmp/telemetry-ios-sim-current.lM06ab`, built and launched `local.webdashboard.Telemetry` on iPhone 17 iOS 26.5; UI snapshot reported 151 elements and the screenshot showed the live cockpit in one viewport |
| Physical REC/GPS transition | PASS (foreground) | REC and GPS state labels were observed; SpringBoard `Change to Always Allow` was handled by the test; same session evidence |
| Physical session UI screenshot | PASS | XCUITest attachment `/tmp/telemetry-ios-physical-ui-attachments.cMmlG8/14676355-EFAB-470C-99D0-D473716A3638.png` visibly shows `RECORDING` and `GPS ON`; CAN remains honestly `DISCONNECTED/STALE` without vehicle input |
| Physical SQLite GPS recording | PASS (foreground) | `devicectl` app-container copy `/tmp/telemetry-ios-physical-data.Jsd74N`; 16 `LOCATION` rows over 172.579 s preserve original/received epoch, monotonic time, coordinates, altitude, speed, course, and horizontal/vertical accuracy |
| Physical restart recovery | PASS | After relaunch, `/tmp/telemetry-ios-physical-data-recovery.3OJQ4h` shows `recording_interrupted` and `ended_at` for the previously open session; outbox remains durable with 18 pending events |
| Physical background transition automation | PASS | XCUITest on physical iPhone 17 pressed Home, waited 15 s, and reactivated the app; `/tmp/telemetry-ios-physical-background-smoke3.rEyR63/result.xcresult` reports 1 passed test |
| Physical background SQLite continuity | PASS | `/tmp/telemetry-ios-physical-background-data.gz8ERD`; latest session records `background` at `1790516884.85912`, `foreground` at `1790516899.6472` (14.788 s), and 4 GPS rows during that interval |
| Physical 30-minute background recording | PASS (background, screen not locked) | Temporary physical XCUITest ran Home/background for 1,800 s and passed; `/tmp/telemetry-ios-30min-background.jqHbbd/` result reports 1 passed test |
| Physical 30-minute GPS durability | PASS | `/tmp/telemetry-ios-30min-closed.WGzXNG`; latest session duration `1883.171 s`, 1,809 GPS rows, GPS source span `1816.504 s`, and a durable `recording_interrupted` close event |
| iOS 27 SDK | BLOCKED | Mac has Xcode 26.3 / iOS 26.2 SDK; `iphoneos27` is not installed |
| P1 GPS storage contract | PASS (software) | `LocationSample` preserves source timestamp, app epoch/monotonic receive times, coordinates, altitude, speed, course, and horizontal/vertical accuracy; `TelemetryStore` and `MeasurementRecorder` retain the same sample |
| Foreground GPS/recording | PASS | Physical UI automation started REC/GPS and the app stored GPS samples in SQLite; CAN remains disconnected without vehicle hardware |
| Screen-lock GPS/recording | NOT TESTED | Public XCUITest APIs exposed here can press Home but cannot press the physical lock button; a manual lock/unlock run is still required |
| Canonical workspace direct Xcode build | BLOCKED: HOST TOOLCHAIN | Xcode 26.3 mis-resolves Swift package file-list paths when invoked from this workspace's space/non-ASCII path; generated projects in `/tmp` and GitHub CI build successfully |
| BT4N GATT profile | BLOCKED: PHYSICAL HARDWARE REQUIRED | The iPhone scan found 54 UUID/RSSI entries with no human-readable adapter identity, no `NANICAR`, `ELM327`, or `BT4N` match, and no verified adapter GATT profile; the app correctly keeps the adapter profile `NOT CONFIGURED` |
| Vehicle raw CAN | BLOCKED: PHYSICAL HARDWARE REQUIRED | No ELM327-to-vehicle capture |
| Raw-to-decode-to-dashboard recording E2E | BLOCKED: PHYSICAL HARDWARE REQUIRED | Real frame and GPS are required |
| One-hour endurance | NOT TESTED | Depends on physical E2E |
| CarPlay scene manifest wiring | PASS (software) | Built `Info.plist` contains `CPTemplateApplicationSceneSessionRoleApplication`, `CPTemplateApplicationScene`, and `Telemetry.CarPlaySceneDelegate`; build 15 physical test passed in `/tmp/telemetry-ios-carplay-manifest-build15.i5E1hA/result.xcresult` |
| CarPlay compile | PASS | CarPlay sources compiled in the native build |
| CarPlay simulator rendering | NOT TESTED | No CarPlay head-unit simulator/runtime was present in the installed Xcode or `simctl` device inventory; iPhone simulator rendering is not a CarPlay runtime result |
| CarPlay entitlement approval | NOT TESTED | No approval evidence in this checkpoint |
| CarPlay physical vehicle runtime | NOT TESTED | Requires approved entitlement and head unit |
| Vector/CANoe/CANape | NOT TESTED | Future/optional scope |

## Tooling Notes

- The XcodeBuildMCP simulator path was blocked by a non-ASCII workspace path
  being concatenated into source paths. The same generated project was tested
  from an ASCII `/tmp` staging path with `xcodebuild` and `simctl`.
- `scripts/ios-bt4n-preflight.sh` previously recognized only `available`
  device rows. It now accepts both `available` and `connected`, and the live
  preflight reports the connected iPhone 17 correctly.
- The preflight still reports the iOS 27 SDK as blocked and BT4N as not tested;
  those are real blockers, not software failures.
- `LocationService` starts Core Location with automotive navigation accuracy,
  disables automatic pausing, enables background updates, and records invalid
  horizontal fixes as unavailable rather than inventing a coordinate.
- The physical session-control test uses label-based SwiftUI assertions and a
  SpringBoard permission bridge. An earlier attempt failed because the
  permission alert remained foreground and the test queried a label as an
  identifier; the corrected test passed on the physical iPhone.

## Next Automatic Action

Run post-commit CI, inspect the CarPlay projection/category configuration, and
prepare the physical-session checklist without changing the existing telemetry
architecture.

## Next Human Action

On the physical iPhone, perform one manual screen-lock/unlock run while REC and
GPS are active. Separately connect the NANICAR BT4N to the Santa Fe MX5 HEV and
provide the observed BLE/GATT and raw
ELM327 response evidence. Do not treat the current software or simulator PASS
results as vehicle CAN or BT4N compatibility proof.
