# iPhone 17 Signing and Install Checkpoint

Checked: 2026-09-26; physical launch follow-up: 2026-09-27. This is a
physical-device signing/install/launch checkpoint, not an iOS 27 production
compatibility or release approval.

## Observed environment

- Physical device: iPhone 17, iOS 27.0, build 24A437
- Developer Mode: enabled
- Pairing: available, wired tunnel connected
- Xcode: 26.3
- Build SDK: iOS 26.2, not iOS 27
- Xcode account: Personal Team, Team ID 548HKZYKDP
- Previous app version: 0.1.1, build 1
- Previous feature build: 0.2.0, build 1
- Previous feature build: 0.3.1, build 1
- Previous feature build: 0.4.0, build 1
- Previous feature build: 0.5.0, build 1
- Previous feature build: 0.6.0, build 1
- Previous feature build: 0.6.1, build 1
- Previous feature build: 0.7.0, build 1
- Previous feature build: 0.8.0, build 1
- Previous feature build: 0.9.0, build 1
- Current feature build: 0.10.0, build 1

## Evidence

The current source was staged at an ASCII temporary path and built with:

- DEVELOPMENT_TEAM=548HKZYKDP
- CODE_SIGN_STYLE=Automatic
- -allowProvisioningUpdates
- destination: the physical iPhone 17

Result: **device build PASS**.

The resulting app passed local codesign --verify --deep --strict and contains:

- Apple Development signing authority
- matching team identifier 548HKZYKDP
- get-task-allow=true
- an Xcode-managed local provisioning profile containing the target device

devicectl device install app also returned installed and listed:

- Bundle: local.webdashboard.Telemetry
- Version: 0.1.1
- Build: 1

## Launch follow-up

The initial launch attempt was denied by SpringBoard because the Personal Team
developer had not yet been trusted on the phone. After the user completed the
device-side developer trust flow, the same signed app was verified again with:

```sh
DEVICE_ID=2C0892EB-662D-5D9A-A908-96EA723DEEB4 \
APP_PATH=/tmp/telemetry-ios-device-verify.58nYom/app-build/Build/Products/Debug-iphoneos/Telemetry.app \
./mobile-ios/scripts/verify_device.sh
```

Result: **physical launch PASS**.

- `devicectl` installed bundle `local.webdashboard.Telemetry`, version `0.1.1`, build `1`.
- `devicectl` returned `Launched application with local.webdashboard.Telemetry bundle identifier.`
- The process list observed `Telemetry.app/Telemetry` at PID `20622`.
- Verification artifacts: `/tmp/telemetry-ios-device-run.tyM1je/`

This proves installation and process launch after trust. It does not yet prove
first-run GPS permission handling, live CAN transport, recording endurance, or
background execution.

## Post-hardening device rerun

After the native hardening changes (validated server CAN contract, ELM327 DLC
handling, adapter reconnect loop, foreground GPS authorization path, MapKit track
widget, and read-only BLE discovery), a fresh device build was produced with the
same Personal Team and installed on the same phone:

- Build artifact: `/tmp/telemetry-ios-device-current.MdU7LB`
- Install/launch artifacts: `/tmp/telemetry-ios-device-run.Wn1dx9/`
- Result: **device build PASS, physical launch PASS**
- Process observed: `Telemetry.app/Telemetry`, PID `20655`

This rerun is still an Xcode 26.3/iOS 26.2 SDK result against iOS 27.0; it does
not promote the iOS 27 SDK, GPS permission, BT4N, vehicle CAN, background, or
CarPlay gates.

The versioned `0.2.0` feature build was then installed and launched again:

- Latest pipeline build artifact: `/tmp/telemetry-ios-device-pipeline.yamYu4`
- Install/launch artifacts: `/tmp/telemetry-ios-device-run.FIdDub/`
- Bundle version: `0.2.0` build `1`
- Result: **physical launch PASS**
- Process observed: `Telemetry.app/Telemetry`, PID `20668`

After the native `TelemetryStore` integration, the current v0.2.0 build was
rebuilt and rerun:

- Build artifact: `/tmp/telemetry-ios-device-store.eLLYmn`
- Install/launch artifacts: `/tmp/telemetry-ios-device-run.AMtycz/`
- Result: **physical launch PASS**
- Process observed: `Telemetry.app/Telemetry`, PID `20670`

The deferred-permission/selected-device BLE probe build was then installed and
launched:

- Build artifact: `/tmp/telemetry-ios-device-ble.y1h34q`
- Install/launch artifacts: `/tmp/telemetry-ios-device-run.5ggshA/`
- Result: **physical launch PASS**
- Process observed: `Telemetry.app/Telemetry`, PID `20673`

The current signal-quality timeout build was then installed and launched:

