# Native iOS Telemetry

SwiftUI / Core Location / SQLite / background URLSession implementation.
This is the replacement for the React Native iOS scaffold. It is under active
validation and is not a released product. App Store/CarPlay approval is not implied.

## Implemented

- Six CAN gauges and two bounded, 60-second Charts views over the existing v1 WS stream.
- Original GPS capture timestamps; unknown speed/course stays unknown.
- Core Location continuous updates after explicit Start and Always authorization.
- Durable SQLite outbox: records survive process restart and remain until server ACK.
- File-backed background URLSession upload to authenticated /api/v2/ingest.
- OS-registered retries with earliestBeginDate, restored configuration on background
  relaunch, and serial preparation that finishes before releasing background callbacks.
- Keychain credential storage, HTTPS validation, explicit Stop, and persisted MARK events.

## OBD work in progress

The user owns a NANICAR ELM327-BT4N (12V) and a Hyundai Santa Fe MX5 HEV.
`TelemetryCore/ELM327.swift` provides a pure, hardware-independent prompt framer and
headerless Mode 01 decoder for capabilities, RPM, speed and coolant temperature.
It rejects ambiguous/malformed replies and keeps no-data separate from real zero.
The parser's examples/tests are synthetic, not recordings from this scanner.

**Bluetooth connection, live OBD display, background polling and OBD ingestion are
not implemented yet.** The existing v2 upload accepts GPS/MARK/STATE, not OBD.
Profile discovery must precede Core Bluetooth transport wiring; do not assume common
ELM GATT UUIDs. Track requirements and real-device evidence in
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
then build for the connected device. The initial native version remains 0.1.0 while
Git integration and release verification are incomplete. Use the original source
path only if it has no NBSP; otherwise use the verification snapshot for a trial build
and make edits back in the canonical source.

In the app, enter the trusted HTTPS server origin in Connection. Store the ingest
credential in Keychain. The server needs INGEST_TOKEN configured; without it the
v2 endpoint rejects requests. Never put credentials in source files or reports.
Connect receives CAN; Start GPS begins native recording after Always authorization.
Stop ends collection. MARK is shown only after its local durable write completes.

For locked-screen operation, the native store uses file protection available after
first unlock. Force-quit, reboot before first unlock, revoked permissions, and OS
resource policy can still interrupt collection or transmission. Test and report each
case; a healthy display or simulator is not a 30-minute background pass.

## Remaining release gates

Real-device signing/install and 30-minute logs, automatic pairing/provisioning,
full upload recovery fault testing, Naver map/roadview integration in the native UI,
CarPlay templates/entitlement, Android parity, Windows packaging and real CAN adapter.
See ../docs/production-plan.md for the full completion criteria.
