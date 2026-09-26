# Native iOS Telemetry

SwiftUI / Core Location / SQLite / background URLSession implementation.
This is the replacement for the React Native iOS scaffold. It is under active
validation and is not a released product. App Store/CarPlay approval is not implied.

## Implemented

- Six CAN gauges and two bounded, 60-second Charts views over the existing v1 WS stream.
- Versioned dashboard pages with persisted portrait/landscape orientation, grid-based
  rect layout, page selection, drag/resize editor controls, z-order and legacy-profile
  migration.
- Widget rendering covers numeric/circular/bar/LED/status/raw/bit/time-series/GPS
  representations with stale-state handling; map track/provider integration remains
  a separate gate.
- The optional CarPlay scene is status-only and receives live projection state through
  an entitlement-gated bridge; no CarPlay entitlement or arbitrary gauge UI is assumed.
- Original GPS capture timestamps; unknown speed/course stays unknown.
- Core Location continuous updates after explicit Start and Always authorization.
- Durable SQLite outbox: records survive process restart and remain until server ACK.
- File-backed background URLSession upload to authenticated /api/v2/ingest.
- OS-registered retries with earliestBeginDate, restored configuration on background
  relaunch, and serial preparation that finishes before releasing background callbacks.
- Keychain credential storage, HTTPS validation, explicit Stop, and persisted MARK events.
- In-app JSON export of the local SQLite-backed measurement session for offline analysis.

## OBD work in progress

The user owns a NANICAR ELM327-BT4N (12V) and a Hyundai Santa Fe MX5 HEV.
`TelemetryCore/ELM327.swift` provides a pure, hardware-independent prompt framer and
headerless Mode 01 decoder for capabilities, RPM, speed and coolant temperature.
It rejects ambiguous/malformed replies and keeps no-data separate from real zero.
The parser's examples/tests are synthetic, not recordings from this scanner.

The app declares `location` and `bluetooth-central` background modes for the
explicitly started session. This is a capability declaration, not a guarantee of
continuous execution after suspension or termination.

The current software boundary also includes a versioned `AdapterProfile` JSON,
explicit observed-profile BLE and Wi-Fi transports, cancellation-safe ELM session
startup, and a live adapter controller that decodes every matching signal in the
profile and records the raw frame plus decoded samples. The demo adapter exercises
the same session, decoder, recorder and UI path without radio hardware.
The existing v2 upload accepts GPS/MARK/STATE, not OBD frames.

This is not BT4N compatibility proof. Profile discovery must precede Core Bluetooth
use; do not assume common ELM GATT UUIDs or that the box's dual-mode claim means
arbitrary iOS Bluetooth Classic access. Track requirements and real-device evidence in
[ADR-0004](../docs/adr/0004-obd-bt4n-integration.md) and
[the hardware run sheet](../docs/reports/obd-bt4n-compatibility.md).

## Build and verify

Use a full Xcode installation selected by xcode-select or DEVELOPER_DIR and XcodeGen
installed with its SettingPresets resources. XcodeGen 2.44.1 was used for the current
project. A binary-only copy without share/xcodegen/SettingPresets is insufficient.

```bash
# At the repository root, using your full Xcode installation:
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
./mobile-ios/scripts/verify.sh build

# UI checks on an available simulator (not an iPhone device identifier):
SIMULATOR_ID="<simulator-uuid>" ./mobile-ios/scripts/verify.sh test
```

The script stages source copies in a unique ASCII /tmp path to avoid an observed
Xcode response-file parsing failure for NBSP-containing paths. Source hashes,
compiler logs, Core test output and xcresult stay in the printed artifact directory.
This is a build snapshot, not a second editable checkout. Edit only this repository.
Simulator signing uses the local ad-hoc identity; it does not provision a real iPhone.
Do not open staged /tmp Xcode projects in Xcode 26.3; its Source Control workspace
status integration has a crash path for that temporary snapshot. Use the shell
verification command and inspect the printed artifacts instead.

## Real device

The current user-reported target is iPhone 17 / iOS 27 (2026-09-23).
Verify its exact OS build after reconnecting. Use Xcode 27 with the iOS 27 SDK
for this validation; Apple's [requirements](https://developer.apple.com/xcode/system-requirements/)
list macOS 26.6 or later. The checked host runs macOS 26.6.2 but still has Xcode 26.3,
and devicectl currently reports the iPhone unavailable. Prior iOS 26.2 simulator
results do not establish iOS 27 compatibility. Rebuild, sign, install and repeat
the locked-screen/recovery test on the updated device. This target update does not
raise the app's minimum deployment version or constitute a release.

Generate/open Telemetry.xcodeproj with XcodeGen, select the verified Apple team,
then build for the connected device. The current native development version is 0.1.1 while
Git integration and release verification are incomplete. Use the original source
path only if it has no NBSP; otherwise use the verification snapshot for a trial build
and make edits back in the canonical source.

After a signed device build exists, use the bounded install/launch check:

```bash
DEVICE_ID="2C0892EB-662D-5D9A-A908-96EA723DEEB4" \
APP_PATH="/path/to/Telemetry.app" \
./mobile-ios/scripts/verify_device.sh
```

The script records device, install, launch, and process evidence. A trust error
returns exit code 10 and prints the exact iPhone Settings path; it never handles
passwords, MFA, payment, or device passcodes.

In the app, enter the trusted HTTPS server origin in Connection. Store the ingest
credential in Keychain. The server needs INGEST_TOKEN configured; without it the
v2 endpoint rejects requests. Never put credentials in source files or reports.
Connect receives CAN; Start GPS begins native recording after Always authorization.
Stop ends collection. MARK is shown only after its local durable write completes.

For locked-screen operation, the native store uses file protection available after
first unlock. Force-quit, reboot before first unlock, revoked permissions, and OS
resource policy can still interrupt collection or transmission. Test and report each
case; a healthy display or simulator is not a 30-minute background pass.

## CarPlay simulator and account gates

The current Xcode Simulator can open a CarPlay external display. With a booted
simulator, select `I/O > External Displays > CarPlay`. This verifies the host
display only. The app is intentionally not registered with a guessed CarPlay
entitlement or scene manifest, so an app appearing in that window is not yet an
acceptance criterion. See the dated execution checkpoint at
`../docs/reports/carplay-simulator-and-account-gates-2026-09-26.md`.

CarPlay app display requires an Apple-approved category entitlement and the
corresponding App ID/Xcode configuration. The Account Holder submits the managed
capability request in Certificates, Identifiers & Profiles; membership, signing,
and physical-device provisioning are separate gates. Do not add an entitlement
key until Apple assigns the exact capability. The first planned surface is a
status-only system template, not a copy of the high-frequency phone dashboard.

## Remaining release gates

Real-device signing/install and 30-minute logs, automatic pairing/provisioning,
live BT4N profile capture, vehicle signal validation, full upload recovery fault
testing, Naver map/roadview integration in the native UI, CarPlay templates/entitlement,
Android parity, Windows packaging and real CAN adapter acceptance.
See ../docs/production-plan.md for the full completion criteria.
