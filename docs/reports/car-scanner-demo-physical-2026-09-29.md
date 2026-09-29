# Car Scanner Physical Demo Follow-up

Date: 2026-09-29
Device: iPhone 17 / iOS 27.0
App bundle: `ovz.Car-Scanner`
App version: `2.1.46`

## Evidence Separation

This follow-up separates two evidence sources:

- **User-provided real-vehicle evidence:** the attached screenshots show the
  Car Scanner Pro screen with `ELM 연결됨`, `ECU 연결됨`, `OBD2 프로토콜: Auto`,
  a VIN, ECU name, and calibration ID.
- **Direct device exploration:** this session selected `Demo -> 마지막으로
  사용한 차량` on the installed app and captured the resulting synthetic
  dashboard.

The demo result is not a real vehicle or adapter PASS. It is a UI and signal
mapping fixture only.

## Direct Exploration

The physical iPhone UI automation test passed:

- Demo selector displayed `모든 센서`, `마지막으로 사용한 차량`, and `취소`.
- Selecting `마지막으로 사용한 차량` changed the title to `Car Scanner Pro`.
- The demo state displayed:
  - OBD2 protocol: `Auto`
  - VIN: `WP0ZZZ99ZTS392124`
  - ECU name: `Random engine ECU`
  - Calibration ID: `1234567890A`
  - ELM connection: `연결됨`
  - ECU connection: `연결됨`
- The synthetic dashboard displayed:
  - Engine RPM: `4314 rpm`
  - Engine coolant temperature: `102 °C`
  - Speed: `13 km/h`

The VIN prefix and `Random engine ECU` identify this as demo data, not the
user's Hyundai Santa Fe MX5 HEV.

Test result: `/tmp/car-scanner-demo.xcresult`

## Screenshots

- `evidence/car-scanner-demo-home-20260929.png`
- `evidence/car-scanner-demo-dashboard-20260929.png`
- User-provided real-vehicle screenshots:
  - `evidence/car-scanner-user-hyundai-1.jpg`
  - `evidence/car-scanner-user-hyundai-2.jpg`
  - `evidence/car-scanner-user-hyundai-3.jpg`

## Mapping To This Project

The demo screen gives a safe fixture for three initial dashboard bindings:

| Car Scanner label | Internal fixture signal | Unit | Dashboard use |
| --- | --- | --- | --- |
| Engine RPM | `demo.engine_rpm` | `rpm` | Numeric/circular gauge |
| Engine coolant temperature | `demo.engine_coolant_temperature` | `celsius` | Numeric/bar/critical threshold |
| Speed | `demo.vehicle_speed` | `kilometersPerHour` | Numeric/gauge/time series |

These are not raw CAN identifiers. The fixture must be marked with
`source = demo` and must never satisfy the real vehicle E2E acceptance gate.

For the user's target vehicle, the OBDb Hybrid candidate signals remain:

- `SANTAFEHYB_HVBAT_SOC`
- `SANTAFEHYB_HVBAT_CHARGING`
- `SANTAFEHYB_VPWR`
- `SANTAFEHYB_TIRE_FL_SPD` through `SANTAFEHYB_TIRE_RR_SPD`
- `SANTAFEHYB_HVBAT_CMU001_VOLT` through
  `SANTAFEHYB_HVBAT_CMU072_VOLT`

Those require a separate OBD Service 21/22 query layer and a real adapter
response fixture. The Car Scanner demo cannot validate them.

## Acceptance Status

| Gate | Result |
| --- | --- |
| Car Scanner installed and launched on physical iPhone | PASS |
| Demo selector explored by UI automation | PASS |
| Last-used demo vehicle selected | PASS |
| Demo gauges and units observed | PASS |
| Real user vehicle connection shown in attached evidence | OBSERVED USER EVIDENCE |
| Real adapter response captured by this project | NOT TESTED |
| Real Santa Fe MX5 HEV OBDb signal verified | BLOCKED: HARDWARE RESPONSE REQUIRED |

No production code was changed by this follow-up.
