import Foundation
import XCTest
@testable import TelemetryCore

final class MeasurementArchiveTests: XCTestCase {
    func testMixedSnapshotUsesLastRawOrDiagnosticRowNotAnOlderResponse() async throws {
        let (path, recorder) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let response = OBDResponse(receivedAtEpoch: 101, receivedAtMonotonicNanos: 10,
            responseCANID: 0x7EC, isExtended: false, service: .service22, command: "0101",
            payload: [0, 0, 0, 0, 97], sequence: 1, sourceAdapter: "fixture", sourceTransport: "fixture")
        let raw = try CANFrame(receivedAtEpoch: 102, receivedAtMonotonicNanos: 11,
            canID: 0x123, isExtended: false, dlc: 1, payload: [7],
            sourceAdapter: "fixture", sourceTransport: "fixture", sequence: 2)
        try await recorder.append(contentsOf: [.diagnosticResponse(response), .can(frame: raw)])
        try await recorder.finish(endedAt: 103)
        let archive = try MeasurementArchive(path: path)
        let saved = try await archive.load(sessionID: "saved")
        let snapshot = try await MeasurementReplay.snapshot(saved)
        XCTAssertEqual(snapshot.frame?.canID, 0x123)
        XCTAssertNil(snapshot.diagnostic, "Older diagnostic response must not be presented as current raw CAN")
    }

    private func fixture() throws -> (URL, MeasurementRecorder) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = root.appendingPathComponent("measurements.sqlite3")
        return (path, try MeasurementRecorder(path: path, sessionID: "saved", startedAt: 100))
    }

    func testClosedSessionRemainsExportableWithoutOriginalRecorder() async throws {
        let (path, recorder) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try await recorder.append(.system(name: "MARK", timestamp: 101, monotonicNanos: 10))
        try await recorder.finish(endedAt: 102)
        let archive = try MeasurementArchive(path: path)
        let sessions = try await archive.sessions()
        XCTAssertEqual(sessions.map(\.sessionID), ["saved"])
        let saved = try await archive.load(sessionID: "saved")
        XCTAssertEqual(saved.session.endedAt, 102)
        XCTAssertEqual(saved.measurements.count, 1)
        let original = try await recorder.exportCSV()
        XCTAssertEqual(MeasurementRecorder.csvData(for: saved.measurements), original)
        let count = try await recorder.count()
        XCTAssertEqual(count, 1)
    }

    func testMissingDatabaseIsNotCreatedAndUnknownIDCannotCreateSession() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try MeasurementArchive(path: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let (path, recorder) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try await recorder.finish(endedAt: 101)
        let archive = try MeasurementArchive(path: path)
        do { _ = try await archive.load(sessionID: "does-not-exist"); XCTFail("Unknown session must not be created") }
        catch { XCTAssertEqual(error as? MeasurementArchiveError, .sessionNotFound) }
        do { _ = try await archive.load(sessionID: "saved\0suffix"); XCTFail("Do not load an ID prefix") }
        catch { XCTAssertEqual(error as? MeasurementArchiveError, .sessionNotFound) }
        let sessions = try await archive.sessions()
        XCTAssertEqual(sessions.count, 1)
    }

    func testOpenSessionCannotBeLoadedAsStableReplayAndRowsAreBounded() async throws {
        let (path, recorder) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let archive = try MeasurementArchive(path: path)
        do { _ = try await archive.load(sessionID: "saved"); XCTFail("Open session is not a closed replay snapshot") }
        catch { XCTAssertEqual(error as? MeasurementArchiveError, .sessionStillOpen) }
        try await recorder.append(.system(name: "MARK", timestamp: 101, monotonicNanos: 10))
        try await recorder.append(.system(name: "MARK", timestamp: 102, monotonicNanos: 20))
        try await recorder.finish(endedAt: 103)
        do { _ = try await archive.load(sessionID: "saved", maximumRows: 1); XCTFail("Do not silently truncate") }
        catch { XCTAssertEqual(error as? MeasurementArchiveError, .rowLimitExceeded) }
    }

    func testArchiveCSVReplayPreservesRealCaptureScalarAndOriginalTimes() async throws {
        let (path, recorder) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let response = OBDResponse(receivedAtEpoch: 101, receivedAtMonotonicNanos: 10,
            responseCANID: 0x7EC, isExtended: false, service: .service22, command: "0101",
            payload: [143, 243, 255, 239, 97], sequence: 1,
            sourceAdapter: "captured-response-fixture", sourceTransport: "fixture")
        let signal = try OBDSignalDecoder.decode(query.signals[0], response: response)
        try await recorder.append(contentsOf: [.diagnosticResponse(response), .diagnosticSignal(signal)])
        try await recorder.finish(endedAt: 102)
        let archive = try MeasurementArchive(path: path)
        let export = try await archive.load(sessionID: "saved")
        let store = TelemetryStore()
        try await MeasurementReplay.replay(export, into: store)
        let replay = await store.signalState(for: query.signals[0].id, now: 102)
        XCTAssertEqual(replay?.value, 48.5)
        XCTAssertEqual(replay?.receivedAtEpoch, 101)
        XCTAssertEqual(replay?.receivedAtMonotonicNanos, 10)
        let snapshot = try await MeasurementReplay.snapshot(export)
        XCTAssertEqual(snapshot.timestamp, 101)
        XCTAssertEqual(snapshot.signals.first?.value, 48.5)
        XCTAssertEqual(snapshot.diagnostic?.receivedAtEpoch, 101)
        let rows = try await recorder.count()
        XCTAssertEqual(rows, 2, "Replay must not append to the recording")
    }
}
