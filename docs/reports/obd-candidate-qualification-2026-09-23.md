# iOS OBD Candidate Qualification - 2026-09-23

Outcome: **both candidates rejected for unmodified production adoption** at the
commits below. This is an actual offline compile/test result, not another star-count
assessment. No physical scanner/vehicle access or paid third-party service was used.

## Fixed inputs

| Candidate | Upstream commit | Branch sampled | License |
|---|---|---|---|
| SwiftOBD2 | `fe6def4e8599671dfc1b9597dbcdbc6a7c078b96` | main | MIT |
| LTSupportAutomotive | `909c42a803e74d7e941add4ba31201948a117259` | SPM | MIT |

Source references: [SwiftOBD2](https://github.com/kkonteh97/SwiftOBD2/tree/fe6def4e8599671dfc1b9597dbcdbc6a7c078b96),
[LT SPM](https://github.com/mickeyl/LTSupportAutomotive/tree/909c42a803e74d7e941add4ba31201948a117259).
Environment: macOS 26.6.2, Xcode 26.3, iOS Simulator SDK 26.2.
The user's iOS 27 iPhone remains unavailable in device discovery. No iOS 27 pass implied.

## Executed results

| Phase | Result | Meaning |
|---|---|---|
| SwiftOBD2 original XCTest | 26 PASS | Upstream test suite, not our transport/reliability gate |
| LT SPM macOS build | PASS with warnings | No upstream test target in this package |
| SwiftOBD2 deadline acceptance | 1 FAIL | Missing reply does not complete caller at configured timeout |
| LT parsing acceptance | 2 FAIL | PID06 payload offset and strict padding boundary mismatch |
| Both packages in temporary iOS Simulator app | BUILD SUCCEEDED | Compile/link only; no UI or radio session |

All phases are reproduced by `scripts/obd_eval/evaluate.sh`; it returns 1 for the
observed acceptance failures. Original upstream production sources were not patched.
Artifacts: `/tmp/telemetry-obd-eval.4D3tT1/`.
Raw phase results are retained in `exit-codes.tsv`, `swift-acceptance.log`,
`lt-acceptance.log`, `ios-simulator-compile.log` and `archives-sha256.txt` there.
Portable phase/commit/hash receipts: [evidence directory](evidence/obd-candidates-2026-09-23/).
Initial independent-run evidence remains at `/tmp/telemetry-obd-eval.Kgob8Q/`,
with its logs also copied under `initial-probe/` in the final artifact directory.
These are upstream evaluation snapshots, not editable project worktrees.

## Findings that change implementation decisions

### P1: SwiftOBD2 response timeout can leave the caller pending

`BLEMessageProcessor.waitForResponse(timeout: 0.02)` with no reply fails to finish
within a 0.5-second acceptance window. Calling its reset afterward releases the
pending continuation and permits test cleanup. This was reproduced in two isolated runs.

The [processor](https://github.com/kkonteh97/SwiftOBD2/blob/fe6def4e8599671dfc1b9597dbcdbc6a7c078b96/Sources/SwiftOBD2/Communication/BLE/BLEDataProcessor.swift)
waits on a checked continuation inside a throwing task group. The timeout path
does not complete that continuation. Cancellation alone cannot terminate the pending
child, so the scope waits instead of delivering its error promptly.
Our acceptance test exercises this real class without a Bluetooth manager.

Consequence: a disconnected scanner can stall a request/recorder. Do not adopt the
default sender, or equate passing decoder tests with bounded timeout behavior.
The existing upstream `testSetupVehicle` also fulfills its expectation on catch,
so its pass alone does not establish successful setup.

### P1: LT Mode 01 PID06 is confused with Mode 06

The real 11-bit CAN decoder given request `0106` and fixture `7E8 03 41 06 7C`
returns payload `[6,124]`, not `[124]`. The extra byte is the requested PID, not
sensor data. Its Mode 06 workaround indexes the wrong field for this single frame.
This reproduces the concern in [upstream issue 48](https://github.com/mickeyl/LTSupportAutomotive/issues/48)
at the evaluated SPM commit, rather than assuming the issue applies from its title.

### Boundary mismatch: LT includes CAN padding in decoded payload

For `010C`, fixture `7E8 04 41 0C 1A F8 00 00 00` returns `[26,248,0,0,0]`
instead of the two measurement bytes `[26,248]`. The decoder does not limit payload
to the single-frame length. This fails our strict payload contract; it does not prove
every upstream high-level RPM decoder is incorrect, since some may ignore extra bytes.
The integration boundary must enforce frame length, source ECU and expected PID.

### Device-selection and background gaps (source review, not radio tests)

The LT transport's discovery callback attempts to connect discovered peripherals,
and later selects the first qualifying service. Its initializer supplies no central
restoration options. SwiftOBD2's default path also selects the first found peripheral
and recognizes a fixed set of service/characteristic IDs. These default behaviors
do not meet our explicit operator-selected BT4N profile and background restoration
requirements. They must not be enabled blindly on nearby devices.

## Decision and next work

Keep both libraries as comparison/reference candidates, not current runtime dependencies.
A scoped MIT-preserving fork could be reconsidered only after fixing these gates and
testing the selected real device/profile. Do not copy a whole diagnostics surface
that includes DTC clearing or arbitrary commands into a read-only product.

The small existing TelemetryCore codec remains an acceptance boundary, not a full
replacement scanner SDK or evidence of BT4N compatibility. Transport selection remains
explicitly unresolved until its GATT evidence is available. Server recording and
device-independent reliability work can continue without weakening that requirement.

C25 is **partially investigated, not complete**: public usage evidence, exact hardware
support, iOS 27 build/install and background behavior remain required. C19-C24 remain
open. No version increment, deployment, App Store action or new dependency was caused
by this evaluation.
