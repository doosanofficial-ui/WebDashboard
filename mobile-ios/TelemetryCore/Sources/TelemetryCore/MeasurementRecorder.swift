import Foundation
import CSQLite

public struct PersistedMeasurement: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let sessionID: String
    public let kind: String
    public let sourceTimestamp: Double
    public let receivedAtEpoch: Double
    public let receivedAtMonotonicNanos: UInt64
    public let payloadJSON: String

    public init(
        sequence: Int64,
        sessionID: String,
        kind: String,
        sourceTimestamp: Double,
        receivedAtEpoch: Double,
        receivedAtMonotonicNanos: UInt64,
        payloadJSON: String
    ) {
        self.sequence = sequence
        self.sessionID = sessionID
        self.kind = kind
        self.sourceTimestamp = sourceTimestamp
        self.receivedAtEpoch = receivedAtEpoch
        self.receivedAtMonotonicNanos = receivedAtMonotonicNanos
        self.payloadJSON = payloadJSON
    }
}

public actor MeasurementRecorder {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let db: OpaquePointer
    private let sessionID: String

    public init(path: URL, sessionID: String, startedAt: Double) throws {
        guard !sessionID.isEmpty, startedAt.isFinite else { throw TelemetryError.invalidBatch }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var connection: OpaquePointer?
        guard sqlite3_open(path.path, &connection) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw TelemetryError.storage
        }
        db = connection
        self.sessionID = sessionID
        sqlite3_busy_timeout(connection, 5_000)
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS measurement_sessions (
          session_id TEXT PRIMARY KEY,
          started_at REAL NOT NULL,
          ended_at REAL
        );
        CREATE TABLE IF NOT EXISTS measurements (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          source_timestamp REAL NOT NULL,
          received_at REAL NOT NULL,
          received_monotonic INTEGER NOT NULL,
          payload_json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS measurements_session_sequence
          ON measurements(session_id, sequence);
        """
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw TelemetryError.storage
        }
        let insert = try Self.prepare(connection, "INSERT OR IGNORE INTO measurement_sessions(session_id, started_at) VALUES (?, ?)")
        defer { sqlite3_finalize(insert) }
        try Self.bind(sessionID, to: insert, index: 1)
        sqlite3_bind_double(insert, 2, startedAt)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw TelemetryError.storage }
    }

    deinit { sqlite3_close(db) }

    public func append(_ event: MeasurementEvent) throws {
        let row = try encode(event)
        try transaction {
            let insert = try Self.prepare(db, """
                INSERT INTO measurements(
                  session_id, kind, source_timestamp, received_at,
                  received_monotonic, payload_json
                ) VALUES (?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(insert) }
            try Self.bind(sessionID, to: insert, index: 1)
            try Self.bind(row.kind, to: insert, index: 2)
            sqlite3_bind_double(insert, 3, row.sourceTimestamp)
            sqlite3_bind_double(insert, 4, row.receivedAtEpoch)
            sqlite3_bind_int64(insert, 5, Int64(bitPattern: row.receivedAtMonotonicNanos))
            try Self.bind(row.payloadJSON, to: insert, index: 6)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw TelemetryError.storage }
        }
    }

    public func finish(endedAt: Double) throws {
        guard endedAt.isFinite else { throw TelemetryError.invalidBatch }
        let update = try Self.prepare(db, "UPDATE measurement_sessions SET ended_at=? WHERE session_id=?")
        defer { sqlite3_finalize(update) }
        sqlite3_bind_double(update, 1, endedAt)
        try Self.bind(sessionID, to: update, index: 2)
        guard sqlite3_step(update) == SQLITE_DONE else { throw TelemetryError.storage }
    }

    public func count() throws -> Int {
        let query = try Self.prepare(db, "SELECT count(*) FROM measurements WHERE session_id=?")
        defer { sqlite3_finalize(query) }
        try Self.bind(sessionID, to: query, index: 1)
        guard sqlite3_step(query) == SQLITE_ROW else { throw TelemetryError.storage }
        return Int(sqlite3_column_int64(query, 0))
    }

    public func export() throws -> [PersistedMeasurement] {
        let query = try Self.prepare(db, """
            SELECT sequence, session_id, kind, source_timestamp, received_at,
                   received_monotonic, payload_json
            FROM measurements WHERE session_id=? ORDER BY sequence
            """)
        defer { sqlite3_finalize(query) }
        try Self.bind(sessionID, to: query, index: 1)
        var rows: [PersistedMeasurement] = []
        while true {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW,
                  let sessionText = sqlite3_column_text(query, 1),
                  let kindText = sqlite3_column_text(query, 2),
                  let payloadText = sqlite3_column_text(query, 6) else {
                throw TelemetryError.storage
            }
            rows.append(PersistedMeasurement(
                sequence: sqlite3_column_int64(query, 0),
                sessionID: String(cString: sessionText),
                kind: String(cString: kindText),
                sourceTimestamp: sqlite3_column_double(query, 3),
                receivedAtEpoch: sqlite3_column_double(query, 4),
                receivedAtMonotonicNanos: UInt64(bitPattern: sqlite3_column_int64(query, 5)),
                payloadJSON: String(cString: payloadText)
            ))
        }
    }

    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(export())
    }

    private struct EncodedRow {
        let kind: String
        let sourceTimestamp: Double
        let receivedAtEpoch: Double
        let receivedAtMonotonicNanos: UInt64
        let payloadJSON: String
    }

    private func encode(_ event: MeasurementEvent) throws -> EncodedRow {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch event {
        case .can(let frame):
            return try EncodedRow(
                kind: "CAN",
                sourceTimestamp: frame.receivedAtEpoch,
                receivedAtEpoch: frame.receivedAtEpoch,
                receivedAtMonotonicNanos: frame.receivedAtMonotonicNanos,
                payloadJSON: String(decoding: encoder.encode(frame), as: UTF8.self)
            )
        case .signal(let sample):
            guard sample.receivedAtEpoch.isFinite, sample.value.isFinite else {
                throw TelemetryError.invalidBatch
            }
            return try EncodedRow(
                kind: "SIGNAL",
                sourceTimestamp: sample.receivedAtEpoch,
                receivedAtEpoch: sample.receivedAtEpoch,
                receivedAtMonotonicNanos: sample.receivedAtMonotonicNanos,
                payloadJSON: String(decoding: encoder.encode(sample), as: UTF8.self)
            )
        case .location(let sample):
            guard sample.originalTimestamp.isFinite, sample.receivedAtEpoch.isFinite else {
                throw TelemetryError.invalidBatch
            }
            return try EncodedRow(
                kind: "LOCATION",
                sourceTimestamp: sample.originalTimestamp,
                receivedAtEpoch: sample.receivedAtEpoch,
                receivedAtMonotonicNanos: sample.receivedAtMonotonicNanos,
                payloadJSON: String(decoding: encoder.encode(sample), as: UTF8.self)
            )
        case .system(let name, let timestamp, let monotonicNanos):
            guard timestamp.isFinite, !name.isEmpty else { throw TelemetryError.invalidBatch }
            struct SystemPayload: Codable { let name: String }
            return try EncodedRow(
                kind: "SYSTEM",
                sourceTimestamp: timestamp,
                receivedAtEpoch: timestamp,
                receivedAtMonotonicNanos: monotonicNanos,
                payloadJSON: String(decoding: encoder.encode(SystemPayload(name: name)), as: UTF8.self)
            )
        }
    }

    private func transaction(_ work: () throws -> Void) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw TelemetryError.storage
        }
        do {
            try work()
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw TelemetryError.storage
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw TelemetryError.storage }
        return statement
    }

    private static func bind(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        guard result == SQLITE_OK else { throw TelemetryError.storage }
    }
}
