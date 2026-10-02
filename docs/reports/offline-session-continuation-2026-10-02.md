# Offline session continuation

## Scope and plan

User left the vehicle: current connection/power UNKNOWN; physical tests held.
No physical device/radio/vehicle API was contacted in this checkpoint.

1. Preserve original physical data and pending work in a private durable backup.
2. Reuse Recorder/Replay/Store with a read-only saved-session archive and existing
   Sessions/Dashboard UI. No transport framework replacement.
3. Verify real-record exports separately from synthetic Simulator UI and run
   regression, then preserve a precise next-vehicle checklist.

## Checkpoint fields

- CURRENT MAIN baseline: `a8120b696f1f52f42ccb0aa433dd40c911d854ee`; final source
  commit is the main commit adding this report. Do not revert old feature refs.
- APP VERSION/BUILD: 0.22.4 (20), qualifying saved-session export/Replay feature
  and reproduced recording-drain fix. No audit-only version bump or release ZIP.
- CHANGED FILES: MeasurementArchive, shared CSV formatting, Replay snapshot,
  TelemetryModel/Sessions/Signals/Live UI, pipeline drain/batch handling, native
  and Core regression tests, isolated validation runners/CI and scoped docs.
- WHY: exports previously required an in-memory active/completed recorder after
  launch; saved sessions needed an actual read-only UI path. Regression exposed
  Stop returning before response/signal persistence finished.
- PHYSICAL EVIDENCE: no new physical run, install, GPS or CAN claim. Last known
  iPhone build remains 0.22.3 (19). Preserved 25-session/6,586-row evidence only.
- SIMULATOR EVIDENCE: iOS 27 iPhone 17 fixture UI, explicit DEMO recorded data;
  local hosted tests use a separate disposable Simulator. Never physical PASS.
- BLOCKERS: vehicle tests held by user; RPM/Car Scanner alignment and physical
  new-build regression remain untested. CarPlay entitlement/runtime separate.
- NEXT AUTOMATIC ACTION: CI software regression and the remaining offline tasks
  in the resume checklist; no automatic vehicle discovery or reconnect.
- NEXT HUMAN ACTION: none now. Fresh power/connection/parked confirmation and
  security prompts only when the user next resumes the vehicle gate.

## Preservation

Copied the complete prior private evidence directory (~1GB) to an owner-only
directory under `~/.local/share/WebDashboard/evidence/physical-20261002.*`.
Original temporary evidence was retained too. SQLite bytes were compared with
the source; private DB/exports contain real GPS and must never enter Git/CI.
User's unrelated `mobile/` modifications remained unchanged and unstaged.

## Implementation and acceptance

- [x] Archive opens SQLite READONLY; no directory/session creation, migrations,
  journal-mode changes or write API. Stable closed-session snapshot transaction.
- [x] Selected session CSV/JSON export survives model restart; original payload,
  timestamps, mode and session identity retained. Shared existing CSV escaping.
- [x] Unknown/NUL IDs and open/oversized snapshots fail closed; no silent truncation.
- [x] Replay snapshot validates the whole export before UI mutation, retains
  recorded timestamps and distinguishes raw CAN/diagnostic/GPS provenance.
- [x] Recorded reference time is for display freshness only; export timestamps
  are not rewritten. Bad/drop/RTT are not fabricated from live counters in Replay.
- [x] Replay prohibits recording/GPS start/connection/MARK/upload and does not
  auto-reconnect on Stop. CarPlay projection does not receive replay values as
  live summary. No entitlement or runtime claim is implied.
- [x] Existing Numeric/Semi Gauge/Bar render the same fixture value 48.5; proper
  REPLAY/DEMO labels and disabled acquisition controls. Screenshots reviewed.
- [x] Stop waits for accepted consumer work; raw response and decoded signals
  are transactionally grouped. Concurrent repeated Stop shares one drain task.
- [ ] Continuous playback/seek and original graph/track timeline are not implemented.
- [ ] Physical new-build install/runtime and all real-vehicle endurance are held.

The source probe excludes UI/hardware boundaries; native hosted tests execute
real App/SQLite in isolated containers. Original failed artifacts were kept:
missing Archive API RED; Replay recording guard RED; one full Core run exposed
response-only export before Stop drain. Mixed raw/diagnostic snapshot test also
failed before fixing last-source selection. After fixes, Core 214/214 passed.
UI failures identified card/canvas accessibility-container identifiers and an
incorrect fixture portrait grid; both were fixed and the isolated UI test rerun.

## Verification

| Gate | Result | Evidence boundary |
|---|---|---|
| Core regression | PASS | 214 tests, zero failures; Mock/fixture software, not vehicle |
| Hosted native regression | PASS | 18 tests, zero failures; real App/SQLite on Simulator |
| Coordinator source harness | PASS | 25 assertions; explicit boundary substitutes |
| Profile import / GATT source probes | PASS | 12 / 6 assertions, not new BLE evidence |
| Lifecycle runner guard tests | PASS | 8 tests including ASCII staging and no overwrite |
| Dedicated Replay UI | PASS | 1 executed test, no skips; DEMO fixture, actual screenshots |
| Generic iPhoneOS build | PASS | iOS 27 SDK, unsigned generic target; NOT install/runtime |
| Copied physical records export/Replay | PASS | 2 x 96 rows; SOC 46.0 and 48.5; no new measurements |
| Physical vehicle/new-build runtime | BLOCKED | USER-REQUESTED HOLD; connection/power unknown |
| CarPlay entitlement/head-unit | NOT TESTED | no approval/runtime substitution |
| iPad/Android/screen lock | OUT OF SCOPE | no acceptance requirement |

Core emits its existing read-only WAL precondition observation; this is not a
recovery verdict. Simulator system accessibility loader warnings are platform
diagnostics, not removed by changing app code or counted as physical failures.

## Commands and limits

```bash
python3 scripts/validate_platform_docs.py
python3 scripts/verify_telemetry_model.py
python3 scripts/verify_profile_import.py
python3 scripts/verify_ble_profile.py
python3 -m unittest discover -s scripts/tests -p test_ios_lifecycle_runner.py
python3 scripts/verify_ios_lifecycle.py --result-directory /tmp/new-hosted-results
python3 scripts/verify_offline_replay.py --result-directory /tmp/new-replay-ui-results
```

Each result path must be new. Runners copy source to ASCII paths, create only
their own Simulator and delete it afterward. They do not overwrite the canonical
Xcode project or select an existing/user Simulator. UI runner seeds through the
actual parser/decoder/recorder before reading through Archive/Replay; expected
SOC is independently fixed at 48.5. CI now runs this dedicated UI gate and stores
only synthetic fixture artifacts. Default unseeded UI suites skip this fixture
test; the dedicated runner rejects skips/zero-test results.

Archive lists latest 100 sessions (API limit <=1000); load/export is bounded to
200,000 rows. Larger exports require future streaming, not silent truncation.
This release is not certified commercial/physical E2E completion.

Resume using [the vehicle checklist](vehicle-resume-checklist-2026-10-02.md).
