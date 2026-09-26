# OBD Open-Source Qualification Follow-up

Checked: 2026-09-26. This is a source and public-runtime evidence review, not a
physical BT4N or Santa Fe MX5 HEV test. GitHub star counts are discovery signals;
they are not counts of independent successful vehicle sessions.

## Current candidates

| Repository | Stars shown during review | License | Evidence that is useful here | Decision |
| --- | ---: | --- | --- | --- |
| [AndrOBD](https://github.com/fr3ts0n/AndrOBD) | 2.1k | GPL-3.0 | Android Bluetooth/BLE/USB/Wi-Fi, demo mode, recording/charts/dashboard; FAQ documents clone and permission failures | Android reference only |
| [python-OBD](https://github.com/brendan-w/python-OBD) | 1.3k | GPL-2.0 | Mature serial/COM implementation, Windows COM fixes, explicit timeout guidance | Windows bridge reference; not an iOS BLE implementation |
| [ELMduino](https://github.com/PowerBroker2/ELMduino) | 920 | MIT | Embedded nonblocking state-machine pattern and ELM command coverage | Protocol/scheduling reference; not an iOS runtime |
| [ELM327-emulator](https://github.com/Ircama/ELM327-emulator) | 676 | CC BY-NC-SA 4.0 | Multi-ECU/TCP/serial/Bluetooth emulation, vehicle scenarios, reproducible software fixtures | Test-only candidate pending license approval; never bundle by default |
| [LTSupportAutomotive](https://github.com/mickeyl/LTSupportAutomotive) | 248 | MIT | iOS/macOS BLE and stream bridge, maintainer-tested adapter list, explicit iOS Classic Bluetooth limitation | Reference/evaluation candidate; no BT4N proof |
| [SwiftOBD2](https://github.com/kkonteh97/SwiftOBD2) | 153 | MIT | Modern Swift package, Wi-Fi/Bluetooth API and emulator claims | Do not adopt unmodified; reconnect issue requires a fix and regression test |
| [OBDb Hyundai definitions](https://github.com/OBDb/Hyundai-Santa-Fe-Hybrid) | 3 in the 2026-09-23 metadata snapshot | CC BY-SA 4.0 | Vehicle-specific fixtures and PID definitions | Selective data reference only; validate year/market and every signal |

## Operational evidence

- AndrOBD's public documentation shows a real, maintained Android application with
  live data, recording, charts and multiple transport types. Its FAQ also records
  current permission/demo-mode problems and cheap-clone initialization failures;
  that is useful field evidence, but it does not transfer to iOS or BT4N.
- `python-OBD` documents that its adapter path is serial/COM and its troubleshooting
  page calls out Bluetooth pairing and timeout problems. A successful Raspberry Pi
  or USB report is not evidence that an iPhone can access the same adapter.
- ELMduino has an open issue about query speed and vehicle-side symptoms. Keep our
  read-only allowlist and bounded request policy; do not infer a safe 10 Hz query rate
  from its example loop.
- The ELM327 emulator is excellent for deterministic integration tests and Windows
  TCP/COM experiments, but its actual license is non-commercial/share-alike. It is
  not an acceptable production dependency for this project without a separate license
  decision.
- LTSupportAutomotive's README contains maintainer-tested BLE hardware names and
  explicitly states that arbitrary iOS Bluetooth Classic access is unavailable. Its
  public LELink issue reports an initialization stall, so the adapter UUID and
  characteristic path must still be tested rather than inferred.
- SwiftOBD2's README lists tested adapters, but its public issue #41 describes
  accumulated state and reconnect failure in an iOS production app. Stars and a
  successful upstream unit-test run do not remove that acceptance failure.
- Pelican's [scanner table](https://pelican.clutch.engineering/scanning/) reports
  adapter-specific support and PID rates, including a generic ELM327 BLE entry that
  is marked unsupported. It does not list the NANICAR BT4N, so it cannot certify this
  hardware.
- OBDb's Santa Fe definitions are valuable fixtures, but public issues question
  hybrid SOH/energy offsets and TPMS mappings. A vehicle definition is not a verified
  MX5 HEV signal until it is compared with a trusted diagnostic reference on the
  exact year/market.

## Project decision

No reviewed open-source runtime satisfies all of: iOS, raw/observed ELM transport,
the NANICAR BT4N, Hyundai Santa Fe MX5 HEV, background collection, and a large set of
independent reproducible success reports. Keep the in-house `TelemetryCore` boundary,
use LTSupportAutomotive and SwiftOBD2 as comparison material only, use `python-OBD`
only for a separately isolated Windows serial bridge evaluation, and use the emulator
only after licensing approval for test fixtures.

The acceptance evidence required before adoption is: adapter identifier and transport
capture, exact iOS version, exact vehicle year/market, raw request/response, reconnect
and timeout logs, and a trusted-value comparison. Public stars, README claims,
screenshots, issue comments, or a demo mode do not satisfy that gate.

## Official platform constraints

- Apple documents that `CBManager.state` begins as `unknown` and that apps must wait
  for `poweredOn`; the live BLE transport now implements that wait instead of failing
  the first connection attempt.
- Apple documents `bluetooth-central` for background BLE events but also states that
  background execution is resource-limited and the app may be terminated. A 30-minute
  locked-screen test remains mandatory.
- Apple requires a requested and approved CarPlay entitlement for the applicable
  category. No arbitrary CAN gauge screen is treated as CarPlay-approved.
- ELM Electronics documents `MA`, `CF`, `CRA`, `CAF0/1` and `CSM0/1`; the app keeps
  monitoring commands allowlisted and does not send periodic commands while monitoring.
