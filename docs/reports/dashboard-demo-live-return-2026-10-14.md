# Idle Demo return to disconnected LIVE — 2026-10-14

Stopping a Demo preview without an adapter profile left `runMode` in DEMO, while both LIVE start controls required a profile. The source change makes `stopDemoAdapter()` and its `stopLiveAdapter()` alias select LIVE and present “Adapter disconnected” after stopping an idle Demo. It does not start an adapter, recording, GPS, or a server connection.

The mode changes only when local recording is disabled, the recorder and write queue are absent, and recording is not closing. A recording or accepted-write boundary retains DEMO so session measurements keep their source mode. Replay retains its mode. Returning automatically after a recording finishes is outside this change.

## Verification

Tests were added before changing the app source. The actual method extractor reported four behavior failures on the unchanged source: no-profile return, disconnected status, repeated Stop, and the Stop live alias. After the seven-line app change, the same coordinator harness passed 46/46 assertions. This harness compiles actual coordinator method bodies with explicit transport, recorder, and location boundary doubles; it does not execute UIKit or native acquisition services.

Six separate mutations in temporary source copies were rejected by behavior assertions: removing each of the four recording guards, changing Replay to LIVE, and automatically starting GPS. The canonical source was not mutated for these checks.

| Check | Result | Scope |
| --- | --- | --- |
| `python3 -B scripts/verify_telemetry_model.py` | 46/46 | Actual coordinator methods with boundary doubles |
| `python3 -B scripts/verify_dashboard_regressions.py <repo> <output>` | EN 74/74; KO 74/74 | Help, localization, dashboard and BLE/location source behavior |
| TelemetryCore SwiftPM tests | 271/271 | Complete canonical Core package |
| Python unit/contract fixtures | 227/228; zero errors or skips | Device commands mocked; no native runner |
| Generic iOS Simulator Debug build, signing disabled | Exit 0, `BUILD SUCCEEDED` | Fresh 207-input source snapshot; no install or launch |
| Platform documentation validation and `git diff --check` | Exit 0 | Repository consistency |

The one Python failure is `test_bundled_captures_and_provenance_are_complete`, reporting `Incomplete source provenance`. Existing Help PNGs, markers and their manifest were preserved; this change does not complete the 28-image recapture. It must not be described as an all-green project regression.

The build still reports the unchanged nested weak-capture warning, App Intents metadata extraction skipped without that framework dependency, and SwiftPM's deprecated native-build-system option. No build error occurred. Native UI, actual transport callbacks, real recording/GPS, accessibility and viewport checks of this new source remain unverified.

## Source and installation boundary

The reviewed base is `4ebbfd3eedfcee048232a6537af1ce298b550fcb`. The changed `TelemetryModel.swift` SHA-256 is `4de0922cd608cac8d3af16c37cdbaff846937ccdd98f1acf45a00742e3d1b97a`. All 207 build input hashes still matched the canonical source after the build.

The uninstalled generic build loader SHA-256 is `2a8208df001ff8e81f4fc67cf1177106ade8fd98117e739188a8acf5efad641c`; its implementation-bearing `Telemetry.debug.dylib` is `5fd8736bbdbf5b3d5f35730bafed84d07f4f638f4974f6afa04d571f941f4da7`.

The owned simulator remains `DDD24F62-C420-4211-B607-D1B03EBF881B`, with the previously installed source `1c71f8e47b43ceebf1d76d203c6c115ed65c832e`. Its loader SHA-256 is `c6931a1fac330d84e7baaf7c850113a54c561a03dbf4dd6f8e4cac82d6b080f3`, and debug dylib SHA-256 is `9fee05c32e112cf9b114b8a457d527321eb356a94ac69a839673e9d6bc25899b`. Signature verification returned 0. Previous screenshots therefore do not verify this fix.

## Preservation and remaining boundary

The read-only post-check found the exact approved model change among 172 recorded app inputs and no unexpected drift. User files 45/45, candidate inputs 228/228, prior manifests and the hard-blocked capture helper, Help resources 57/57, installed bundle files 68/68, and app data files 10/10 remained unchanged during this fix. Dashboard values and array order equal the preserved original; preference bytes and English language remain restored. No measurement database was created.

No app was installed, launched, or operated, and no native UI runner, data fixture, recording, GPS, permission, security, physical-device or other-simulator operation occurred. The previously rejected fixture/runner workflow remains blocked pending separate approval. Local receipts, RED/GREEN logs, mutation logs and full build logs are under `demo-live-return-fix-20261014` in the delegated task workspace, with the disposable build under `/tmp/webdashboard-demo-return-20261014`.
