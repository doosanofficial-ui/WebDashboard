# Commercial Hardening v0.20.1 Checkpoint

Date: 2026-09-27

## Patch scope

- Strict Vector signal-rule flag validation and bounded driver-error backoff.
- Windows `start.ps1 -Vector` optional dependency installation using a pinned
  `requirements-vector.txt` hash.
- Release identity: v0.20.1, native build 12.

## Verification

| Area | Result | Evidence |
| --- | --- | --- |
| Server regression suite | PASS | 85 tests, 0 failures |
| Vector decoder/source | PASS | Intel/Motorola/signed/CAN-FD/fake-bus tests |
| Python compile | PASS | server source and CAN sources |
| Native app build | PASS | `/tmp/telemetry-ios-verify.KpZHxF`; `BUILD SUCCEEDED` |
| Platform docs | PASS | `scripts/validate_platform_docs.py` |

PowerShell syntax was not executed on macOS because `pwsh` is unavailable;
clean Windows execution remains a release gate.

## Hardware boundary

No VN1640A, Vector driver, CANoe channel, or vehicle signal was connected in
this run. The optional backend is fixture-verified, not hardware-certified.
