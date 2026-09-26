# iOS 27 CAN/GPS/CarPlay/ELM327 Research

Checked: 2026-09-26. This is an architecture input report, not a production
implementation or a hardware compatibility approval.

## Executive findings

- The iOS app must keep CAN acquisition, decoding, storage, SwiftUI refresh,
  and CarPlay projection as separate boundaries.
- The existing project can use a pure Swift package for CAN models, signal
  decoding, ELM327 framing, telemetry state, and recorder tests. Core Bluetooth,
  Core Location, and CarPlay belong in iOS-only adapters.
- The NANICAR ELM327-BT4N label does not establish its GATT services, serial
  profile, firmware behavior, raw CAN visibility, or Santa Fe MX5 HEV coverage.
  The hardware run sheet remains NOT RUN until those values are observed.
- A direct iPhone path is feasible only after the adapter's actual transport is
  identified. A GATT-capable BLE or GATT-over-BR/EDR profile can use Core
  Bluetooth. A classic SPP-only profile must not be assumed to be usable by an
  arbitrary iOS app; a Windows bridge or an MFi accessory path is the fallback.
- CarPlay is not an automatic projection of the SwiftUI dashboard. Apple
  requires a category-matching entitlement and controls the CarPlay template
  interface. The proposed first CarPlay surface is status-only and remains
  optional until Apple confirms the category and grants the entitlement.
- The local Mac currently reports Xcode 26.3 with iOS 26.2 SDK. This is not
  evidence of an iOS 27 build. Xcode 27 and an iOS 27 SDK are required for the
  iOS 27 compile and device gates.

## Apple platform facts

### Xcode and iOS 27

Apple's current Xcode material identifies Xcode 27 as the toolchain containing
the iOS 27 SDK. Apple's submission guidance also states that apps must be built
with the iOS 27 SDK or later starting with the stated future submission date.
The local verification command on this host reports `Xcode 26.3` and
`iOS 26.2`, so no iOS 27 compile or device result is claimed here.

Sources:

