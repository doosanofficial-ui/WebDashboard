import Foundation
import XCTest
@testable import TelemetryCore

final class OutboxTests: XCTestCase {
    func location() throws -> TelemetryEvent {
        try .gps(latitude: 37, longitude: 127, speed: nil, heading: nil,
                 accuracy: 5, altitude: nil, capturedAt: 1_700_000_000, background: true)
    }

    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCaptureTimeAndUnknownSurviveSerialization() throws {
        let event = try location()
        let roundtrip = try JSONDecoder().decode(TelemetryEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(roundtrip, event)
        XCTAssertEqual(roundtrip.capturedAt, 1_700_000_000)
        XCTAssertNil(roundtrip.data.spd)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "GPS")
        XCTAssertEqual(object["captured_t"] as? Double, 1_700_000_000)
        XCTAssertEqual(event.id, event.id.lowercased())
    }

    func testInvalidCoordinatesNeverBecomeZero() {
        for latitude in [Double.nan, Double.infinity, 91, -91] {
            XCTAssertThrowsError(try TelemetryEvent.gps(latitude: latitude, longitude: 127,
                speed: nil, heading: nil, accuracy: nil, altitude: nil,
                capturedAt: 1_700_000_000, background: false))
        }
    }

    func testRealZeroRemainsValid() throws {
        let event = try TelemetryEvent.gps(latitude: 0, longitude: 0, speed: 0, heading: 0,
            accuracy: 0, altitude: -20, capturedAt: 1_700_000_000, background: false)
        XCTAssertEqual(event.data.spd, 0)
        XCTAssertEqual(event.data.hdg, 0)
        XCTAssertEqual(event.data.alt, -20)
    }

    func testQueueSurvivesReopeningUntilAcknowledged() async throws {
        let path = try directory().appendingPathComponent("outbox.sqlite3")
        let first = try DurableOutbox(path: path)
        let event = try location()
        try await first.enqueue(event)
        let reopened = try DurableOutbox(path: path)
        let pending = try await reopened.pending()
        XCTAssertEqual(pending, [event])
        let batch = try UploadBatch(clientID: "device-1", events: pending)
        try await reopened.acknowledge(.init(version: 2, clientID: "device-1", acked: [event.id]), for: batch)
        let remaining = try await first.pending()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPartialAcknowledgementPreservesOtherEvents() async throws {
        let box = try DurableOutbox(path: directory().appendingPathComponent("outbox.sqlite3"))
        let first = try location(), second = try location()
        try await box.enqueue(first)
        try await box.enqueue(second)
        let batch = try UploadBatch(clientID: "device-1", events: [first, second])
        try await box.acknowledge(.init(version: 2, clientID: "device-1", acked: [first.id]), for: batch)
        let pending = try await box.pending()
        XCTAssertEqual(pending, [second])
    }

    func testUnrelatedOrWrongClientAckCannotDeleteQueuedData() async throws {
        let box = try DurableOutbox(path: directory().appendingPathComponent("outbox.sqlite3"))
        let event = try location()
        try await box.enqueue(event)
        let batch = try UploadBatch(clientID: "device-1", events: [event])
        for ack in [Acknowledgement(version: 2, clientID: "device-2", acked: [event.id]),
                    Acknowledgement(version: 2, clientID: "device-1", acked: [UUID().uuidString.lowercased()])] {
            do {
                try await box.acknowledge(ack, for: batch)
                XCTFail("Invalid acknowledgement was accepted")
            } catch TelemetryError.invalidAcknowledgement { }
        }
        let pending = try await box.pending()
        XCTAssertEqual(pending, [event])
    }

    func testCapacityDoesNotSilentlyDropOldRecords() async throws {
        let box = try DurableOutbox(path: directory().appendingPathComponent("outbox.sqlite3"), capacity: 1)
        let first = try location()
        try await box.enqueue(first)
        do {
            try await box.enqueue(location())
            XCTFail("Overflow should be visible")
        } catch TelemetryError.queueFull { }
        let pending = try await box.pending()
        XCTAssertEqual(pending, [first])
    }

    func testDuplicateEnqueueIsIdempotent() async throws {
        let box = try DurableOutbox(path: directory().appendingPathComponent("outbox.sqlite3"))
        let event = try location()
        try await box.enqueue(event)
        try await box.enqueue(event)
        let pending = try await box.pending()
        XCTAssertEqual(pending, [event])
    }
}
