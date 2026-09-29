import Foundation
import XCTest
import CSQLite
@testable import TelemetryCore

final class MeasurementRecorderLifecycleTests: XCTestCase {
    private func database() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recorder-lifecycle-\(UUID().uuidString)/measurements.sqlite")
    }
    private func event(_ name: String = "sample") -> MeasurementEvent {
        .system(name: name, timestamp: 100, monotonicNanos: 1000)
    }
    private func execute(_ sql: String, at path: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK, let db else { throw TelemetryError.storage }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TelemetryError.storage }
    }

    func testAppendAfterFinishIsRejectedAndExportUnchanged() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        try await recorder.append(event())
        try await recorder.finish(endedAt: 101)
        let before = try await recorder.export()
        do { try await recorder.append(event("late")); XCTFail("Closed session accepted a late event") }
        catch { XCTAssertEqual(error as? TelemetryError, .eventConflict) }
        let after = try await recorder.export()
        XCTAssertEqual(after, before)
    }

    func testFinishIsIdempotentAndKeepsFirstEndTime() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        try await recorder.finish(endedAt: 101)
        try await recorder.finish(endedAt: 999)
        let session = try await recorder.exportSession()
        XCTAssertEqual(session.endedAt, 101)
    }

    func testSecondRecorderCannotAppendToClosedSession() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let first = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        let second = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        try await first.finish(endedAt: 101)
        do { try await second.append(event()); XCTFail("Other connection ignored persisted end marker") }
        catch { XCTAssertEqual(error as? TelemetryError, .eventConflict) }
        let count = try await first.count()
        XCTAssertEqual(count, 0)
    }

    func testReopeningFinishedSessionAllowsReadButNotMutation() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let first = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        try await first.append(event())
        try await first.finish(endedAt: 101)
        let reopened = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        let count = try await reopened.count()
        XCTAssertEqual(count, 1)
        do { try await reopened.append(event()); XCTFail("Reopen allowed writes after Stop") }
        catch { XCTAssertEqual(error as? TelemetryError, .eventConflict) }
    }

    func testSameIDCannotSilentlyReuseDifferentStartTimeOrMode() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let original = try MeasurementRecorder(path: path, sessionID: "same", startedAt: 90, mode: .demo)
        XCTAssertThrowsError(try MeasurementRecorder(path: path, sessionID: "same", startedAt: 91, mode: .demo))
        XCTAssertThrowsError(try MeasurementRecorder(path: path, sessionID: "same", startedAt: 90, mode: .live))
        let session = try await original.exportSession()
        XCTAssertEqual(session.startedAt, 90)
        XCTAssertEqual(session.mode, .demo)
    }

    func testNULInSessionIDCannotAliasAnotherSession() throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        XCTAssertThrowsError(try MeasurementRecorder(path: path, sessionID: "s\0different", startedAt: 90))
    }

    func testRecoveryClosesExistingWriterAsWellAsSessionMetadata() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        try await recorder.append(event())
        XCTAssertEqual(try MeasurementRecorder.recoverUnfinishedSessions(path: path, endedAt: 101), 1)
        do { try await recorder.append(event("late")); XCTFail("Recovered session remained writable") }
        catch { XCTAssertEqual(error as? TelemetryError, .eventConflict) }
        let rows = try await recorder.export()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.last?.payloadJSON.contains("recording_interrupted") == true)
    }

    func testCorruptStoredModeMustNotBeReportedAsLive() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        try execute("UPDATE measurement_sessions SET mode='BROKEN'", at: path)
        do { _ = try await recorder.exportSession(); XCTFail("Invalid mode silently became LIVE") }
        catch { XCTAssertEqual(error as? TelemetryError, .storage) }
    }
    func testStopMarkerAndEndTimeRollbackTogetherOnSQLFailure() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        try await recorder.append(event())
        try execute("CREATE TRIGGER fail_end BEFORE UPDATE OF ended_at ON measurement_sessions BEGIN SELECT RAISE(ABORT, 'injected'); END", at: path)
        do {
            try await recorder.finish(endedAt: 101, terminalEvent: .system(name: "recording_stopped", timestamp: 101, monotonicNanos: 2000))
            XCTFail("Injected SQL failure was ignored")
        } catch { XCTAssertEqual(error as? TelemetryError, .storage) }
        let rows = try await recorder.export()
        let session = try await recorder.exportSession()
        XCTAssertEqual(rows.count, 1, "No successful-stop marker may survive a failed close")
        XCTAssertNil(session.endedAt)
    }

    func testRepeatedTerminalCloseStoresExactlyOneMarker() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        let stopped = MeasurementEvent.system(name: "recording_stopped", timestamp: 101, monotonicNanos: 2000)
        try await recorder.finish(endedAt: 101, terminalEvent: stopped)
        try await recorder.finish(endedAt: 101, terminalEvent: stopped)
        let rows = try await recorder.export()
        XCTAssertEqual(rows.count, 1)
    }

    func testMismatchedTerminalTimestampIsRejectedBeforeMutation() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        do {
            try await recorder.finish(endedAt: 101, terminalEvent: .system(name: "recording_stopped", timestamp: 100, monotonicNanos: 2000))
            XCTFail("Mismatched stop time was accepted")
        } catch { XCTAssertEqual(error as? TelemetryError, .invalidBatch) }
        let rows = try await recorder.export()
        let session = try await recorder.exportSession()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertNil(session.endedAt)
    }

    func testEventBatchIsAtomicWhenOneEventIsInvalid() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        do {
            try await recorder.append(contentsOf: [event("raw"), event("")])
            XCTFail("Invalid event was accepted")
        } catch { XCTAssertEqual(error as? TelemetryError, .invalidBatch) }
        let rows = try await recorder.export()
        XCTAssertTrue(rows.isEmpty, "A rejected batch cannot be partially persisted")
    }
}