- [Xcode](https://developer.apple.com/xcode)
- [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
- [App Store submission requirements](https://developer.apple.com/app-store/submitting/)

### Core Bluetooth and accessory transport

Apple documents Core Bluetooth support for Bluetooth LE and BR/EDR devices, but
the application still needs a usable GATT service and characteristic contract.
Apple's External Accessory framework is for MFi accessories and their declared
protocols. Therefore the adapter discovery task must record the actual
advertised services, characteristic properties, framing, and write/notify
behavior rather than copying UUIDs from another ELM327 product.

Background Bluetooth is event-driven and resource constrained. The
`bluetooth-central` background mode can wake an app for relevant central events,
but it is not a promise of an unrestricted, forever-running high-rate polling
loop. iOS 26 and later document additional Live Activity-related background
behavior; that behavior is an optimization to investigate, not the Phase 1
correctness contract.

Sources:

- [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth/)
- [Core Bluetooth background processing guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- [External Accessory](https://developer.apple.com/documentation/externalaccessory/)
- [Core Bluetooth transport bridging](https://developer.apple.com/documentation/corebluetooth/cbconnectperipheraloptionenabletransportbridgingkey)

### Core Location and locked-screen collection

For continuous background location, Apple documents the `location` background
mode and `allowsBackgroundLocationUpdates`. The system may suspend applications
and queue updates; the app must preserve the original `CLLocation` timestamp and
must not manufacture a 10 Hz GPS source. The recorder should distinguish the
location event time from the phone receive time and should surface stale data.

Sources:

- [Core Location](https://developer.apple.com/documentation/corelocation/)
- [Handling location updates in the background](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
- [allowsBackgroundLocationUpdates](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates)

### CarPlay

Apple states that CarPlay apps use the CarPlay framework and system-controlled
templates. The app controls content, while the framework controls interface
details such as touch targets, fonts, colors, and highlights. The app must
request the appropriate entitlement for its category; Apple reviews the request
and provisions managed capabilities when approved.

Apple's current CarPlay overview and WWDC materials mention driving task and
fueling categories. The public entitlement table currently exposes a subset of
category keys, so the project must not invent or hardcode an entitlement key for
this telemetry app. The Apple request flow and the granted provisioning profile
are the source of truth. A vehicle telemetry dashboard may be a reasonable
driving-status use case, but eligibility is not established by the API alone.

The first CarPlay design is therefore one glanceable status surface: adapter
connection, recording state, active profile, and a small number of validated
status values. High-frequency animated gauges, a free-form SwiftUI canvas, and
the full dashboard editor stay on iPhone/iPad unless Apple grants a category and
the allowed templates support the requested interaction.

Widgets and Live Activities can provide glanceable CarPlay information, but they
are not treated as a replacement for a full custom CAN dashboard or as a 10 Hz
raw-data transport.

Sources:

- [CarPlay overview](https://developer.apple.com/carplay/)
- [CarPlay framework](https://developer.apple.com/documentation/carplay/)
- [Requesting CarPlay entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
- [CarPlay HIG](https://developer.apple.com/design/human-interface-guidelines/carplay)
- [What's new for enterprise developers](https://developer.apple.com/videos/play/tech-talks/110356/)
- [Turbocharge your app for CarPlay](https://developer.apple.com/videos/play/wwdc2025/216/)

## ELM327 command findings

The source of truth for these command meanings is the official ELM327 data
sheet, not a clone adapter README. The commands below are configuration or
monitoring controls. The app will not expose arbitrary CAN transmit or ECU
write APIs.

| Command | Official meaning | Phase 1 treatment |
| --- | --- | --- |
| `AT MA` | Monitor all messages seen on the OBD bus. It is a quiet monitor and does not send normal CAN acknowledges while silent monitoring is enabled. | Start the bounded raw receive stream only after capability and protocol checks. Stop through the session state machine. |
| `AT CRA` | Set or reset the CAN receive address; supports 11-bit and 29-bit forms and can simplify one-ID filtering. | Use for a configured single-ID slice when the adapter accepts it; verify the result with captured frames. |
| `AT CF` | Set the CAN ID filter. | Use only from the typed filter configuration. |
| `AT CM` | Set the CAN ID mask used with the filter. | Use only from the typed filter configuration. |
| `AT H1` | Turn headers on. Headers are required to identify the CAN ID in a raw monitor capture. | Enable during discovery and raw capture unless the adapter's output contract proves another format. |
| `AT CAF0` / `AT CAF1` | Disable or enable CAN automatic formatting. `CAF1` is the default. | Prefer a documented raw-compatible profile, normally `CAF0`, and parse the exact observed output. Never assume clone parity. |
| `AT CSM1` / `AT CSM0` | Enable or disable CAN silent monitoring. The data sheet warns that disabling silent monitoring can affect the bus. | Treat `CSM1` as a safety capability gate. If unsupported or ambiguous, do not approve live vehicle monitoring. |

The data sheet also documents a 512-byte internal RS232 transmit buffer and the
`BUFFER FULL` condition. A full buffer means received data can be lost and the
session must recover. It explicitly says the maximum useful data rate depends on
multiple factors, so no fixed ELM327 throughput or 10 Hz raw-frame guarantee is
assumed.

The ELM327 output is adapter receive data. It is not a timestamp from the CAN
controller on the vehicle bus. The data model therefore stores an iPhone
receive timestamp and an optional adapter sequence, but never labels that time
as a bus-transmit timestamp.

Source:

- [ELM327 official data sheet PDF](https://www.elmelectronics.com/wp-content/uploads/2016/07/ELM327DS.pdf)

## Existing open-source evidence

The repository's 2026-09-23 research report remains the current qualification
record. It found no open-source project proving the exact NANICAR BT4N,
domestic Hyundai Santa Fe MX5 HEV, iOS 27 combination with a large set of
independent verified successes.

- High star counts rank discovery candidates; they do not prove this adapter or
  vehicle combination.
- `LTSupportAutomotive` and `SwiftOBD2` remain evaluation candidates, not
  adopted runtime dependencies. The pinned offline qualification found build
  success but acceptance failures around timeout or PID behavior.
- `python-OBD` is a Windows serial/COM reference and does not establish a BLE
  GATT path for BT4N.
- `ELMduino` is useful protocol/scheduling reference material, not an iOS
  runtime.
- `OBDb/Hyundai-Santa-Fe-Hybrid` is useful for year-specific vehicle data, but
  its small star count and unresolved definitions mean it cannot substitute for
  redacted vehicle captures.
- The Pelican data is a useful external benchmark and vehicle-data reference,
  not a BT4N compatibility certificate or a reusable scanner SDK.

Evidence in this repository:

- [OBD ecosystem research](obd-oss-research-2026-09-23.md)
- [Pinned candidate qualification](obd-candidate-qualification-2026-09-23.md)
- [BT4N / Santa Fe hardware run sheet](obd-bt4n-compatibility.md)

## Required hardware observations before live integration

- Adapter identity response and firmware string.
- Transport type: BLE GATT, GATT-over-BR/EDR, Wi-Fi TCP, or unsupported classic
  serial profile.
- Service and characteristic UUIDs, properties, MTU, fragmentation, and prompt
  or line framing.
- Supported CAN protocol and baud rate on the target vehicle.
- Whether the OBD connector exposes the required vehicle CAN network or only a
  gateway/diagnostic subset.
- Whether `AT H1`, `AT CAF0`, `AT CSM1`, filtering, and `AT MA` are accepted and
  produce the documented behavior.
- Measured frame rate, P95 receive latency, and `BUFFER FULL` behavior under
  stationary and driving conditions.
- Vehicle model year, market, READY/engine state, and trusted-reference values.

## Evidence status

- Official API/data-sheet research: COMPLETE for architecture planning.
- Current local iOS 27 compile: BLOCKED by the installed Xcode 26.3 / iOS 26.2
  SDK; no iOS 27 result claimed.
- BT4N live transport discovery: NOT RUN.
- Santa Fe MX5 HEV raw CAN/signal verification: NOT RUN.
- CarPlay entitlement/category approval: NOT REQUESTED and NOT GRANTED.
- Production implementation: intentionally deferred until design approval.
