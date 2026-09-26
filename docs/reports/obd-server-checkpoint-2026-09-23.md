# OBD Preparation and Server Resilience Checkpoint

Status: source checkpoint, not a release or physical-device compatibility pass.
Base: `444fc2e`; working branch: `codex/native-telemetry-productization`.

## Changes and verification

- Server: separate bounded single-writer WebSocket delivery per peer. A blocked
  ASGI transport no longer blocks CAN sequence progress, healthy peers or CSV writes.
  The latest-only slot exposes per-connection coalescing without changing global drops.
  Stalled writers time out; reader/writer/connection cleanup is tested.
- CSV: unique session suffix plus exclusive file creation. Frozen-time rapid restart,
  explicit ID collision and partial initialization tests preserve previous bytes and
  release handles. No log deletion or migration was performed.
- Initial regression: three expected failures (two overwrite cases and slow-peer stall).
  The first fix exposed ASGI cancellation in the existing TestClient smoke; cleanup
  shielding and cancelled-child handling corrected it without weakening the test.
- Native Core: typed Mode 01 requests and bounded ELM framing/decoding, eight synthetic
  OBD tests. Initial missing-code failure, CRLF parsing failure and x86_64 compiler
  type-check timeout were corrected before the final successful build.
- Updated target: user reports iPhone 17 / iOS 27. Local macOS is 26.6.2 and Xcode is
  still 26.3. Device discovery reports unavailable. No Xcode 27 or device pass claimed.
- Added BT4N / Santa Fe MX5 HEV product gates and a primary-source OSS/Pelican review.
  No third-party library or PID dataset was copied into the runtime.

| Verification | Result | Evidence |
|---|---|---|
| Python server suite | 28 PASS | `/tmp/webdashboard-tests.CYmkcl/obd-checkpoint-server.log` |
| Core XCTest | 23 PASS, including 8 OBD | `/tmp/telemetry-ios-verify.sNwiLP/core-tests.log` |
| App simulator compile | PASS, Xcode 26.3 / SDK 26.2 | `/tmp/telemetry-ios-verify.sNwiLP/app-build.log` |
| Web/RN GPS regressions | 23 PASS | `/tmp/webdashboard-tests.CYmkcl/obd-checkpoint-gps.log` |
| Service worker | 8 PASS | `/tmp/webdashboard-tests.CYmkcl/obd-checkpoint-sw.log` |
| Platform docs / whitespace | PASS | `validate_platform_docs.py`, `git diff --check` |
| New physical OBD/GPS/background/UI tests | NOT RUN | No connected physical transport |

Native build inputs: [SHA-256 manifest](evidence/obd-2026-09-23/native-source-sha256.txt).
Standalone unit/build results do not validate Bluetooth, actual PID rates, ECU timing,
readings on this Hyundai, iOS 27 scheduling, background collection or current installed UI.
Legacy RN package/build edits predating this work remain untouched and uncommitted.

## Review and remaining risk

A bounded read-only review returned no findings in the server/codec slice; the
reviewer was closed. That review did not run tests and excluded known C05 follow-ups.
Tests and build results above were obtained by the parent process.

C05 remains open: synchronous disk IO, disk-failure health reporting, source cadence
under faults, legacy input validation and repeated app lifespan initialization still
need separate reproduction/fixes. The new session naming prevents truncation; it
does not claim power-failure durability of flushed CSV. v2 SQLite ACK durability is
a separate existing path.

C19-C25 remain open: hardware discovery, SDK/signing, real native/bridge transport,
versioned OBD ingest, independent reported-success qualification and physical tests.
Keep the draft PR unmerged and version 0.1.0 unreleased until required gates pass.
