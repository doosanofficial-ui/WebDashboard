import Foundation

public enum MeasurementReplayError: Error, Equatable, Sendable {
    case invalidExport
    case sessionMismatch
    case malformedRow(String)
    case unsupportedKind(String)
}

/// Restores a persisted snapshot into the store only. It has no transport or
/// recorder reference. Callers must stop live ingestion before starting replay.
/// Invalid input never leaves a partially restored or mixed-session snapshot.
public enum MeasurementReplay {
    public static func replay(_ data: Data, into store: TelemetryStore) async throws {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(MeasurementExport.self, from: data) {
            try await replay(envelope, into: store)
            return
        }
        if let rows = try? decoder.decode([PersistedMeasurement].self, from: data) {
            try await replay(rows, session: nil, into: store)
            return
        }
        throw MeasurementReplayError.invalidExport
    }

    public static func replay(_ export: MeasurementExport, into store: TelemetryStore) async throws {
        guard export.schemaVersion == 1, !export.session.sessionID.isEmpty,
              export.session.startedAt.isFinite,
              export.session.endedAt.map({ $0.isFinite }) ?? true else {
            throw MeasurementReplayError.invalidExport
        }
        try await replay(export.measurements, session: export.session, into: store)
    }

    private static func replay(
        _ rows: [PersistedMeasurement],
        session: PersistedMeasurementSession?,
        into store: TelemetryStore
    ) async throws {
        let sessionID = session?.sessionID ?? rows.first?.sessionID
        if let sessionID, sessionID.isEmpty { throw MeasurementReplayError.invalidExport }
        // Persisted SQLite sequence is authoritative even if a wall clock moved
        // backwards or a consumer reordered the JSON array. Gaps are legitimate.
        let ordered = rows.sorted { $0.sequence < $1.sequence }
        var previousSequence: Int64 = 0
        var events: [MeasurementEvent] = []
        events.reserveCapacity(ordered.count)
        for row in ordered {
            guard row.sessionID == sessionID else { throw MeasurementReplayError.sessionMismatch }
            guard row.sequence > previousSequence,
                  row.sourceTimestamp.isFinite, row.receivedAtEpoch.isFinite else {
                throw MeasurementReplayError.invalidExport
            }
            previousSequence = row.sequence
            events.append(try decode(row))
        }
        try Task.checkCancellation()
        await store.replaceForReplay(events, session: session)
    }

    private static func decode(_ row: PersistedMeasurement) throws -> MeasurementEvent {
        let decoder = JSONDecoder()
        let data = Data(row.payloadJSON.utf8)
        func payload<T: Decodable>(_ type: T.Type) throws -> T {
            guard let value = try? decoder.decode(type, from: data) else {
                throw MeasurementReplayError.malformedRow(row.kind)
            }
            return value
        }
        func checkTimes(source: Double, received: Double, monotonic: UInt64) throws {
            guard source.isFinite, received.isFinite,
                  row.sourceTimestamp == source, row.receivedAtEpoch == received,
                  row.receivedAtMonotonicNanos == monotonic else {
                throw MeasurementReplayError.malformedRow(row.kind)
            }
        }
        switch row.kind {
        case "CAN":
            let frame = try payload(CANFrame.self)
            try checkTimes(source: frame.receivedAtEpoch, received: frame.receivedAtEpoch,
                           monotonic: frame.receivedAtMonotonicNanos)
            // Synthesized Codable bypasses CANFrame's validating initializer.
            guard (0...8).contains(frame.dlc), frame.payload.count == frame.dlc,
                  frame.canID <= (frame.isExtended ? 0x1FFF_FFFF : 0x7FF) else {
                throw MeasurementReplayError.malformedRow(row.kind)
            }
            return .can(frame: frame)
        case "SIGNAL":
            let signal = try payload(DecodedSignalSample.self)
            try checkTimes(source: signal.receivedAtEpoch, received: signal.receivedAtEpoch,
                           monotonic: signal.receivedAtMonotonicNanos)
            guard signal.value.isFinite else { throw MeasurementReplayError.malformedRow(row.kind) }
            return .signal(signal)
        case "DIAGNOSTIC_RESPONSE":
            let response = try payload(OBDResponse.self)
            try checkTimes(source: response.receivedAtEpoch, received: response.receivedAtEpoch,
                           monotonic: response.receivedAtMonotonicNanos)
            return .diagnosticResponse(response)
        case "DIAGNOSTIC_SIGNAL":
            let signal = try payload(DecodedOBDSignal.self)
            try checkTimes(source: signal.receivedAtEpoch, received: signal.receivedAtEpoch,
                           monotonic: signal.receivedAtMonotonicNanos)
            guard signal.value.isFinite else { throw MeasurementReplayError.malformedRow(row.kind) }
            return .diagnosticSignal(signal)
        case "LOCATION":
            let location = try payload(LocationSample.self)
            try checkTimes(source: location.originalTimestamp, received: location.receivedAtEpoch,
                           monotonic: location.receivedAtMonotonicNanos)
            return .location(location)
        case "SYSTEM":
            struct SystemPayload: Decodable { let name: String }
            let system = try payload(SystemPayload.self)
            guard !system.name.isEmpty else { throw MeasurementReplayError.malformedRow(row.kind) }
            try checkTimes(source: row.receivedAtEpoch, received: row.receivedAtEpoch,
                           monotonic: row.receivedAtMonotonicNanos)
            return .system(name: system.name, timestamp: row.sourceTimestamp,
                           monotonicNanos: row.receivedAtMonotonicNanos)
        default:
            throw MeasurementReplayError.unsupportedKind(row.kind)
        }
    }
}
