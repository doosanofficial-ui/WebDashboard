import Foundation

public enum MeasurementReplayError: Error, Equatable, Sendable {
    case invalidExport
    case sessionMismatch
    case malformedRow(String)
    case unsupportedKind(String)
}

/// Replays persisted rows into the store only. It has no transport reference,
/// cannot issue a vehicle request, and does not append new recorder rows.
public enum MeasurementReplay {
    public static func replay(_ data: Data, into store: TelemetryStore) async throws {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(MeasurementExport.self, from: data) {
            try await replay(envelope, into: store)
            return
        }
        if let rows = try? decoder.decode([PersistedMeasurement].self, from: data) {
            try await replay(rows, sessionID: nil, into: store)
            return
        }
        throw MeasurementReplayError.invalidExport
    }

    public static func replay(_ export: MeasurementExport, into store: TelemetryStore) async throws {
        try await replay(export.measurements, sessionID: export.session.sessionID, into: store)
    }

    private static func replay(
        _ rows: [PersistedMeasurement],
        sessionID: String?,
        into store: TelemetryStore
    ) async throws {
        let decoder = JSONDecoder()
        for row in rows {
            if let sessionID, row.sessionID != sessionID {
                throw MeasurementReplayError.sessionMismatch
            }
            switch row.kind {
            case "CAN":
                guard let frame = try? decoder.decode(CANFrame.self, from: Data(row.payloadJSON.utf8)) else {
                    throw MeasurementReplayError.malformedRow(row.kind)
                }
                await store.ingest(frame: frame)
            case "SIGNAL":
                guard let signal = try? decoder.decode(DecodedSignalSample.self, from: Data(row.payloadJSON.utf8)) else {
                    throw MeasurementReplayError.malformedRow(row.kind)
                }
                await store.ingest(signal: signal)
            case "DIAGNOSTIC_RESPONSE":
                guard (try? decoder.decode(OBDResponse.self, from: Data(row.payloadJSON.utf8))) != nil else {
                    throw MeasurementReplayError.malformedRow(row.kind)
                }
            case "DIAGNOSTIC_SIGNAL":
                guard let signal = try? decoder.decode(DecodedOBDSignal.self, from: Data(row.payloadJSON.utf8)) else {
                    throw MeasurementReplayError.malformedRow(row.kind)
                }
                await store.ingest(diagnostic: signal)
            case "LOCATION":
                guard let location = try? decoder.decode(LocationSample.self, from: Data(row.payloadJSON.utf8)) else {
                    throw MeasurementReplayError.malformedRow(row.kind)
                }
                await store.ingest(location: location)
            case "SYSTEM":
                continue
            default:
                throw MeasurementReplayError.unsupportedKind(row.kind)
            }
        }
    }
}
