# BT4N / Santa Fe MX5 HEV Compatibility Run Sheet

Baseline: 2026-09-23. **NOT HARDWARE-VERIFIED.**
Spec: [ADR-0004](../adr/0004-obd-bt4n-integration.md).
Keep values below empty until observed; do not replace them with typical ELM UUIDs.

## Known inputs

| Item | Evidence | Current conclusion |
|---|---|---|
| NANICAR ELM327-BT4N | User photo 4, body label | Unit model identified |
| 12V | User photo 4 | Do not connect to 24V |
| BT4.0 dual mode, iOS/Android/Windows | Photos 2-3, package | Advertising claim, not live compatibility |
| Hyundai Santa Fe MX5 HEV | User answer | Test target, year/market unconfirmed |
| iPhone 17 / iOS 27 | User answer | Primary device; exact build unconfirmed |
| Xcode 26.3 / macOS 26.6.2 | Local commands 2026-09-23 | Prepare Xcode 27 SDK validation |
| BLE/serial/vehicle session | None | NOT RUN |

## 1. Hardware discovery (C19, P0)

- [ ] Record model year and regional specification without recording VIN.
- [ ] Confirm safe 12V connection/operating conditions with vehicle/operator instructions.
- [ ] Close competing OBD apps; keep one transport owner and an explicit Stop control.
- [ ] Verify selected device locally, then record only its redacted profile.
- [ ] Discover services/characteristics and read/write/notify/indicate properties.
- [ ] Confirm actual write mode, maximum payload/fragmentation and notification setup.
- [ ] Perform adapter-local identity/configuration exchange; capture bounded replies.
- [ ] Query Mode 01 capabilities while stationary; distinguish no response from unsupported.

Record: OS/build, app commit, vehicle year, selected transport, service UUID,
write UUID/property, receive UUID/property, self-reported firmware, prompt/echo format,
protocol, number of responding ECUs, advertised PID bitmap, permission/connection errors.
Do not record pairing codes, secrets, VIN or unrelated nearby peripherals in the repo.

## 2. Deterministic protocol tests (C20/C21, P0)

- [ ] Fragmented notifications, multiple prompts, CR/LF, echo and `SEARCHING...`.
- [ ] Response length/mode/PID validation; reject malformed or mismatched data.
- [ ] Multiple ECUs: identify verified source or return ambiguous, never last-response wins.
- [ ] `NO DATA`, `?`, `STOPPED`, timeout and bus errors stay nonnumeric.
- [ ] Supported-PID bit order and range, RPM scaling, speed units, coolant offset.
- [ ] Unknown/unsupported values never become 0; real speed/RPM 0 remains valid.
- [ ] Single in-flight request; bounded buffer/rate/backoff, Stop cancels work.
- [ ] Command allowlist rejects DTC clear, injection/newlines and all ECU writes.
- [ ] Disconnect cannot reuse partial data or attach a late reply to a new request.

Each test must fail against the faulty/missing implementation before acceptance.
Synthetic fixtures are explicitly labeled; replace/add redacted physical captures
after C19. An ELM datasheet example is not a BT4N vehicle capture.

## 3. Native and bridge integration (C20-C22)

- [ ] iOS 27 signed install and user-triggered Core Bluetooth permission/discovery.
- [ ] No guessed GATT UUID and no automatic connection to a device by signal strength.
- [ ] Windows BLE or confirmed serial path feeds a nonblocking timestamped sample cache.
- [ ] Existing CAN source and GPS/MARK paths stay usable; no implicit dummy fallback.
- [ ] Versioned OBD ingest/ACK/replay tests pass; existing v2 continues rejecting OBD.
- [ ] OBD gauges/graphs show actual PID sample age/rate; unsupported CAN cards are absent/N/A.
- [ ] Original observation time/event ID survive queue replay and CSV export.

## 4. Vehicle and background acceptance (C23/C24, P0/P1)

- [ ] Compare stationary readings with a trusted diagnostic reference for the same PID/ECU.
- [ ] Record engine-off/READY/engine-on transitions, zero RPM and actual no-data cases.
- [ ] Measure each PID's Hz/latency and total traffic for at least 10 minutes.
- [ ] iPhone lock 30 minutes: native generated-event count vs persisted/ACK count, not 10Hz assumption.
- [ ] Separately test GPS collection, OBD collection and server delivery during lock.
- [ ] Network disconnect/recovery: no unexplained loss after replay, logical deduplication.
- [ ] Bluetooth disconnect/adapter power loss: stale immediately visible; no fabricated data.
- [ ] Restore/force-quit/reboot/permissions and battery observations recorded separately.
- [ ] Windows bridge alternative measured if phone polling pauses; no hidden downgrade.
- [ ] Version/commit/package/device install and test evidence match before release qualification.

## Result record

- Run UTC / tester:
- App/server commits and versions:
- Device OS/build / Xcode SDK:
- Vehicle year/region and operator-confirmed setup:
- Adapter profile revision / firmware response:
- Supported PIDs / ECU selection:
- Actual per-PID Hz / P95 reply duration / stale threshold:
- Native original event count / server unique count / pending count:
- Background interval / transport interruptions / power states:
- Sanitized evidence paths:
- Verdict: NOT RUN / SOFTWARE ONLY / HARDWARE CONNECTED / VEHICLE VERIFIED / FAIL
- Remaining blockers:

Current verdict: **NOT RUN**. Photos establish identity, not measured compatibility.

## OSS evidence gate (C25)

See [the repository and usage review](obd-oss-research-2026-09-23.md).
Do not label the scanner as supported based on stars or Pelican's generic ELM row.
The new pure codec's eight synthetic tests pass; they do not change the hardware verdict.
- [ ] Candidate version/license/usage evidence reviewed before runtime integration.
- [ ] Known reconnect, multi-ECU and no-data regressions reproduced against candidates.
- [ ] Vehicle-specific definitions checked against unresolved OBDb issues and actual model year.
