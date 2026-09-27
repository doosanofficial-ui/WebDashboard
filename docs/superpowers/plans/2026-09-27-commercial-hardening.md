# Commercial Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the current unreleased iOS 27 telemetry product toward a defensible internal-release candidate without claiming hardware, iOS 27 SDK, background, or CarPlay gates that have not been observed.

**Architecture:** Preserve the native SwiftUI/Core Location app as the primary iOS runtime, the FastAPI server as the Windows bridge, and the existing v1/v2 contracts. Add production seams at the server source, error, release-identity, and test boundaries instead of coupling the UI directly to Vector, CANoe, or ELM327 behavior.

**Tech Stack:** Swift 5 / SwiftUI / Core Location / Core Bluetooth / URLSession, Python 3.11+ / FastAPI / uvicorn, optional `python-can` on Windows, Vanilla JS client, XcodeGen, XCTest, unittest, Node test runner.

**Spec:** `docs/PRD.md`, `docs/production-plan.md`, `docs/adr/0004-obd-bt4n-integration.md`, `docs/reports/raw-can-contract-v017-2026-09-27.md`.

## Global Constraints

- Do not modify, stage, or revert the user's uncommitted `mobile/` work.
- Do not add CAN transmission, ECU programming, DTC clearing, or other vehicle-control behavior.
- Treat the iPhone 17/iOS 27 device, Xcode 27/iOS 27 SDK, VN1640A, BT4N, Santa Fe MX5 HEV, and CarPlay entitlement as external evidence gates.
- Keep Classical CAN and CAN-FD raw metadata lossless; reject invalid DLC/payload/flags rather than coercing values.
- Keep GPS measurement time, receive time, stale state, and background state distinct.
- Never expose bearer credentials, client secrets, raw upstream error bodies, or filesystem paths through API/UI responses.
- Every functional change gets a focused regression test and fresh full-suite/build evidence before commit.

## Review Focus

- A test must pass from both `server/` and repository root without import-path accidents.
- A malformed CANoe/Vector datagram must not publish an empty healthy frame or reset source freshness.
- Naver/HTTP upstream failures must expose a stable safe code, not credentials or upstream response text.
- A version/build shown by server metadata, native bundle, reports, and release receipt must identify the same source revision.
- An iOS background upload failure must leave the durable outbox item retryable and visible; a simulator build is not a background pass.

---

### Task 1: Baseline and Release Identity

**Files:**
- Create: `release.json`
- Create: `server/release.py`
- Modify: `server/app.py`
- Modify: `server/tests/test_can_frame_contract.py`
- Create: `server/tests/test_release_identity.py`
- Modify: `docs/production-plan.md`

**Interfaces:**
- Produces `load_release_metadata() -> ReleaseMetadata` and `/api/public-config.release`.
- The server version must be `0.18.0`, the native marketing version must remain `0.18.0`, and the current native build is `9`.

- [x] Add the root release metadata and tests for schema, version, build, and commit-safe public projection.
- [x] Make the server FastAPI version and public config use the metadata without exposing secrets.
- [x] Fix the raw CAN test import path so the same test command is valid from repository root and `server/`.
- [x] Run root and server working-directory test commands and update the plan evidence.

### Task 2: Safe Upstream and API Error Boundary

**Files:**
- Modify: `server/app.py`
- Modify: `server/tests/test_app_runtime.py`
- Create or modify: `server/tests/test_security.py`

**Interfaces:**
- Naver failure responses remain JSON with stable `error.code`/`detail` values; upstream body text, URLs containing credentials, and exception paths do not cross the API boundary.

- [x] Add failing assertions for 401/403/429/5xx/exception responses and secret redaction.
- [x] Implement safe internal logging plus bounded public error codes.
- [x] Run the focused tests, then the full server suite.

### Task 3: CANoe/MATLAB UDP Source Adapter

**Files:**
- Create: `server/can_source/udp_json.py`
- Modify: `server/can_source/base.py`
- Modify: `server/can_source/__init__.py`
- Modify: `server/config.py`
- Modify: `server/app.py`
- Create: `server/tests/test_udp_json_source.py`
- Modify: `server/can_source/adapters.md`
- Modify: `server/README.md`

**Interfaces:**
- `UDPJsonCANSource(bind_host: str, port: int, stale_after: float) -> CANSource`.
- `next_frame() -> dict[str, float]` returns the latest decoded `sig` snapshot only after a valid datagram.
- `next_raw_frame() -> CANRawFrame | None` returns the validated optional raw frame from the same datagram.
- Invalid datagrams increment a bounded diagnostic counter and never become healthy frames.

- [x] Write tests for valid Classical CAN, valid CAN-FD, malformed JSON, invalid signal values, stale source, and close/reuse.
- [x] Implement a bounded background UDP receiver that keeps the latest complete sample and never blocks the 10 Hz publisher.
- [x] Add `CAN_SOURCE=udp_json`, `CAN_UDP_HOST`, `CAN_UDP_PORT`, and `CAN_SOURCE_STALE_AFTER` configuration and factory wiring.
- [x] Make `/api/ping` distinguish server-up/source-not-ready/source-stale without publishing fake zeros.
- [x] Document the CANoe/MATLAB envelope and Windows firewall scope.

### Task 4: Native Runtime Reliability and Release QA

**Files:**
- Modify: `mobile-ios/App/TelemetryModel.swift`
- Modify: `mobile-ios/App/LocationService.swift`
- Modify: `mobile-ios/App/BackgroundUploader.swift`
- Create/modify: `mobile-ios/TelemetryCore/Tests/TelemetryCoreTests/*`
- Modify: `mobile-ios/README.md`
- Create: `docs/reports/commercial-hardening-v017-2026-09-27.md`

**Interfaces:**
- Keep server WS acquisition, local recording, GPS acquisition, and durable v2 upload as separate state machines.
- All unrecoverable storage/permission/transport failures must be visible as stable user-facing states and system events.

- [x] Add tests for outbox retry after non-2xx/transport failure, background callback completion, GPS denial/stale transitions, and adapter disconnect/reconnect.
- [x] Replace silent critical `try?` paths at the user-visible storage/network seams with stable error state updates while preserving redaction.
- [ ] Verify SwiftUI invalidation boundaries and accessibility identifiers for Live, Signals, Sessions, Setup, and CarPlay status.
- [ ] Run Core tests, app build, simulator visual/AX smoke, and device verifier if a connected unlocked device and matching SDK exist.

### Task 5: External Release Gates

**Files:**
- Update only evidence/checklist files after actual observation: `docs/production-plan.md`, `docs/e2e-platform-checklist.md`, `docs/reports/*`.

- [ ] Install/verify Xcode 27 with iOS 27 SDK and rebuild the exact source revision.
- [ ] Unlock/connect iPhone 17 and run install, launch, GPS permission, MARK, recording, network-loss, and 30-minute screen-lock tests.
- [ ] Observe BT4N GATT/framing and validate one real Santa Fe MX5 HEV signal; do not infer compatibility from packaging or stars.
- [ ] Run Windows VN1640A/CANoe UDP or Vector backend with real timestamps, CAN/CAN-FD mode, and seven-signal comparison.
- [ ] Obtain an applicable CarPlay entitlement or document the entitlement/category rejection; only then run CarPlay simulator/device projection acceptance.
- [ ] Publish an internal signed package only after version, commit, artifact hash, runtime, install, and test evidence reconcile.
