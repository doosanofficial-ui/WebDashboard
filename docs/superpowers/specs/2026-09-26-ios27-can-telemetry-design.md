# iOS 27 CAN/GPS Telemetry Dashboard Design

**Status:** implementation baseline for the first production vertical slice

**Goal:** Build a read-only iPhone telemetry application that can receive
Classical CAN frames through an abstract adapter, decode user-defined signals,
record CAN and Core Location samples in one session, and expose only a small,
policy-compliant status projection to CarPlay.

## Scope and invariants

- Classical CAN only in the first slice; CAN FD is rejected, not guessed.
- The public application API has no arbitrary CAN transmit, ECU write, DTC
  clear, or programming operation.
- Raw frame receive time is never labelled as the vehicle bus transmit time.
- GPS keeps `CLLocation.timestamp` and a separate phone receive/monotonic time.
- Raw acquisition, signal decoding, latest-value UI state, and recording are
  separate paths. UI refresh does not downsample the raw recorder.
- The actual NANICAR ELM327-BT4N transport is unknown until its services,
  characteristics, framing, and responses are observed.
- CarPlay is an optional, entitlement-gated projection. It is not a copy of the
  SwiftUI dashboard or its editor.

## Product shape

The first shippable vertical slice is:

```text
MockCANTransport or qualified ELM transport
  -> ELM327Session / raw frame parser
  -> one configurable CAN ID
  -> one configurable SignalDefinition
  -> TelemetryStore actor
  -> Numeric display + GPS card
  -> SQLite session recorder + CSV/JSON export
```

The Windows server and Vector/CANoe/CANape paths remain supported as an
alternative capture source. A future server bridge can publish the same typed
frame contract, so the iPhone UI and recorder do not depend on ELM327.

## Module boundaries

### Pure Swift package

`mobile-ios/TelemetryCore` owns code that can run in XCTest without a device:

- `CANModel`: `CANFrame`, `SignalDefinition`, byte order, source metadata.
- `CANDecode`: bounded 11-bit/29-bit frame parsing and Intel/Motorola signal
  extraction.
- `TransportCore`: `CANTransport` protocol, transport events, and mock stream.
- `ELM327Core`: line/prompt framing, capability replies, allowlisted command
  model, and the `ELM327Session` state machine.
- `TelemetryCore`: actor-owned latest values, quality/staleness transitions,
  and raw/decode event fan-out.
- `RecordingCore`: session metadata, SQLite writer contract, close/failure
  events, and CSV/JSON export interfaces.
- `DashboardModel`: versioned signal/widget/profile JSON. The editor is later;
  the first slice only loads one numeric binding.

### iOS application target

`mobile-ios/App` owns system integrations:

- `BLETransport`: Core Bluetooth discovery and characteristic I/O after the
  actual adapter profile is known.
- `WiFiTransport`: Network framework TCP framing for an observed Wi-Fi adapter.
- `LocationService`: Core Location permissions, background mode, original
  timestamps, and stale diagnostics.
- `CarPlayScene`: compile-time framework boundary and entitlement-gated status
  projection.
- SwiftUI views: phone dashboard, recording state, and configuration UI.

No module may import an ELM327 type from a SwiftUI view. No CarPlay scene may
own the acquisition or recorder lifecycle.

## Data model

`CANFrame` contains:

```text
receivedAtEpoch
receivedAtMonotonicNanos
canID
isExtended
dlc
payload[0...8]
sourceAdapter
sourceTransport
sequence
```

`SignalDefinition` contains `id`, `name`, `canID`, `startBit`, `bitLength`,
`byteOrder`, `signed`, `factor`, `offset`, `min`, `max`, `unit`, `timeout`, and
an optional enum map. Intel uses DBC-compatible LSB numbering; Motorola uses
DBC-compatible MSB start-bit semantics. Each is pinned by fixtures.

`SignalState` contains the decoded value, `valid/stale/invalid/disconnected`
quality, source frame time, receive time, and last-valid time. A timeout never
turns a held value into a fresh value.

`LocationSample` preserves the original Core Location timestamp, latitude,
longitude, altitude, speed, course, horizontal accuracy, vertical accuracy,
phone receive time, and monotonic time.

## Transport and session behavior

```text
Disconnected -> Connecting -> Initializing -> Ready -> Monitoring
Monitoring -> Recovering -> Connecting
any state -> Error -> Recovering or Disconnected
```

The transport writes bytes, but the ELM session exposes only typed, allowlisted
adapter commands. During `Monitoring`, no periodic AT command is sent. The
session handles prompt fragmentation, echo, `NO DATA`, `BUFFER FULL`, malformed
frames, disconnects, and unsupported commands. A `CSM1` capability failure is a
live-vehicle safety failure, not a silent fallback to active bus behavior.

## Concurrency and storage

- `CANReceiver` is an actor or isolated task that reads the transport and emits
  parsed frames.
- `TelemetryStore` is an actor and never blocks on SwiftUI or disk I/O.
- `Recorder` is a separate actor/serial writer using SQLite WAL and bounded
  batches. A frame accepted by the receiver is either committed or produces an
  explicit storage error/overrun event.
- The UI subscribes to latest-value snapshots at approximately 10 Hz. It does
  not control the raw receive rate.
- Storage tables are session metadata, raw CAN frames, decoded signal samples,
  location samples, and system events.

## Background and CarPlay policy

Core Location uses the documented location background mode and explicit user
consent. Bluetooth background operation is treated as best effort until the
BT4N device passes the locked-screen test. If continuous raw capture is
required while locked, the Windows/Vector bridge is the authoritative capture
path and the phone displays/reconciles it.

CarPlay begins with one glanceable status surface: connection, recording,
profile, elapsed session, and a few validated values. The full editor,
high-frequency gauges, and raw hex stream remain on the phone. Entitlement
approval is a release gate, not a compile assumption.

## Phase sequence

1. Pure CAN model, decoder, ELM framing, and deterministic tests.
2. Mock transport and ELM session state machine.
3. TelemetryStore, recording, export, and Core Location integration.
4. Numeric iPhone vertical slice and profile JSON.
5. BT4N profile discovery and stationary vehicle acceptance.
6. Background/lock/reconnect endurance evidence.
7. Multi-signal dashboard editor and widget model.
8. CarPlay entitlement request, minimum template projection, and vehicle/simulator
   validation.

## Non-goals for this implementation cycle

- Full DBC import.
- Automatic discovery of undocumented adapter UUIDs.
- CAN FD.
- Arbitrary CAN transmit or ECU programming.
- Claiming iOS 27 compatibility from the installed Xcode 26.3 toolchain.
- Claiming CarPlay support without entitlement and runtime evidence.
