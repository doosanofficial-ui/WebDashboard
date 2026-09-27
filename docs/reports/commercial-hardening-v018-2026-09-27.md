# Commercial Hardening v0.18 Checkpoint

Date: 2026-09-27

## Current diagnosis

The repository is a strong internal-development baseline, not yet a commercial
release. The native iOS path is the source of truth; the React Native `mobile/`
directory contains user-owned uncommitted work and was not modified or staged.

## Implemented in this checkpoint

- Added `release.json` and server public release identity. The server FastAPI
  version, native bundle spec, and reports now target v0.18.0 build 9.
- Made raw CAN tests runnable from both repository root and `server/`.
- Removed Naver reverse-geocode upstream body/exception reflection from public
  errors. Stable auth, rate-limit, and unavailable codes are returned instead.
- Added `UDPJsonCANSource` for CANoe/MATLAB decoded signal bridges with strict
  JSON/raw-frame validation, bounded invalid counters, readiness, stale state,
  and clean shutdown.
- `/api/ping` now distinguishes `source_not_ready` and `source_stale` from a
  generic server/recording failure.
- Added iOS v2 event metadata for `source`, `app_ver`, and `device`, while old
  outbox events without those keys remain decodable.
- Prevented queue-storage read errors from being represented as a false zero
  pending count in the native UI.

## Fresh verification

| Area | Result | Evidence |
| --- | --- | --- |
| Server regression suite | PASS | 79 tests, 0 failures |
| Server compile | PASS | `server/.venv/bin/python -m py_compile server/*.py server/can_source/*.py` |
| Native Core suite | PASS | 89 tests, 0 failures |
| Native app build | PASS | `/tmp/telemetry-ios-verify.MHCXZs`; `BUILD SUCCEEDED` |
| Native Signals visual/AX smoke | PASS | iPhone 17 simulator current build; `docs/reports/evidence/swiftui-signals-v018-2026-09-27.png` (SHA-256 `40636e1545d4f9898f5d6ff4985ee1023d121d7415d161d9ffb5901002a9a191`); AX exposes acquisition health, filter, stale toggle, raw CAN, developer disclosure |
| Native Live visual/AX smoke | PASS | iPhone 17 simulator current build; AX exposes live status, MARK/REC/GPS, stale indicators, profile control |
| Web GPS/service worker | PASS | 28 + 8 tests |
| Platform docs | PASS | `scripts/validate_platform_docs.py` |
| Xcode/iOS SDK | UNVERIFIED for target | Xcode 26.3, iOS 26.2 SDK only; no iOS 27 SDK present |
| Physical iPhone 17 | NOT RUN | Current `devicectl` device inventory has no connected device |

## Remaining release blockers

- Xcode 27/iOS 27 SDK build and unlocked iPhone 17 install/runtime evidence.
- 30-minute locked-screen GPS/outbox/network-loss measurement with original and
  server timestamps reconciled.
- Observed NANICAR BT4N GATT/framing and one real Santa Fe MX5 HEV signal.
- Windows VN1640A/CANoe execution with actual seven-signal comparison. The UDP
  adapter is implemented and fixture-tested, but no physical bridge result is
  claimed.
- Apple CarPlay entitlement/category approval and simulator/device projection
  acceptance. Current CarPlay code remains status-only and entitlement-gated.
- Windows clean-machine installation, firewall, upgrade/rollback, dependency
  and retention-policy evidence.
