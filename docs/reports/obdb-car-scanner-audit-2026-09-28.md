# OBDb + Car Scanner Audit

Date: 2026-09-28
Repository baseline: `main` at `d6c68ac`
Target vehicle: Hyundai Santa Fe MX5 HEV

## Executive Result

OBDb is a strong source for **diagnostic request definitions and decoded
signals**, but it is not a raw CAN capture database and it is not proof that a
signal works on the user's vehicle. The current iPhone application can reuse
OBDb data after adding a separate OBD query layer; it must not replace the
existing raw-CAN and ELM327 monitoring boundaries.

Car Scanner was directly launched on the physical iPhone 17. The installed
bundle is `ovz.Car-Scanner`, version `2.1.46`. The app exposes a mature
profile-driven OBD UX, but the direct session remained disconnected because no
OBD adapter was connected. Therefore this audit has **UI/runtime evidence**,
not vehicle or adapter compatibility evidence.

## Coverage

### OBDb organization

Official repository inventory: [OBDb repositories](https://github.com/orgs/OBDb/repositories)

- 746 public repositories enumerated from the GitHub organization API.
- 746/746 shallow snapshots collected with zero clone failures.
- All repositories use `main` as the default branch in the inventory snapshot.
- 740 `signalsets/v3/*.json` files found; 736 repositories contain
  `signalsets/v3/default.json`.
- 29,091 commands and 49,809 signal entries counted in the 736 default
  signalsets.
- 49,396 distinct signal IDs counted; 413 duplicate occurrences remain across
  commands or repositories and must be namespaced when importing.
- 740/740 signalset JSON files passed the current OBDb JSON Schema.
- OBDb schema tests passed: 108 tests, 0 failures.
- 743 repositories contain GitHub workflow files; 737 contain both the
  `presubmits.yml` and `response_tests.yml` patterns.
- Repository metadata reports 738 `CC-BY-SA-4.0` repositories and one
  `Apache-2.0` repository; several tooling repositories do not expose an SPDX
  license in the API metadata and require per-repository license review.

This is an exhaustive structural, syntax, schema, workflow, and metadata audit
of the organization snapshot. It is not a manual line-by-line semantic review
of every one of the 49,809 signal definitions.

### Linked external repositories

The OBDb vehicle READMEs explicitly link to these functional sources, which
were also shallow-cloned and inspected:

- [JejuSoul/OBD-PIDs-for-HKMC-EVs](https://github.com/JejuSoul/OBD-PIDs-for-HKMC-EVs)
- [Esprit1st/Hyundai-Ioniq-5-Torque-Pro-PIDs](https://github.com/Esprit1st/Hyundai-Ioniq-5-Torque-Pro-PIDs)
- [ElectricSidecar/Hyundai-IONIQ-5](https://github.com/ElectricSidecar/Hyundai-IONIQ-5)
- [ElectricSidecar/Hyundai-IONIQ-6](https://github.com/ElectricSidecar/Hyundai-IONIQ-6)
- [ElectricSidecar/Kia-Niro-EV](https://github.com/ElectricSidecar/Kia-Niro-EV)
- [kallisti5/chevybolt](https://github.com/kallisti5/chevybolt)
- [iternio/autopi-link](https://github.com/iternio/autopi-link)

The first two Hyundai/Kia sources are relevant to the current vehicle/data
decision. The Chevrolet/AutoPi sources are retained as cross-vehicle adapter
and EV telemetry references, not as Santa Fe evidence.

## OBDb Architecture

Primary source: [OBDb organization README](https://github.com/OBDb)

OBDb organizes signalsets by vehicle make/model and stores versioned JSON under
`signalsets/v3/`. The authoritative schema is
[`OBDb/.schemas/signals.json`](https://github.com/OBDb/.schemas/blob/main/signals.json).

The relevant command model is:

| OBDb field | Meaning | Import implication |
| --- | --- | --- |
| `hdr` | Request CAN header | Query request ID, not a received raw-frame timestamp |
| `rax` | Response address/filter | Response routing and ECU matching |
| `cmd` | OBD/UDS service and payload, commonly `01`, `21`, or `22` | Requires a request/response query session |
| `proto` | ISO 15765-4 or ISO 9141/KWP protocol declaration | Transport/protocol selection |
| `fcm1` | Flow-control behavior | ISO-TP/ELM adapter option; must be tested on hardware |
| `freq` | Request interval in seconds | `0.25` means 4 requests/s; it is not a 10 Hz guarantee |
| `filter` | Actual model-year filter | Runtime profile selection |
| `dbgfilter` | Debug/test filter | Do not treat as authoritative vehicle support |
| `ecu` | Header/ECU type mapping | Query routing and UI grouping |

Signal format fields are close to the current native decoder model:

- `bix` and `len` map to bit start and bit length.
- `blsb` describes byte ordering and needs an explicit adapter test before it
  is mapped to `.intel` or `.motorola`.
- `sign` maps to signed decoding.
- `mul`, `div`, and `add` map to a physical-value transform. The importer can
  use `factor = mul / div` and `offset = add` when omitted values default to
  `1` and `0`, but this must be locked by regression fixtures.
- `min`, `max`, `nullmin`, and `nullmax` map to validity and range handling.
- `map` maps raw values to enumerations.
- `path`, `suggestedMetric`, `signalGroups`, and `synthetics` provide UI and
  derived-value organization.

The schema supports `signalGroups` and synthetic formulas, including grouped
battery module voltages. The current app's `SignalDefinition` already has the
core raw-CAN fields, but it lacks a query command model, response address,
OBD/UDS service, ISO-TP flow-control policy, and model-year profile selection.

## Santa Fe MX5 HEV Findings

### OBDb repositories

Relevant source snapshots:

- [OBDb/Hyundai-Santa-Fe](https://github.com/OBDb/Hyundai-Santa-Fe), commit
  `4f2e8ce6956a6eb149d0f7aa79d699b6a1f7961a`
- [OBDb/Hyundai-Santa-Fe-Hybrid](https://github.com/OBDb/Hyundai-Santa-Fe-Hybrid),
  commit `c14ff9dd8a87482604200a859d7d734234d98892`
- [OBDb/Hyundai](https://github.com/OBDb/Hyundai), commit
  `8d6f2845f8267a4382878e718627c21607e0566a`

`Hyundai-Santa-Fe` contains 82 commands and 424 signals. It includes wheel
speeds, vehicle speed, battery state, battery voltage, engine RPM, coolant,
torque, transmission, tires, doors, and other signals. It uses multiple
request/response addresses including `7D1/7D9`, `7D4/7DC`, `7E0/7E8`, and
`7E1/7E9`.

`Hyundai-Santa-Fe-Hybrid` contains 8 commands and 86 signals:

| Request/response | Command | Data relevant to the project |
| --- | --- | --- |
| `7A0/7A8` | `22 C00B` | Four tire pressures, 15-second request interval |
| `7E2/7EA` | `22 E004` | 12 V battery charge |
| `7E4/7EC` | `22 0101` | HV battery SOC, charge-port state, charging state |
| `7E4/7EC` | `22 0102` | HV battery modules 001-032 voltage |
| `7E4/7EC` | `22 0103` | HV battery modules 033-064 voltage |
| `7E4/7EC` | `22 0104` | HV battery modules 065-072 voltage |
| `7E4/7EC` | `22 0105` | HV battery SOC display value |
| `7E7/7EF` | `22 C101` | Four wheel speeds, 0.25-second request interval |

The Hybrid repository's `generations.yaml` describes the fifth-generation
hybrid as starting in 2023. The command definitions currently use
`dbgfilter`, including a `from: 2026` branch and a `years: [2022]` exception.
The OBDb tooling documents `dbgfilter` as a debug filter, and the aggregation
processor removes both `filter` and `dbgfilter` when producing a merged output.
This means the data is a strong candidate source for a 2026 MX5 HEV query
profile, but it is not a physical compatibility proof for the user's vehicle.

### Direct Car Scanner evidence

The physical device evidence was collected with Xcode 27/XCUITest on iPhone 17
(iOS 27.0 build 24A437):

- Bundle: `ovz.Car-Scanner`
- Version: `2.1.46`
- UI test result bundles: `/tmp/car-scanner-ui.xcresult`,
  `/tmp/car-scanner-mycar-text.xcresult`,
  `/tmp/car-scanner-picker.xcresult`, and
  `/tmp/car-scanner-features.xcresult`
- Accessibility inventory confirmed the home menu labels and connection
  status.
- Home showed `ELM 연결: 연결 끊김` and `엔진 제어 장치(ECU) 연결: 연결 끊김`.
- The app exposed `연결` and `데모` controls without an adapter.
- `내 차량` opened a current profile named `My car (#8DF1CF20E26FB24)` with
  year `2026`; the row was selected and the screen exposed `적용`.
- `통계` opened a seven-day distance/average-consumption chart with no data.
- `데이터 기록` showed recording enabled, location recording disabled, value
  rounding disabled, and an import action.
- In the disconnected state, `실시간 데이터`, `모든 센서`, `고장 코드(DTC)`,
  `프리즈 프레임`, and `비연속 모니터` returned to the home menu rather than
  showing live data. This is observed behavior in this session, not a claim
  about every app state.

The user-provided screenshots show the Hyundai profile list containing:
`Santa Fe MX5 2.5 GDI (2024-current)` and `Santa Fe MX5 HEV (2024-current)`.
That screenshot is evidence of the installed app's profile catalog, not proof
that the profile has successfully read this vehicle.

Evidence files:

- `evidence/car-scanner-home-20260928.png`
- `evidence/car-scanner-mycar-20260928.png`
- `evidence/car-scanner-statistics-20260928.png`
- `evidence/car-scanner-data-recording-20260928.png`
- `evidence/car-scanner-user-hyundai-1.jpg` through
  `evidence/car-scanner-user-hyundai-4.jpg`

The official [Car Scanner App Store listing](https://apps.apple.com/us/app/car-scanner-elm-obd2/id1259933623)
reports version 2.1.46, iOS/iPadOS support, Wi-Fi or Bluetooth 4.0 BLE ELM327
adapters, custom extended PIDs, DTC/freeze-frame/Mode 06/readiness features,
all-sensor view, and Hyundai/Kia connection profiles. It also warns that
low-quality ELM327 clones can cause connection failures and lag. The official
[Car Scanner site](https://www.carscanner.info/) describes the product as an
iOS/Android OBD2 diagnostic and trip-computer application.

## External Provenance Findings

[JejuSoul/OBD-PIDs-for-HKMC-EVs](https://github.com/JejuSoul/OBD-PIDs-for-HKMC-EVs)
is an older, community-maintained Torque/Engine Link PID collection. Its README
states that the strongest support is for the author's Kia Soul EV and that the
iOS Engine Link + BLE path was not tested in that repository. It is useful as
historical provenance, not as current iPhone compatibility evidence.

[Esprit1st/Hyundai-Ioniq-5-Torque-Pro-PIDs](https://github.com/Esprit1st/Hyundai-Ioniq-5-Torque-Pro-PIDs)
contains CSV PID files for Torque Pro and claims use for real-time vehicle data
and ABRP forwarding. It is a PID export reference, not an iOS BLE transport or
raw CAN implementation.

[Iternio AutoPi link](https://github.com/iternio/autopi-link) documents an
AutoPi/ABRP Python path with approximately five-second cycles and fields such
as SOC, SOH, battery voltage/current, charging state, GPS, and speed. This
supports a slower telemetry/route-planning architecture, not the project's
10 Hz raw-CAN display target.

## Comparison With Current Project

### What can be reused

1. Import OBDb `hdr`/`rax`/`cmd`/`freq`/`fcm1` into a dedicated
   `OBDbQueryDefinition` model.
2. Convert OBDb `fmt` into the existing signal decoder after adding explicit
   `mul/div/add`, null-range, enum, and `blsb` fixtures.
3. Use `suggestedMetric` values to seed dashboard bindings such as `speed`,
   `engineSpeed`, `stateOfCharge`, `tractionBatteryVoltage`, and tire pressure.
4. Use `signalGroups` for the 72-module HV battery view rather than creating 72
   unrelated dashboard cards.
5. Use the OBDb Explorer/MCP patterns for a future profile browser and signal
   search UI. See [OBDb/obdb.community](https://github.com/OBDb/obdb.community)
   and [OBDb/vscode-obdb](https://github.com/OBDb/vscode-obdb).

### What cannot be reused directly

1. OBDb command definitions are request/response diagnostics, not raw CAN bus
   frames. They do not provide bus-transmit timestamps or a raw frame stream.
2. The current native `ELM327Session` is intentionally a raw `AT MA` monitor
   path and the current OBD decoder is headerless Mode 01. It does not yet
   implement OBDb's Mode 21/22 query scheduling, ECU response filtering, or
   ISO-TP multi-frame/flow-control query path.
3. A valid schema file is not a vehicle proof. All 740 files passing JSON
   Schema means syntactic/structural validity, not that a command responds on
   the user's 2026 Santa Fe MX5 HEV.
4. A Car Scanner profile match is not evidence that the user's ELM327-BT4N
   adapter exposes the required BLE GATT service or that the vehicle answers
   every extended command.

## Recommended Implementation Order

### P0: Preserve the raw-CAN path

Keep the current `ELM327Session -> CANFrame -> SignalDecoder` monitoring path
unchanged for the real-vehicle gate. Do not replace it with OBDb polling.

### P1: Add an OBDb importer, not a direct dependency

Create a versioned import layer with these types:

```text
OBDbSignalset
OBDbCommand
OBDbQueryDefinition
OBDbSignalDefinition
```

The importer should retain source repository, source commit, model-year filter,
request ID, response ID, service, payload, protocol, flow-control flag, poll
period, and original raw `fmt` fields. The generated runtime definition should
be auditable back to the source JSON.

### P1: Add a separate query session

Add a read-only `ELM327QuerySession` for Service 01/21/22. Do not run
`AT MA` monitoring and repeated request/response polling over the same session
without an explicit scheduler and state transition. Record query failures,
`NODATA`, `BUFFER FULL`, unsupported commands, response address mismatches, and
ISO-TP reassembly errors separately from raw-CAN frame drops.

### P1: Seed the MX5 HEV profile

Start with a small fixture from `Hyundai-Santa-Fe-Hybrid`:

- `SANTAFEHYB_HVBAT_SOC`
- `SANTAFEHYB_HVBAT_CHARGING`
- `SANTAFEHYB_VPWR`
- `SANTAFEHYB_TIRE_FL_SPD` through `SANTAFEHYB_TIRE_RR_SPD`
- one or two HV module voltage signals

Do not import all 72 module values into the first dashboard. Bind SOC,
charging state, 12 V charge, four wheel speeds, and one battery-module summary
to Numeric/Bar/LED widgets. Add a hardware-captured golden response before
marking any signal `VALID`.

### P2: Add provenance and support UX

Show the source repository/commit, command, response address, model-year filter,
and last successful response in the app. This is necessary because the Car
Scanner catalog and OBDb catalog are profile references, not runtime proof.

## Final Compatibility Decision

| Claim | Result |
| --- | --- |
| OBDb contains useful Santa Fe/Hyundai signal definitions | PASS |
| OBDb contains candidate MX5 HEV HV battery and wheel-speed signals | PASS |
| OBDb proves the user's physical vehicle supports those commands | NOT TESTED |
| Car Scanner iOS app is installed and directly explored | PASS |
| Car Scanner connected to the user's ELM327-BT4N in this session | BLOCKED: adapter not connected |
| Current native app can consume OBDb JSON directly | FAIL: query-session adapter required |
| OBDb replaces raw CAN monitoring | FAIL: different data plane |
| Production physical E2E is complete | BLOCKED: real adapter and vehicle capture required |

No production code was changed by this audit. The report and evidence files
are research artifacts only.
