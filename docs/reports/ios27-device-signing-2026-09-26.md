# iPhone 17 Signing and Install Checkpoint

Checked: 2026-09-26. This is a physical-device signing/install checkpoint,
not an iOS 27 production compatibility or release approval.

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

## Current launch result

devicectl device process launch was denied by SpringBoard with:

Unable to launch because the application was not explicitly trusted by the user.

The local signature and provisioning profile checks pass, and Developer Mode is
enabled. Therefore the remaining observed boundary is device-side developer
trust/verification, not a compile or profile-mismatch failure.

On the physical iPhone, open the installed Telemetry app once. If iOS presents
an untrusted/verification prompt, complete the device trust/verification flow
in Settings for the Apple development account, ensure the phone has internet
access, then retry launch from Xcode or devicectl.

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
