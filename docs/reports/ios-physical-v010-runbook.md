# iPhone 17 Physical Verification Runbook

Target: iPhone 17 / iOS 27.0 (`24A437`). This runbook is for the native
Telemetry app. It does not claim iOS 27 SDK compatibility while the host uses
Xcode 26.3 / iOS 26.2 SDK.

## 1. Unlock and Launch

Unlock the phone with Face ID or the device passcode. Codex must not enter the
passcode. Keep the wired connection active and run:

```sh
DEVICE_ID="2C0892EB-662D-5D9A-A908-96EA723DEEB4" \
APP_PATH="/tmp/telemetry-ios-device-condition-live2.wI9BNU/app-build/Build/Products/Debug-iphoneos/Telemetry.app" \
./mobile-ios/scripts/verify_device.sh
```

Expected: exit `0`, `Physical launch PASS`, and a non-empty `processes.log`
containing `Telemetry.app/Telemetry`. Exit `12` means the phone is locked;
exit `10` means developer trust/verification is incomplete.

## 2. GPS and Recording

- Open the app and select `Start GPS`.
- Grant Precise Location and When In Use; grant Always when testing screen lock.
- Confirm a valid location fix, accuracy, speed, and heading.
- Confirm the cockpit `REC` state is ON.
- Tap `STOP`, then export both `measurement JSON` and `measurement CSV`.
- Confirm JSON contains session start/end metadata and ordered `CAN`, `SIGNAL`,
  `LOCATION`, and `SYSTEM` rows.

Acceptance: no synthetic zero replaces an unknown GPS field; a stopped session
remains exportable; a new `REC` starts a new session ID.

## 3. Adapter and Signal Configuration

- Open `Connection > BLE discovery` and tap `Scan BLE`.
- Select the physical adapter and tap `Inspect GATT`.
- Copy the observation and record service/characteristic UUIDs and properties.
- Import or edit the adapter profile and define at least one signal.
- In `Dashboard Editor`, add a widget, bind its signal ID, and configure units,
  range, condition, hysteresis, and hold time.

Acceptance: discovery does not connect to unselected devices; no CAN write is
sent; a valid frame updates the bound widget; a timeout renders `STALE`.

## 4. 30-Minute Background Trial

Record the following before starting:

- app version and build
- iOS build
- adapter profile ID
- vehicle stationary/route context
- start epoch and initial queue depth

Procedure:

1. Start GPS and recording.
2. Start the read-only adapter monitoring session.
3. Lock the screen for 30 minutes without force-quitting the app.
4. Unlock and export JSON/CSV.
5. Compare generated, persisted, uploaded, acknowledged, and rejected counts.

Acceptance: every gap is explained by a recorded system event or transport
counter. Do not infer background success from a still-visible screen.

## 5. CarPlay Gate

CarPlay app rendering remains blocked until Apple grants the category-appropriate
managed capability. The current app intentionally exposes only a compile-gated,
status-only projection and does not invent an entitlement or scene manifest.

Evidence to collect after approval:

- final App ID and team identifier
- approved capability request/read-back
- signed entitlement inspection
- CarPlay simulator app appearance
- physical head-unit connection and status-list interaction
