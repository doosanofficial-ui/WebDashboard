import Foundation
import CSQLite

public actor DurableOutbox {
    private let db: OpaquePointer
    private let capacity: Int
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL, capacity: Int = 50_000) throws {
        guard capacity > 0 else { throw TelemetryError.queueFull }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open(path.path, &connection) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw TelemetryError.storage
        }
        self.db = connection
        self.capacity = capacity
        sqlite3_busy_timeout(connection, 5_000)
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS outbox (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          event_id TEXT NOT NULL UNIQUE,
          payload TEXT NOT NULL
        );
        """
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw TelemetryError.storage
        }
    }

    deinit { sqlite3_close(db) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TelemetryError.storage }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else {
            throw TelemetryError.storage
        }
        return result
    }

    private func bind(_ text: String, to statement: OpaquePointer, index: Int32) throws {
        let result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
        guard result == SQLITE_OK else { throw TelemetryError.storage }
    }

    private func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func count() throws -> Int {
        let query = try statement("SELECT count(*) FROM outbox")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw TelemetryError.storage }
        return Int(sqlite3_column_int64(query, 0))
    }

    public func enqueue(_ event: TelemetryEvent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(event)
        guard let payload = String(data: encoded, encoding: .utf8) else { throw TelemetryError.storage }
        try transaction {
            let existing = try statement("SELECT payload FROM outbox WHERE event_id=?")
            defer { sqlite3_finalize(existing) }
            try bind(event.id, to: existing, index: 1)
            let existingResult = sqlite3_step(existing)
            if existingResult == SQLITE_ROW {
                guard String(cString: sqlite3_column_text(existing, 0)) == payload else { throw TelemetryError.eventConflict }
                return
            }
            guard existingResult == SQLITE_DONE else { throw TelemetryError.storage }
            guard try count() < capacity else { throw TelemetryError.queueFull }
            let insert = try statement("INSERT INTO outbox(event_id, payload) VALUES (?, ?)")
            defer { sqlite3_finalize(insert) }
            try bind(event.id, to: insert, index: 1)
            try bind(payload, to: insert, index: 2)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw TelemetryError.storage }
        }
    }

    public func pending(limit: Int = 200) throws -> [TelemetryEvent] {
        guard (1...200).contains(limit) else { throw TelemetryError.invalidBatch }
        let query = try statement("SELECT payload FROM outbox ORDER BY sequence LIMIT ?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int(query, 1, Int32(limit))
        var events: [TelemetryEvent] = []
        while true {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return events }
            guard result == SQLITE_ROW else { throw TelemetryError.storage }
            let payload = String(cString: sqlite3_column_text(query, 0))
            events.append(try JSONDecoder().decode(TelemetryEvent.self, from: Data(payload.utf8)))
        }
    }

    public func acknowledge(_ ack: Acknowledgement, for batch: UploadBatch) throws {
        let sent = Set(batch.events.map(\.id))
        guard ack.version == 2, ack.clientID == batch.clientID,
              ack.acked.count <= batch.events.count,
              Set(ack.acked).isSubset(of: sent) else { throw TelemetryError.invalidAcknowledgement }
        try transaction {
            let deletion = try statement("DELETE FROM outbox WHERE event_id=?")
            defer { sqlite3_finalize(deletion) }
            for id in Set(ack.acked) {
                sqlite3_reset(deletion)
                sqlite3_clear_bindings(deletion)
                try bind(id, to: deletion, index: 1)
                guard sqlite3_step(deletion) == SQLITE_DONE else { throw TelemetryError.storage }
            }
        }
    }
}
