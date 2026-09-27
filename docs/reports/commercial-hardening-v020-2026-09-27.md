# Commercial Hardening v0.20 Checkpoint

Date: 2026-09-27

## Functional change

The Windows server now has an optional direct Vector backend for VN1600/VN1640A
class hardware through `python-can`:

- default MVP installation remains dependency-free (`dummy` and UDP bridge);
- `requirements-vector.txt` keeps `python-can` optional;
- `CAN_SOURCE=vector` opens the configured Vector channel lazily;
- Classical CAN and CAN-FD raw frames preserve DLC, payload, BRS, ESI, channel,
  and source timestamp;
- configurable signal rules decode CAN ID, 11/29-bit mode, Intel/Motorola
  bit order, signed values, and then use the existing scale/offset/clamp mapper;
- fake-bus tests verify the source without pretending to have a VN1640A attached.

## Verification

| Area | Result | Evidence |
| --- | --- | --- |
| Server regression suite | PASS | 84 tests, 0 failures |
| Vector signal decoder | PASS | Intel, Motorola, signed, CAN-FD and short-frame tests |
| Vector source | PASS | Injected fake `python-can`-shaped bus test |
| Python compile/docs | PASS | compile and platform-doc validation |
| Native app build | PASS | `/tmp/telemetry-ios-verify.ghikm0`; `BUILD SUCCEEDED` |
| Release identity | v0.20.0 build 11 | `release.json`, `mobile-ios/project.yml` |

## Hardware gate still open

The backend is implementation- and fixture-verified only. Windows must still
install Vector's driver, `python-can`, and the correct CANoe/CANape application
channel, then compare actual VN1640A timestamps, bitrate/CAN-FD mode, and the
seven configured signals against the source tool. No live vehicle or transmission
feature is claimed.
