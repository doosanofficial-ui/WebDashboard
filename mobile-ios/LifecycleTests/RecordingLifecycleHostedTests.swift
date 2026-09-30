import Foundation
import SQLite3
import XCTest
import TelemetryCore
@testable import TelemetryLifecycleHost

/// Full production App sources + real queue/SQLite, hosted in a distinct iOS
/// Simulator app. These are not touch/UI tests or vehicle/GPS qualification.
final class RecordingLifecycleHostedTests: XCTestCase {
    private enum FixtureError: Error { case unsafeHost, busy, missingExport, closeTimeout, sqlite }
    private struct SystemPayload: Decodable { let name: String }

    @MainActor
    private func withModel(_ body: (TelemetryModel) async throws -> Void) async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Lifecycle fault injection is Simulator-only")
        #else
        guard Bundle.main.bundleIdentifier == "local.webdashboard.Telemetry.LifecycleHost" else {
            throw FixtureError.unsafeHost
        }
        let model = TelemetryModel.shared
        // Never repurpose a user's configured connection or active session.
        guard model.serverText.isEmpty, !model.credentialSaved,
              !model.collecting, model.connection == "Disconnected",
              !model.localRecordingEnabled,
              model.localRecordingStatus != "Closing local recording" else { throw FixtureError.busy }
        XCTAssertNil(model.storageStatus)
        do {
            try await body(model)
            model.stopRecording()
            try await waitForClose(model)
        } catch {
            model.stopRecording()
            try? await waitForClose(model)
            throw error
        }
        #endif
    }

    @MainActor
    private func waitForClose(_ model: TelemetryModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.localRecordingStatus != "Recording off"
            && model.localRecordingStatus != "Recording failed; retained data is available for export" {
            guard ContinuousClock.now < deadline else { throw FixtureError.closeTimeout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(model.localRecordingEnabled)
    }

    @MainActor
    private func exported(_ model: TelemetryModel) async throws -> MeasurementExport {
        guard let data = await model.exportMeasurementJSON() else { throw FixtureError.missingExport }
        return try JSONDecoder().decode(MeasurementExport.self, from: data)
    }

    private func names(_ export: MeasurementExport) throws -> [String] {
        try export.measurements.map {
            XCTAssertEqual($0.kind, "SYSTEM")
            return try JSONDecoder().decode(SystemPayload.self, from: Data($0.payloadJSON.utf8)).name
        }
    }

    private func assertClosed(_ export: MeasurementExport, marks: Int) throws {
        XCTAssertNotNil(export.session.endedAt)
        XCTAssertEqual(export.session.mode, .live)
        XCTAssertEqual(try names(export), ["recording_started"] + Array(repeating: "MARK", count: marks) + ["recording_stopped"])
        XCTAssertTrue(export.measurements.allSatisfy { $0.sessionID == export.session.sessionID })
        XCTAssertEqual(Set(export.measurements.map(\.sequence)).count, export.measurements.count)
        XCTAssertEqual(export.measurements.map(\.sequence), export.measurements.map(\.sequence).sorted())
        XCTAssertEqual(export.measurements.last?.sourceTimestamp, export.session.endedAt)
    }

    @MainActor
    func testImmediateStopExportDrainsAllAcceptedMarks() async throws {
        try await withModel { model in
            model.startRecording()
            XCTAssertTrue(model.localRecordingEnabled)
            for _ in 0..<40 { model.mark() }
            model.stopRecording()
            // Deliberately no sleep/wait between Stop and the public export API.
            let export = try await exported(model)
            try assertClosed(export, marks: 40)
        }
    }

    @MainActor
    func testRepeatedStopAndLateAdmissionDoNotAppendOrMoveEndTime() async throws {
        try await withModel { model in
            model.startRecording()
            model.mark()
            model.stopRecording()
            for _ in 0..<10 { model.mark(); model.stopRecording(); model.finishLocalMeasurement() }
            let first = try await exported(model)
            try assertClosed(first, marks: 1)
            try await waitForClose(model)
            model.stopRecording()
            model.mark()
            let second = try await exported(model)
            XCTAssertEqual(second, first)
        }
    }

    @MainActor
    func testExportWhileRecordingCapturesAcceptedBoundaryWithoutClosing() async throws {
        try await withModel { model in
            model.startRecording()
            for _ in 0..<12 { model.mark() }
            let active = try await exported(model)
            XCTAssertNil(active.session.endedAt)
            XCTAssertEqual(try names(active), ["recording_started"] + Array(repeating: "MARK", count: 12))
            XCTAssertTrue(model.localRecordingEnabled)
            for _ in 0..<7 { model.mark() }
            model.stopRecording()
            let closed = try await exported(model)
            try assertClosed(closed, marks: 19)
            XCTAssertEqual(closed.session.sessionID, active.session.sessionID)
            XCTAssertEqual(Array(closed.measurements.prefix(active.measurements.count)), active.measurements)
        }
    }

    @MainActor
    func testRestartDuringCloseIsRejectedThenNewSessionRemainsIsolated() async throws {
        try await withModel { model in
            model.startRecording()
            for _ in 0..<80 { model.mark() }
            model.stopRecording()
            model.startRecording() // same actor turn: closing admission must win
            XCTAssertFalse(model.localRecordingEnabled)
            let first = try await exported(model)
            try assertClosed(first, marks: 80)
            try await waitForClose(model)
            model.startRecording()
            XCTAssertTrue(model.localRecordingEnabled)
            model.mark()
            let active = try await exported(model)
            XCTAssertNotEqual(active.session.sessionID, first.session.sessionID)
            XCTAssertNil(active.session.endedAt)
            XCTAssertTrue(model.localRecordingEnabled, "Old completion callbacks cannot disable the new session")
            model.stopRecording()
            let second = try await exported(model)
            try assertClosed(second, marks: 1)
            XCTAssertNotEqual(second.session.sessionID, first.session.sessionID)
            let oldRecorder = try MeasurementRecorder(path: measurementPath(), sessionID: first.session.sessionID,
                startedAt: first.session.startedAt, mode: first.session.mode)
            let oldData = try await oldRecorder.exportSessionJSON()
            XCTAssertEqual(try JSONDecoder().decode(MeasurementExport.self, from: oldData), first)
        }
    }

    @MainActor
    func testDemoSwitchCannotRelabelAnActiveOrClosingLiveSession() async throws {
        try await withModel { model in
            XCTAssertEqual(model.runMode, .live)
            model.startRecording()
            model.startDemoAdapter()
            XCTAssertEqual(model.runMode, .live)
            XCTAssertTrue(model.localRecordingEnabled)
            model.mark()
            model.stopRecording()
            model.startDemoAdapter()
            XCTAssertEqual(model.runMode, .live)
            let export = try await exported(model)
            try assertClosed(export, marks: 1)
        }
    }

    @MainActor
    func testCSVAfterImmediateStopMatchesClosedJSONRows() async throws {
        try await withModel { model in
            model.startRecording()
            for _ in 0..<15 { model.mark() }
            model.stopRecording()
            guard let data = await model.exportMeasurementCSV() else { throw FixtureError.missingExport }
            let export = try await exported(model)
            try assertClosed(export, marks: 15)
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            XCTAssertEqual(lines.count, export.measurements.count + 1)
            XCTAssertEqual(String(lines[0]), "sequence,session_id,kind,source_timestamp,received_at,received_monotonic,payload_json")
            // These fixture SYSTEM payloads contain no comma/newline. Parse the
            // first six CSV cells, then compare the independently escaped JSON.
            for (line, row) in zip(lines.dropFirst(), export.measurements) {
                let cells = line.split(separator: ",", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
                XCTAssertEqual(cells.count, 7)
                guard cells.count == 7 else { continue }
                XCTAssertEqual(Int64(cells[0]), row.sequence)
                XCTAssertEqual(cells[1], row.sessionID)
                XCTAssertEqual(cells[2], row.kind)
                XCTAssertEqual(Double(cells[3]), row.sourceTimestamp)
                XCTAssertEqual(Double(cells[4]), row.receivedAtEpoch)
                XCTAssertEqual(UInt64(cells[5]), row.receivedAtMonotonicNanos)
                XCTAssertEqual(cells[6], "\"" + row.payloadJSON.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
            }
        }
    }

    @MainActor
    func testRealSQLiteWriteFailureStaysVisibleAndNextSessionRecovers() async throws {
        try await withModel { model in
            model.startRecording()
            model.mark()
            let active = try await exported(model) // a real committed prefix
            let trigger = "lifecycle_failure_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let id = active.session.sessionID.replacingOccurrences(of: "'", with: "''")
            try sql("""
                CREATE TRIGGER \(trigger) BEFORE INSERT ON measurements
                WHEN NEW.session_id = '\(id)' AND NEW.kind = 'SYSTEM'
                  AND NEW.payload_json = '{"name":"MARK"}'
                BEGIN SELECT RAISE(ABORT, 'injected lifecycle write failure'); END;
                """)
            defer { try? sql("DROP TRIGGER IF EXISTS \(trigger)") }
            model.mark()
            model.stopRecording()
            try await waitForClose(model)
            XCTAssertTrue(model.localRecordingStatus.hasPrefix("Recording failed"))
            let failed = try await exported(model)
            XCTAssertEqual(try names(failed), ["recording_started", "MARK", "recording_failed"])
            XCTAssertNotNil(failed.session.endedAt)
            XCTAssertEqual(Array(failed.measurements.prefix(active.measurements.count)), active.measurements)
            try sql("DROP TRIGGER \(trigger)")
            model.startRecording()
            model.mark()
            let restarted = try await exported(model)
            XCTAssertTrue(model.localRecordingEnabled)
            XCTAssertNotEqual(restarted.session.sessionID, failed.session.sessionID)
            model.stopRecording()
            let closed = try await exported(model)
            try assertClosed(closed, marks: 1)
        }
    }

    private func measurementPath() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Telemetry/measurements.sqlite3")
    }

    private func sql(_ statement: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(try measurementPath().path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
    }
}
