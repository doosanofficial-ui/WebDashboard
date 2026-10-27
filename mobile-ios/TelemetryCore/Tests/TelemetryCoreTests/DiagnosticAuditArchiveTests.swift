import Foundation
import XCTest
@testable import TelemetryCore

final class DiagnosticAuditArchiveTests: XCTestCase {
    func testVersionedAuditAndSelectionSurviveReopenAndUnchangedExports() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("audit-archive-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("fixture.sqlite")
        let queries = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let profile = try AdapterProfile(id: "fixture", name: "Synthetic fixture", transport: .wifi,
            peripheralID: nil, serviceUUID: nil, writeCharacteristicUUID: nil, notifyCharacteristicUUID: nil,
            host: "127.0.0.1", port: 35000, signals: [], diagnosticQueries: queries)
        let selection = try SignalAcquisitionSelectionChange(previousPolicy: nil, selectedQueryIDs: [],
            profile: profile, localContextID: "synthetic-local", profileRevision: "fixture-revision")
        let context = try DiagnosticAuditContext(adapterProfileID: profile.id, adapterProfileName: profile.name,
            transport: "fixture", connectionID: UUID())
        var ledger = DiagnosticAuditLedger(scope: .recordingWindow(recordingID: UUID()))
        let queued = try ledger.queued(query: queries[0], context: context,
            at: .init(epochSeconds: 100, monotonicNanoseconds: 1_000_000_000))
        let terminals = try ledger.closeRecordingWindow(at: .init(epochSeconds: 101, monotonicNanoseconds: 2_000_000_000))
        let terminal = try XCTUnwrap(terminals.first)
        do {
            let recorder = try MeasurementRecorder(path: path, sessionID: "fixture", startedAt: 99)
            try await recorder.append(.system(name: "legacy-marker", timestamp: 99, monotonicNanos: 0))
            try await recorder.append(.diagnosticAudit(queued))
            try await recorder.append(.diagnosticAudit(terminal))
            try await recorder.append(.diagnosticSelection(selection, timestamp: 102, monotonicNanos: 3_000_000_000))
            try await recorder.finish(endedAt: 103)
        }
        let reopened = try MeasurementRecorder(path: path, sessionID: "fixture", startedAt: 99)
        let rows = try await reopened.export()
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.kind == "SYSTEM" })
        let encoded = try await reopened.exportSessionJSON()
        let archive = try JSONDecoder().decode(MeasurementExport.self, from: encoded)
        XCTAssertEqual(archive.schemaVersion, 1, "Additive payloads do not migrate the SQLite/archive schema")
        XCTAssertEqual(archive.measurements, rows)
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticAuditSystemPayload.self, from: Data(rows[1].payloadJSON.utf8)).diagnosticAudit, queued)
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticAuditSystemPayload.self, from: Data(rows[2].payloadJSON.utf8)).diagnosticAudit, terminal)
        struct LegacyNameOnly: Decodable { let name: String }
        let names = try rows.map { try JSONDecoder().decode(LegacyNameOnly.self, from: Data($0.payloadJSON.utf8)).name }
        XCTAssertEqual(names, ["legacy-marker", "diagnostic_audit_v1", "diagnostic_audit_v1", "diagnostic_query_selection_changed_v1"])
        let policy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rows[3].payloadJSON.utf8)) as? [String: Any])
        XCTAssertEqual(policy["selectedQueryIDs"] as? [String], [])
        XCTAssertEqual(policy["previousQueryIDs"] as? [String], queries.map(\.id))
        XCTAssertEqual(policy["localContextID"] as? String, "synthetic-local")
        let csv = String(decoding: try await reopened.exportCSV(), as: UTF8.self)
        for row in rows {
            XCTAssertTrue(csv.contains("\"" + row.payloadJSON.replacingOccurrences(of: "\"", with: "\"\"") + "\""))
        }
        let timeline = try await MeasurementReplay.timeline(archive)
        let earlier = try timeline.systemHistory(at: 1.5)
        XCTAssertEqual(earlier.samples.map(\.sequence), [1, 2])
        XCTAssertFalse(earlier.samples.contains { $0.payloadJSON == rows[2].payloadJSON })
        let later = try timeline.systemHistory(at: 3)
        XCTAssertEqual(later.samples, rows)
    }
}
