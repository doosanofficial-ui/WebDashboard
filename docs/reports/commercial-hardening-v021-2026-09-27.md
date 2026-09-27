# Commercial Hardening v0.21 Checkpoint

Date: 2026-09-27

## P0 capture preparation

BLE GATT observations can now be saved from Setup as a protected JSON file under
the app's Application Support directory using `Save observation`. The capture
contains only the observed peripheral/service/characteristic profile; it sends
no ELM command and does not select UUIDs automatically. The saved artifact is
intended to become the first redacted physical BT4N regression fixture.

## Release identity

- Native version: `0.21.0`, build `13`.
- Physical device build/install/launch: PASS,
  `/tmp/telemetry-ios-device-build.0EH5Of` and
  `/tmp/telemetry-ios-device-run.GjmEXW`.
- Hardware compatibility remains `NOT TESTED` until a BT4N GATT profile and raw
  ELM response are captured from the target vehicle.

## Remaining P0 evidence

- Connect BT4N to the vehicle OBD port and run BLE Scan/Inspect GATT on the
  connected iPhone 17.
- Save the observation, verify write/notify properties, create the profile, and
  run the read-only ELM monitor.
- Preserve the raw capture and compare CANFrame → SignalDecoder → TelemetryStore
  → dashboard values with the source response.
