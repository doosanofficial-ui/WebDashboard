import Foundation
import XCTest
import CSQLite
@testable import TelemetryCore

final class MeasurementRecoveryTests: XCTestCase {
    private func database() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("measurements.sqlite")
    }

    private func execute(_ sql: String, at path: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw TelemetryError.storage
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TelemetryError.storage }
    }

    private struct SQLProbeError: Error, CustomStringConvertible {
        let description: String
        init(_ db: OpaquePointer?, stage: String, code: Int32) {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
            let extended = db.map { sqlite3_extended_errcode($0) } ?? code
            description = "SQLite probe \(stage): rc=\(code), extended=\(extended), \(message)"
        }
    }

    private func integer(_ sql: String, at path: URL, flags: Int32 = SQLITE_OPEN_READWRITE) throws -> Int64 {
        // Match recovery's read/write connection mode, but never create a file
        // during inspection. READONLY WAL setup has platform-specific sidecar
        // requirements and is not the production recovery contract.
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(path.path, &db, flags, nil)
        guard opened == SQLITE_OK, let db else {
            let error = SQLProbeError(db, stage: "open", code: opened)
            if let db { sqlite3_close(db) }
            throw error
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw SQLProbeError(db, stage: "prepare", code: prepared)
        }
        defer { sqlite3_finalize(statement) }
        let stepped = sqlite3_step(statement)
        guard stepped == SQLITE_ROW else { throw SQLProbeError(db, stage: "step", code: stepped) }
        return sqlite3_column_int64(statement, 0)
    }

    private let legacySchema = """
        CREATE TABLE measurement_sessions(session_id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL);
        CREATE TABLE measurements(sequence INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
            kind TEXT NOT NULL, source_timestamp REAL NOT NULL, received_at REAL NOT NULL,
            received_monotonic INTEGER NOT NULL, payload_json TEXT NOT NULL);
        """

    func testMissingDatabaseRecoveryDoesNotCreateAFile() throws {
        let path = try database()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        XCTAssertEqual(try MeasurementRecorder.recoverUnfinishedSessions(path: path, endedAt: 200), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testZeroLengthDatabaseDoesNotBlockFirstRecording() async throws {
        let path = try database()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try Data().write(to: path)
        // Simulate termination after opening the file but before schema creation.
        XCTAssertEqual(try MeasurementRecorder.recoverUnfinishedSessions(path: path, endedAt: 200), 0)
        let recorder = try MeasurementRecorder(path: path, sessionID: "first", startedAt: 201)
        try await recorder.append(.system(name: "MARK", timestamp: 202, monotonicNanos: 1))
        try await recorder.finish(endedAt: 203)
        let rows = try await recorder.export()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.sessionID, "first")
    }

    func testSchemaEmptySQLiteDatabaseDoesNotBlockFirstRecording() async throws {
        let path = try database()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try execute("PRAGMA journal_mode=WAL", at: path)
        XCTAssertGreaterThan(try Data(contentsOf: path).count, 0)
        // Diagnostic only: the prior macOS failure occurred in this READONLY
        // inspection before production recovery ran. Keep its exact SQL error
        // visible; the actual recovery assertions below remain mandatory.
        do {
            let count = try integer("SELECT count(*) FROM sqlite_master", at: path, flags: SQLITE_OPEN_READONLY)
            print("READONLY WAL precondition observation: schema count \(count)")
        } catch {
            print("READONLY WAL precondition observation (not a recovery verdict): \(error)")
        }
        XCTAssertEqual(try integer("SELECT count(*) FROM sqlite_master", at: path), 0)
        XCTAssertEqual(try MeasurementRecorder.recoverUnfinishedSessions(path: path, endedAt: 200), 0)
        XCTAssertEqual(try integer("SELECT count(*) FROM sqlite_master", at: path), 0,
                       "Recovery must not invent a session or measurement schema")
        let recorder = try MeasurementRecorder(path: path, sessionID: "after-empty", startedAt: 201, mode: .demo)
        let session = try await recorder.exportSession()
        XCTAssertEqual(session.mode, .demo)
        XCTAssertNil(session.endedAt)
        let count = try await recorder.count()
        XCTAssertEqual(count, 0)
    }

    func testForeignSchemaIsRejectedWithoutChangingStoredData() throws {
        let path = try database()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try execute("CREATE TABLE unrelated(value INTEGER); INSERT INTO unrelated VALUES(42)", at: path)
        XCTAssertThrowsError(try MeasurementRecorder.recoverUnfinishedSessions(path: path, endedAt: 200))
        XCTAssertEqual(try integer("SELECT value FROM unrelated", at: path), 42)
        XCTAssertEqual(try integer("SELECT count(*) FROM sqlite_master WHERE name='measurement_sessions'", at: path), 0)
    }

    func testCorruptDatabaseIsRejectedWithoutReplacingBytes() throws {
        let path = try database()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let bytes = Data(repeating: 0xEF, count: 4096)
        try bytes.write(to: path)
        XCTAssertThrowsError(try MeasurementRecorder.recoverUnfinishedSessions(path: path, endedAt: 200))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }

    func testPartiallyInitializedSessionSchemaIsNotSilentlySkipped() throws {
        let path = try database()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try execute("""
            CREATE TABLE measurement_sessions(session_id TEXT PRIMARY KEY, started_at REAL, ended_at REAL);
            INSERT INTO measurement_sessions VALUES('incomplete', 90, NULL);
            """, at: path)
        XCTAssertThrowsError(try MeasurementRecorder.recoverUnfinishedSessions(path: path, endedAt: 200))
        XCTAssertEqual(try integer("SELECT count(*) FROM measurement_sessions WHERE ended_at IS NULL", at: path), 1)
        XCTAssertEqual(try integer("SELECT count(*) FROM sqlite_master WHERE name='measurements'", at: path), 0)
    }

    func testLegacyMigrationAndRepeatedReopenPreserveRecoveredRecords() async throws {
        let path = try database()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try execute(legacySchema + """
            INSERT INTO measurement_sessions VALUES('legacy', 90, NULL);
            INSERT INTO measurements VALUES(41,'legacy','SYSTEM',100,100,1000,'{"name":"MARK"}');
            """, at: path)
        XCTAssertEqual(try MeasurementRecorder.recoverUnfinishedSessions(path: path, endedAt: 200), 1)
        let reopened = try MeasurementRecorder(path: path, sessionID: "legacy", startedAt: 90)
        let before = try await reopened.exportSessionJSON()
        let export = try JSONDecoder().decode(MeasurementExport.self, from: before)
        XCTAssertEqual(export.session.mode, .live)
        XCTAssertEqual(export.session.endedAt, 200)
        XCTAssertEqual(export.measurements.map(\.sequence), [41, 42])
        XCTAssertEqual(export.measurements[0].payloadJSON, "{\"name\":\"MARK\"}")
        XCTAssertEqual(export.measurements[0].receivedAtMonotonicNanos, 1000)
        XCTAssertTrue(export.measurements[1].payloadJSON.contains("recording_interrupted"))
        XCTAssertEqual(try MeasurementRecorder.recoverUnfinishedSessions(path: path, endedAt: 300), 0)
        let second = try MeasurementRecorder(path: path, sessionID: "legacy", startedAt: 90)
        let after = try await second.exportSessionJSON()
        XCTAssertEqual(after, before)
    }

    func testFailedRecoveryRollsBackAllSessionsAndCanRetry() throws {
        let path = try database()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try execute(legacySchema + """
            INSERT INTO measurement_sessions VALUES('first',90,NULL),('second',91,NULL);
            CREATE TRIGGER recovery_failure BEFORE INSERT ON measurements WHEN NEW.session_id='second'
            BEGIN SELECT RAISE(ABORT,'injected recovery failure'); END;
            """, at: path)
        XCTAssertThrowsError(try MeasurementRecorder.recoverUnfinishedSessions(path: path, endedAt: 200))
        XCTAssertEqual(try integer("SELECT count(*) FROM measurements", at: path), 0)
        XCTAssertEqual(try integer("SELECT count(*) FROM measurement_sessions WHERE ended_at IS NULL", at: path), 2)
        try execute("DROP TRIGGER recovery_failure", at: path)
        XCTAssertEqual(try MeasurementRecorder.recoverUnfinishedSessions(path: path, endedAt: 201), 2)
        XCTAssertEqual(try integer("SELECT count(*) FROM measurements", at: path), 2)
        XCTAssertEqual(try integer("SELECT count(*) FROM measurement_sessions WHERE ended_at=201", at: path), 2)
        XCTAssertEqual(try MeasurementRecorder.recoverUnfinishedSessions(path: path, endedAt: 202), 0)
    }
}
