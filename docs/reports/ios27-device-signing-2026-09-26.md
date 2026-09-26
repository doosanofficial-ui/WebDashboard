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
- App version: 0.1.1, build 1

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
