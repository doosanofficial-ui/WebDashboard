# Failure-atomic adapter profile import

Baseline: `c6a706a8980f84f51b892edb76b7263dec5b5c50`. Scope: issue #25; no vehicle commands or user data changes.

## Plan and acceptance
1. Reproduce failed JSON/file replacement and caller success propagation before editing production code.
2. Validate and persist a candidate before publishing its profile/timeouts; retain previous state on failure, return an explicit result to the BLE conversion caller.
3. Run focused regressions, then full Core/coordinator/Simulator/hosted CI. Never substitute these results for iOS 27 or physical qualification.

## Reproduction and correction
The baseline importer published configuration before its file write, cleared the previous profile in catch, accepted a missing destination, and its BLE caller reported success unconditionally. The exact-method control-flow probe reproduced 7 failed assertions out of 12 on Linux Swift 6.2.1. After the minimal fix it passes all 12. The probe uses reduced profile/GATT substitutes and real Foundation file operations: it is not a full App or manufacturer-profile validation test.

`AdapterProfileHostedTests` adds six native tests of the real App entry points and real AdapterProfile/Foundation: malformed JSON, unsupported schema, blocked atomic save plus retry, successful raw+diagnostic replacement, rejected editor input and editor file failure. The combined hosted suite must now execute exactly 13 tests (seven prior lifecycle tests plus these six). Native execution evidence is recorded in CI and issue #25 after the run completes; syntax checks alone are not runtime PASS.

The file-failure fixture moves only its disposable host's profile to a unique backup, places a directory at the target path, verifies the backup bytes, and restores it. It never uses an existing user simulator or actual Bluetooth/GPS connection. The success-path profile schema, wire format and atomic-write option remain unchanged. No production dependency or schema migration was added.

## Reproduce
- `python3 scripts/verify_profile_import.py [optional-baseline-TelemetryModel.swift]`
- `swift test --package-path mobile-ios/TelemetryCore`
- `python3 scripts/verify_telemetry_model.py`
- macOS/Xcode: `python3 scripts/verify_ios_lifecycle.py --result-directory /tmp/profile-lifecycle-UNIQUE`

## Boundaries
This closes profile-import failure atomicity, not hot profile replacement while an adapter is actively acquiring, all callback interleavings, complete session-browser/replay UI, database-migration robustness, iOS 27/BT4N/vehicle endurance or CarPlay approval/runtime. Those remain separate investigations or acceptance gates.
