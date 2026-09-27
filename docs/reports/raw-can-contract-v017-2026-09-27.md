# Raw CAN/CAN-FD Contract v0.17 Checkpoint

Date: 2026-09-27

## Scope

This checkpoint keeps the A+B+C operator UI from v0.16 and adds the transport
contract needed for a future Vector/CANoe/CANape bridge:

- decoded v1 `sig` remains backward compatible;
- an optional `raw` object carries Classical CAN or CAN-FD metadata and bytes;
- the iOS Signals screen renders a server-provided raw frame without replacing
  the configured signal catalog;
- CAN CSV stores the raw object as a JSON cell.

This is not a VN1640A live integration, a CANoe CAPL bridge, or proof that the
NANICAR BT4N exposes raw CAN. Hardware and vendor-tool execution remain separate
gates.

## Contract decisions

- Classical CAN uses 11-bit or 29-bit arbitration identifiers and DLC 0..8.
- CAN-FD DLC 9..15 maps to payload lengths 12/16/20/24/32/48/64.
- `brs` and `esi` are rejected for Classical CAN.
- `data_length` must match the payload; no string-to-number or string-to-boolean
  coercion is performed at the boundary.
- `t` is the source timestamp carried by the adapter; it is not asserted to be a
  bus transmission timestamp.
- `python-can` is not a core dependency. `CANRawFrame.from_python_can()` is an
  optional conversion seam for a future Vector backend.

## Changed surfaces

- `server/can_source/frame.py`: validated raw frame model and CAN-FD DLC mapping.
- `server/can_source/base.py`: optional raw-frame and close hooks.
- `server/app.py`: optional `raw` WS field and safe adapter cleanup.
- `server/logger.py`: raw JSON CSV column.
- `mobile-ios/TelemetryCore/Sources/TelemetryCore/ServerCANFrame.swift`: matching
  Codable model and fail-closed validation.
- `mobile-ios/App/TelemetryModel.swift`: server raw frame presentation in Signals.
- `server/can_source/adapters.md`: CANoe/Vector bridge envelope and verification checklist.

## Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Server raw contract | PASS | 5 focused tests; full server suite 70 tests, 0 failures |
| iOS raw contract | PASS | TelemetryCore 87 tests, 0 failures |
| Native app build | PASS | `./mobile-ios/scripts/verify.sh build`; `/tmp/telemetry-ios-verify.04DuJo` |
| Python compile | PASS | `server/.venv/bin/python -m py_compile app.py can_source/*.py logger.py` |
| Web smoke | PASS | GPS 28 tests and service worker 8 tests |
| Platform docs | PASS | `scripts/validate_platform_docs.py` |

## Open gates

- Implement and test one real CANoe UDP/TCP receiver or Vector `python-can`
  backend on Windows with VN1640A.
- Capture the actual channel, timestamp semantics, Classical/CAN-FD mode,
  bitrate/BRS configuration, and seven signal mappings.
- Rebuild/install v0.17 on the unlocked iPhone 17; current device launch
  evidence is blocked by the phone lock state and current host has no Xcode 27
  / iOS 27 SDK.
