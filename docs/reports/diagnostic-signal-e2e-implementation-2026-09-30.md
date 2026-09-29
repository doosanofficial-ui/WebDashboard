# Diagnostic Signal E2E Implementation Checkpoint

Date: 2026-09-30
Main commit: `a8e515a048d98cc3fe83754dff743bc9b40e1407`
App version/build: `0.22.1 (17)`
Scope: iPhone 17 / iOS 27 / native SwiftUI / read-only ELM327 diagnostics

## Software Gate

`PASS`

- Core test suite: `109` tests, `0` failures.
- iOS 27 Simulator app build: `BUILD SUCCEEDED`.
- Platform documentation validation: passed.
- Fresh verification artifact: `/tmp/telemetry-ios-verify.P3snWl`.

Implemented path:

```text
OBDQueryDefinition
  -> OBDQuerySession / OBDQueryScheduler
  -> ELM response parser
  -> ISO-TP reassembly
  -> OBD signal decoder
  -> TelemetryStore(source=diagnostic)
  -> TelemetryModel diagnostic snapshot
  -> MeasurementRecorder(DIAGNOSTIC_RESPONSE, DIAGNOSTIC_SIGNAL)
  -> CSV / JSON export
  -> MeasurementReplay
```

The Santa Fe Hybrid HV SOC query is pinned to:

- Source: `OBDb/Hyundai-Santa-Fe-Hybrid`
- Commit: `c14ff9dd8a87482604200a859d7d734234d98892`
- Request: `0x7E4 -> 0x7EC`, Service `22`, DID `0101`, flow control enabled
- Signal: `SANTAFEHYB_HVBAT_SOC`, `bix 32`, length `8`, divisor `2`, unit `percent`

The compact OBDb golden response independently decodes to `50.5`. This is a
software/fixture result, not a physical Santa Fe result.

## Physical Device Gate

| Gate | Result | Evidence |
| --- | --- | --- |
| Xcode 27 / iOS 27 SDK | `PASS` | Xcode 27.0 / build 27A266a |
| iPhone 17 build | `PASS` | device destination `00008150-000E39C43CDB401C` |
| iPhone 17 install | `PASS` | `devicectl` installed `local.webdashboard.Telemetry` |
| iPhone 17 launch | `PASS` | `devicectl` foreground launch |
| Physical launch UI | `PASS` | `docs/reports/evidence/telemetry-ios27-physical-v0.22.1-launch.png` |
| Physical BLE scan path | `PASS` | `TelemetryUITests/testPhysicalBLEObservationCapture()` on iPhone 17 |
| BT4N GATT profile | `BLOCKED` | 50 peripherals observed; NANICAR/ELM327/OBD name matches: 0 |
| Santa Fe MX5 HEV response | `BLOCKED` | Physical adapter + stationary vehicle evidence required |
| Diagnostic physical E2E | `BLOCKED` | Must prove real BT4N -> iPhone -> HV SOC response |

The captured launch screen is evidence of this build being installed and
running on the physical iPhone. It is not evidence of vehicle connectivity.

The physical BLE scan evidence is split into a masked result and a screenshot:

- Result: `docs/reports/evidence/telemetry-ios27-ble-scan-2026-09-30.json`
- UI evidence: `docs/reports/evidence/telemetry-ios27-ble-scan-no-bt4n.png`

The scan path and pasteboard export passed, but the adapter was not advertising
during the capture. No UUID or compatibility claim is made.

## Separate Gates

- `SOFTWARE`: `PASS`
- `PHYSICAL DIAGNOSTIC E2E`: `BLOCKED: PHYSICAL HARDWARE EVIDENCE REQUIRED`
- `RAW CAN`: `NOT TESTED` in this implementation checkpoint
- `CARPLAY`: `NOT TESTED` for entitlement/head-unit runtime
- iPad/Android: `OUT OF SCOPE`

## Next Human Action

1. Power the NANICAR BT4N from the vehicle OBD-II port with the vehicle awake;
   keep it near the iPhone and run BLE discovery again. Record the
   actual peripheral/service/characteristic UUIDs and notify/write properties.
2. Create/import an AdapterProfile schema 2 using those observed UUIDs and the
   included Santa Fe diagnostic query catalog; do not guess UUIDs.
3. With the Santa Fe MX5 HEV stationary, capture one real `22 01 01` response,
   then compare the decoded SOC against an independent Car Scanner reading.

Until those results are recorded, do not promote the physical diagnostic gate
to `PASS`.