- Build artifact: `/tmp/telemetry-ios-device-quality.tAs6v6`
- Install/launch artifacts: `/tmp/telemetry-ios-device-run.K5CPXX/`
- Result: **physical launch PASS**
- Process observed: `Telemetry.app/Telemetry`, PID `20677`

The v0.3.0 session-envelope/CSV export build was then installed and launched:

- Build artifact: `/tmp/telemetry-ios-device-export.c7gtN1`
- Install/launch artifacts: `/tmp/telemetry-ios-device-run.swoXAp/`
- Bundle version: `0.3.0` build `1`
- Result: **physical launch PASS**
- Process observed: `Telemetry.app/Telemetry`, PID `20683`

The v0.3.1 adapter-runtime-event build was then installed and launched:

- Build artifact: `/tmp/telemetry-ios-device-events.PC74N4`
- Install/launch artifacts: `/tmp/telemetry-ios-device-run.yWyfHb/`
- Bundle version: `0.3.1` build `1`
- Result: **physical launch PASS**
- Process observed: `Telemetry.app/Telemetry`, PID `20685`

The v0.4.0 explicit recording lifecycle build was built and installed:

- Build artifact: `/tmp/telemetry-ios-device-recording.HYgERd`
- Bundle version: `0.4.0` build `1`
- Install: **PASS**
- Launch: **BLOCKED BY DEVICE LOCK**, verifier exit `12`
- Exact verifier log: `/tmp/telemetry-device-locked-check.log`

The v0.5.0 in-app widget creation build was built and installed:

- Build artifact: `/tmp/telemetry-ios-device-widget.EquIMF`
- Bundle version: `0.5.0` build `1`
- Install: **PASS**
- Launch: **BLOCKED BY DEVICE LOCK**, verifier exit `12`
- Exact verifier log: `/tmp/telemetry-v050-device-check.log`

The v0.6.0 widget configuration inspector build was built and installed:

- Build artifact: `/tmp/telemetry-ios-device-inspector.cqcbaA`
- Bundle version: `0.6.0` build `1`
- Install: **PASS**
- Launch: **BLOCKED BY DEVICE LOCK**, verifier exit `12`
- Exact verifier log: `/tmp/telemetry-v060-device-check.log`

The v0.6.1 BLE first-tap permission fix build was built and installed:

- Build artifact: `/tmp/telemetry-ios-device-blefix.xgcm8a`
- Bundle version: `0.6.1` build `1`
- Install: **PASS**
- Launch: **BLOCKED BY DEVICE LOCK**, verifier exit `12`
- Exact verifier log: `/tmp/telemetry-v061-device-check.log`

The v0.7.0 Signal Catalog Editor build was built and installed:

- Build artifact: `/tmp/telemetry-ios-device-signalcat.JGqsBN`
- Bundle version: `0.7.0` build `1`
- Install: **PASS**
- Launch: **BLOCKED BY DEVICE LOCK**, verifier exit `12`
- Exact verifier log: `/tmp/telemetry-v070-device-check.log`

The v0.8.0 dashboard alignment build was built and installed:

- Build artifact: `/tmp/telemetry-ios-device-align.Hd2blw`
- Bundle version: `0.8.0` build `1`
- Install: **PASS**
- Launch: **BLOCKED BY DEVICE LOCK**, verifier exit `12`
- Exact verifier log: `/tmp/telemetry-v080-device-check.log`

The v0.9.0 condition engine/editor build was built and installed:

- Build artifact: `/tmp/telemetry-ios-device-condition.GbIvr0`
- Bundle version: `0.9.0` build `1`
- Install: **PASS**
- Launch: **BLOCKED BY DEVICE LOCK**, verifier exit `12`
- Exact verifier log: `/tmp/telemetry-v090-device-check.log`

The v0.10.0 condition runtime integration build was built and installed:

- Build artifact: `/tmp/telemetry-ios-device-condition-live2.wI9BNU`
- Bundle version: `0.10.0` build `1`
- Install: **PASS**
- Launch: **BLOCKED BY DEVICE LOCK**, verifier exit `12`
- Exact verifier log: `/tmp/telemetry-v100-device-check.log`

## Limitations

- This build uses the installed iOS 26.2 SDK against an iOS 27 device. It is
  useful for signing/install and basic runtime investigation only; it is not an
  iOS 27 SDK compatibility result.
- Personal Team provisioning is for personal device testing and expires
  periodically. It does not provide App Store, enterprise distribution, or
  CarPlay entitlement access.
- CarPlay entitlement/category approval remains a separate Apple Developer
  Program gate.

Official references:

- https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices
- https://developer.apple.com/help/account/basics/about-your-developer-account
- https://developer.apple.com/support/compare-memberships/
