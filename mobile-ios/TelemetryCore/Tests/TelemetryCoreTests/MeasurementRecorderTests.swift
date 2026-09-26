import Foundation
import XCTest
@testable import TelemetryCore

final class MeasurementRecorderTests: XCTestCase {
    private func frame() throws -> CANFrame {
        try CANFrame(
            receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 1_000,
            canID: 0x123,
            isExtended: false,
            dlc: 2,
            payload: [0x34, 0x12],
            sourceAdapter: "mock",
            sourceTransport: "test",
            sequence: 7
        )
    }

    func testOrderedEventsSurviveReopenAndJSONExport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("measurement-recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.sqlite")
        let sessionID = "session-1"

        do {
            let recorder = try MeasurementRecorder(path: path, sessionID: sessionID, startedAt: 90)
            try await recorder.append(.system(name: "monitoring_started", timestamp: 90, monotonicNanos: 900))
            try await recorder.append(.can(frame: frame()))
            try await recorder.append(.signal(DecodedSignalSample(
                signalID: "vehicle.speed", value: 42, rawValue: 42, enumName: nil,
                unit: "km/h", frameSequence: 7, receivedAtEpoch: 100,
                receivedAtMonotonicNanos: 1_000
            )))
            try await recorder.finish(endedAt: 101)
        }

        let reopened = try MeasurementRecorder(path: path, sessionID: sessionID, startedAt: 90)
        let rows = try await reopened.export()
        XCTAssertEqual(rows.map(\.kind), ["SYSTEM", "CAN", "SIGNAL"])
        XCTAssertEqual(rows.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(rows[1].sourceTimestamp, 100)
        XCTAssertEqual(rows[1].receivedAtEpoch, 100)

        let json = try await reopened.exportJSON()
        let decoded = try JSONDecoder().decode([PersistedMeasurement].self, from: json)
        XCTAssertEqual(decoded, rows)

        let envelope = try JSONDecoder().decode(MeasurementExport.self, from: await reopened.exportSessionJSON())
        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.session.sessionID, sessionID)
        XCTAssertEqual(envelope.session.startedAt, 90)
        XCTAssertEqual(envelope.session.endedAt, 101)
        XCTAssertEqual(envelope.measurements, rows)

        let csv = String(decoding: try await reopened.exportCSV(), as: UTF8.self)
        XCTAssertTrue(csv.hasPrefix("sequence,session_id,kind,source_timestamp,received_at,received_monotonic,payload_json\n"))
        XCTAssertTrue(csv.contains("\"{\"\"name\"\":\"\"monitoring_started\"\"}\""))
    }

    func testLocationExportPreservesOriginalTimestampAndCoordinates() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("measurement-location-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "session-2", startedAt: 90)
        let location = LocationSample(
            originalTimestamp: 90,
            receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 2_000,
            latitude: 37.5,
            longitude: 127.0,
            altitude: nil,
            speed: 10,
            course: nil,
            horizontalAccuracy: 4,
            verticalAccuracy: nil
        )
        try await recorder.append(.location(location))

        let rows = try await recorder.export()
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.kind, "LOCATION")
        XCTAssertEqual(row.sourceTimestamp, 90)
        XCTAssertEqual(row.receivedAtEpoch, 100)
        XCTAssertTrue(row.payloadJSON.contains("37.5"))
        XCTAssertTrue(row.payloadJSON.contains("127"))
    }
}
