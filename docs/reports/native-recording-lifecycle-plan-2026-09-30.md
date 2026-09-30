# Native recording lifecycle verification plan

Goal: close issue #24's hosted-app recording coverage gap without substituting recorder or UIKit boundaries.
Baseline: 44787a1fc986d399688c5a2c949be8a210a55993.

1. Add Simulator-only XCTest cases compiled against all unchanged App sources in a distinct LifecycleHost bundle. Exercise Start, MARK admission, Stop, JSON/CSV export, repeated Stop, fast restart, LIVE/DEMO rejection and a real SQLite trigger failure. Never run on physical hardware or delete existing sessions.
2. Add an opt-in supplemental XcodeGen spec and bounded runner that creates/deletes only its own disposable simulator, preserves xcresult/logs, and rejects empty/skipped/failing test runs. Unit-test runner decisions before use.
3. Execute native app/Core/coordinator/contracts CI. Record exact execution counts, runtime/SDK, result links and limits. A syntax check on Linux is not a hosted app test. Make no product fix without a reproduced defect.

Acceptance: hosted XCTest uses real TelemetryModel, MeasurementWriteQueue, MeasurementRecorder, SQLite and exports. Distinct host identifier and new simulator isolate user data. No BLE queries, GPS permission request, uploads or CarPlay qualification. Source-generated tests remain supplemental. Main changes are sequential with parent checks.
