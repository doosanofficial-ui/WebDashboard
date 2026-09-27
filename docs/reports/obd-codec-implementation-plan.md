# OBD Codec Implementation Plan

> Execution: direct parent, test-first, under the user's standing authorization.

**Goal:** Prepare a hardware-independent native Mode 01 parser without claiming or
attempting BT4N connectivity. This is a first slice of C20, not its completion.

**Architecture:** Core Bluetooth will supply byte fragments to a bounded prompt framer.
A pure decoder handles one complete, headerless response for one typed request.
Unknown profiles, header formats and multiple responses fail closed, rather than
guessing ECU identity. Transport and timestamps remain separate responsibilities.

**Tech stack:** Existing Swift TelemetryCore package and XCTest; no new dependency.
**Spec:** [ADR-0004](../adr/0004-obd-bt4n-integration.md).

## Scope

- Source: `mobile-ios/TelemetryCore/Sources/TelemetryCore/ELM327.swift`.
- Tests: `mobile-ios/TelemetryCore/Tests/TelemetryCoreTests/ELM327Tests.swift`.
- `OBDPID` allowlists 00, 05, 0C, 0D; emits only `01xx\r` commands.
- `ELM327Framer.feed(Data) throws -> [String]`: <=4096 bytes/fragment and buffered
  response, ASCII only, complete `>`-terminated replies. Invalid input discards state.
- `ELM327Decoder.decode(String, for: OBDPID) throws -> OBDReply`: exact payload length,
  matching Mode 41/PID, bitmask/RPM/speed/coolant units, explicit no-data result.
- No Bluetooth permission changes, live requests, arbitrary command API, v2 schema
  changes, UI claim, new release package or vehicle-specific PID inference.

## Test-first execution

- [x] Write failing tests for fragmented prompts, strict read-only command construction,
  overflow/non-ASCII, echo/search text, scaling, real zeros, capability bit order,
  no-data vs error, wrong PID, headers, truncated data and multi-ECU ambiguity.
- [x] Run full Core XCTest; record missing implementation failure.
- [x] Implement the two pure boundaries, keeping normalized errors nonnumeric.
- [x] Run full Core XCTest and existing simulator compile with source hash manifest.
- [x] Review/commit with limitations explicit. Hardware C19-C24 stay unchecked.

Hand-checked fixtures: `410C1AF8` = 1726 rpm; `41057B` = 83 Celsius;
`410D28` = 40 km/h; `410008180001` advertises PIDs 05/0C/0D/20.
These are synthetic/ELM specification fixtures, **not BT4N/MX5 captures**.

## Review focus

- Late reply after reconnect: transport must discard its old framer and in-flight query.
- Multiple ECUs with identical values: still ambiguous without identity, never silently merge.
- `NO DATA` mixed with success/error: reject mixed replies, never choose the last line.
- Engine-off RPM zero is a valid measured result; no-data cannot take that representation.
- Hidden headers or partial bytes: reject rather than stripping data to fit the expected PID.

Next dependent slice: C19 profile evidence, then a Core Bluetooth transport and scheduler
with single in-flight requests and timeout resynchronization. Never connect this decoder
to a guessed characteristic or to the existing GPS-only ingest endpoint.

Update after the user's OSS requirement: C25 library comparison now precedes a full
transport implementation. Reuse the codec tests as acceptance cases for candidates.
Core 23 tests and the Xcode 26.3 / iOS 26.2 simulator compile passed at
`/tmp/telemetry-ios-verify.sNwiLP`; no iOS 27/device claim is made.
CRLF handling and x86_64 compiler type-check complexity were corrected during verification.
