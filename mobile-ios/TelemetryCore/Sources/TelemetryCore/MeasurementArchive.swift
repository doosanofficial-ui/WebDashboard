import Foundation
import CSQLite

public enum MeasurementArchiveError: Error, Equatable {
    case storage, sessionNotFound, sessionStillOpen, rowLimitExceeded
}

/// Read-only access to existing measurements. Never creates a session, migrates
/// a database, changes journal mode or exposes a transport/recorder reference.
public actor MeasurementArchive {
    private let db: OpaquePointer

    public init(path: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            throw MeasurementArchiveError.storage
        }
        db = connection
        sqlite3_busy_timeout(connection, 5_000)
    }

    deinit { sqlite3_close(db) }

    public func sessions(limit: Int = 100) throws -> [PersistedMeasurementSession] {
        let query = try prepare("SELECT session_id, started_at, ended_at, mode FROM measurement_sessions ORDER BY started_at DESC, session_id DESC LIMIT ?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int(query, 1, Int32(min(1_000, max(1, limit))))
        var sessions: [PersistedMeasurementSession] = []
        while true {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return sessions }
            guard result == SQLITE_ROW else { throw MeasurementArchiveError.storage }
            sessions.append(try session(from: query))
        }
    }

    public func load(sessionID: String, maximumRows: Int = 200_000) throws -> MeasurementExport {
        guard !sessionID.isEmpty, !sessionID.contains("\0") else { throw MeasurementArchiveError.sessionNotFound }
        guard (1...200_000).contains(maximumRows) else { throw MeasurementArchiveError.rowLimitExceeded }
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw MeasurementArchiveError.storage }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        let metadata = try prepare("SELECT session_id, started_at, ended_at, mode FROM measurement_sessions WHERE session_id=?")
        defer { sqlite3_finalize(metadata) }
        try bind(sessionID, to: metadata)
        let result = sqlite3_step(metadata)
        guard result != SQLITE_DONE else { throw MeasurementArchiveError.sessionNotFound }
        guard result == SQLITE_ROW else { throw MeasurementArchiveError.storage }
        let selected = try session(from: metadata)
        guard selected.endedAt != nil else { throw MeasurementArchiveError.sessionStillOpen }
        let query = try prepare("""
            SELECT sequence, session_id, kind, source_timestamp, received_at, received_monotonic, payload_json
            FROM measurements WHERE session_id=? ORDER BY sequence LIMIT ?
            """)
        defer { sqlite3_finalize(query) }
        try bind(sessionID, to: query)
        sqlite3_bind_int(query, 2, Int32(maximumRows + 1))
        var rows: [PersistedMeasurement] = []
        while true {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let id = text(query, 1), let kind = text(query, 2),
                  let payload = text(query, 6) else { throw MeasurementArchiveError.storage }
            guard rows.count < maximumRows else { throw MeasurementArchiveError.rowLimitExceeded }
            rows.append(PersistedMeasurement(sequence: sqlite3_column_int64(query, 0),
                sessionID: id, kind: kind, sourceTimestamp: sqlite3_column_double(query, 3),
                receivedAtEpoch: sqlite3_column_double(query, 4),
                receivedAtMonotonicNanos: UInt64(bitPattern: sqlite3_column_int64(query, 5)), payloadJSON: payload))
        }
        return MeasurementExport(session: selected, measurements: rows)
    }

    public func exportJSON(sessionID: String) throws -> Data {
        try JSONEncoder().encode(load(sessionID: sessionID))
    }

    public func exportCSV(sessionID: String) throws -> Data {
        MeasurementRecorder.csvData(for: try load(sessionID: sessionID).measurements)
    }

    private func session(from query: OpaquePointer) throws -> PersistedMeasurementSession {
        guard let id = text(query, 0), let modeText = text(query, 3),
              let mode = TelemetryRunMode(rawValue: modeText) else { throw MeasurementArchiveError.storage }
        return PersistedMeasurementSession(sessionID: id, startedAt: sqlite3_column_double(query, 1),
            endedAt: sqlite3_column_type(query, 2) == SQLITE_NULL ? nil : sqlite3_column_double(query, 2), mode: mode)
    }

    private func text(_ query: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(query, index).map { String(cString: $0) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else {
            throw MeasurementArchiveError.storage
        }
        return query
    }

    private func bind(_ id: String, to query: OpaquePointer) throws {
        guard sqlite3_bind_text(query, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else {
            throw MeasurementArchiveError.storage
        }
    }
}
