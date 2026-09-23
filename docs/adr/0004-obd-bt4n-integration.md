# ADR-0004: NANICAR OBD-II Integration

- Date: 2026-09-23
- Status: Accepted for implementation under standing authorization; hardware compatibility unverified
- Target: Hyundai Santa Fe MX5 HEV; model year/market not yet supplied
- Adapter: NANICAR ELM327-BT4N, 12V, identified from the user's four photographs
- Primary device: iPhone 17 / iOS 27, exact OS build pending reconnection

## Intent and evidence boundary

Add the user's existing OBD scanner as another measurement source. Preserve the
Vector VN1640A path: an OBD scanner is not a replacement for decoded raw CAN signals.
The body label identifies BT4N; the box lists the BT4/BT4N family. The package claims
dual-mode Bluetooth 4.0 and iOS/Android/Windows support. Those are label claims,
not proof of this unit's GATT profile, firmware, throughput or MX5 HEV PID support.
No vehicle traffic or Bluetooth communication has yet been captured by this project.
Do not publish the user's photos, nearby-device identifiers or a VIN as test evidence.

## Decision and alternatives

1. **Primary: native iOS Core Bluetooth central.** Discover the selected adapter's
   actual services and characteristics; validate write/notify properties and ELM
   replies before storing a device profile. Collect GPS and OBD into one native
   session with separate source/time/quality fields. No laptop required for local
   recording, but server upload still requires the authenticated HTTPS path.
2. **Alternative: Windows bridge.** Use confirmed BLE GATT, or a verified Classic
   serial/COM interface if this unit exposes one. An independent receiver maintains
   timestamped samples for the server; do not block the 10Hz broadcaster on queries.
   This reuses the web dashboard and avoids relying on phone background polling.
3. **Not selected: Safari/PWA Bluetooth.** Safari has no Web Bluetooth support in
   the current [MDN compatibility data](https://github.com/mdn/browser-compat-data/blob/main/api/Bluetooth.json).
   HTTPS or a PWA manifest does not provide that missing transport. The web client
   receives OBD through the bridge. Classic SPP must not be assumed accessible as
   an iOS serial port merely because the packaging says Bluetooth 4.0.

The primary and bridge transports are interchangeable collection locations, not
simultaneous owners of one scanner. Select explicitly; never silently switch to
dummy data or connect to the strongest nearby Bluetooth device. A failed BLE
profile check is a compatibility blocker, not permission to guess common UUIDs.

## First supported scope

- Verify adapter identity and a confirmed, non-persistent setup sequence first.
  Record `ATI` as self-reported firmware, not as proof of genuine ELM silicon.
- Query Mode 01 PID 00 capabilities, then only advertised, implemented PIDs:
  `0C` RPM, `0D` vehicle speed and `05` coolant temperature. These are defined in
  the [python-OBD project's command table](https://python-obd.readthedocs.io/en/latest/Command%20Tables/).
- ELM replies need prompt-delimited assembly, echo handling, one command in flight,
  timeout recovery and multiple-ECU detection. A `NO DATA` result is not numeric zero
  and does not alone prove unsupported PID. See the original
  [ELM327 datasheet](https://www.elmelectronics.com/wp-content/uploads/2017/01/ELM327DS.pdf),
  sections Communicating, Talking to the Vehicle and Multiline Responses.
- No DTC clear (Mode 04), ECU writes, coding, actuator control, arbitrary command
  console, manufacturer diagnostic sessions, security access or HV battery control.
  Mode 01 is read-only at the diagnostic service level but still transmits requests;
  it is not passive CAN monitoring. Bound the query rate and stop on persistent errors.
- Follow the photographed **12V** rating. Do not use on a 24V vehicle or unidentified
  supply. First testing is stationary with a qualified operator and a clear Stop action.

## Santa Fe MX5 HEV semantics

- Treat engine RPM zero during engine-off operation as a possible valid value, not
  connection loss. Connection health comes from replies/timeouts, not RPM magnitude.
- Keep `obd_vehicle_speed_kmh` distinct from GPS speed and `ws_fl/fr/rl/rr`.
  Never fill four wheel-speed cards with the single OBD speed value.
- Yaw, ax/ay, individual wheel speeds, HEV battery SOC/current/cell data and TPMS
  are not promised by the initial three-PID scope. Add OEM PIDs only with confirmed
  vehicle/year definitions, units, permissions and real comparison evidence.
- Preserve actual zero, unsupported, no-data, stale and disconnected as different
  states. Engine-off, READY/engine-on and ignition-off transitions are separate tests.
- Model year and regional specification remain unknown; no Hyundai-specific PID
  address, gateway unlock or diagnostic procedure is inferred from the model name.

## Data, timing and UI boundary

- Existing CAN delivery remains 10Hz. OBD acquisition is response-driven; measure
  each PID's actual frequency/latency independently from the 100ms display tick.
- Record request start and complete response times. ELM Mode 01 does not supply
  an ECU measurement timestamp for these values; label the local timestamp
  `observed_t`, not an invented precise ECU capture time. Include monotonic durations.
- Define an immutable OBD sample with event ID, source session, PID, signal, unit,
  value/null, quality, observation time and receive time. A held value keeps its
  original time; a render tick must not create a new measured sample.
- GPS/MARK/STATE-only v2 ingestion does **not** currently accept OBD. Add a separate
  versioned OBD ingestion contract with validation, durable ACK, replay/conflict
  tests and CSV export before wiring either collector. Never tunnel OBD through
  `/api/gps`, rewrite `captured_t`, or bypass the existing unknown-type rejection.
- Add source-specific gauge layouts and charts. OBD charts show only supported
  signals, units and quality; CAN and OBD/GPS speed remain distinguishable.

## Background constraints

The iOS transport needs explicit user Start/Stop, Bluetooth permission,
`bluetooth-central` and state restoration, not only `location` mode. Apple documents
different scan behavior and bounded execution while backgrounded; it does not grant
an unrestricted 10Hz timer. See [Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).

GPS background success is not OBD polling success. Test 30-minute lock separately
for BLE disconnect, OS termination/relaunch, network loss and adapter power loss.
If this request/response device cannot sustain the required locked-screen capture,
report the actual bound and use the Windows bridge for continuous OBD collection;
do not present interpolation or replay as fresh readings. CarPlay remains a separate
category/entitlement gate, not an automatic consequence of OBD connectivity.

## Delivery order and acceptance

The executable checklist and evidence fields are in
[the BT4N compatibility run sheet](../reports/obd-bt4n-compatibility.md).
Current product tasks C19-C24 are in [production-plan.md](../production-plan.md).
Software fixtures, simulator behavior, hardware connectivity and vehicle readings
are separate evidence levels. Only the last two can qualify this specific scanner.

## Open-source selection gate (same-day user requirement)

Before expanding the transport implementation, apply C25 from the product plan.
[The source/usage/license review](../reports/obd-oss-research-2026-09-23.md) identifies
LTSupportAutomotive and SwiftOBD2 for iOS evaluation, python-OBD for a confirmed
serial bridge, and OBDb for selective vehicle data review. None is adopted yet.
Pelican publishes useful benchmarks and links OBDb but does not establish BT4N
compatibility. Its Santa Fe data also has unresolved TPMS/SOH reports.
Do not blindly copy PID tables, import diagnostic writes or assume high stars mean
our exact device/vehicle/OS combination is verified. Preserve license obligations.
