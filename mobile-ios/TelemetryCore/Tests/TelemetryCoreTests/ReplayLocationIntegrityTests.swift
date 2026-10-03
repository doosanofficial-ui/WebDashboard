import Foundation
import XCTest
@testable import TelemetryCore

final class ReplayLocationIntegrityTests: XCTestCase {
    private func export(latitude: Double, longitude: Double, altitude: Double = -30) throws -> MeasurementExport {
        let location = LocationSample(originalTimestamp: 102, receivedAtEpoch: 102,
            receivedAtMonotonicNanos: 2_000_000_000, latitude: latitude, longitude: longitude,
            altitude: altitude, speed: -1, course: -1, horizontalAccuracy: 5, verticalAccuracy: -1)
        let first = PersistedMeasurement(sequence: 1, sessionID: "location-fixture", kind: "SYSTEM",
            sourceTimestamp: 100, receivedAtEpoch: 100, receivedAtMonotonicNanos: 0, payloadJSON: "{\"name\":\"MARK\"}")
        let bad = PersistedMeasurement(sequence: 2, sessionID: "location-fixture", kind: "LOCATION",
            sourceTimestamp: 102, receivedAtEpoch: 102, receivedAtMonotonicNanos: 2_000_000_000,
            payloadJSON: String(decoding: try JSONEncoder().encode(location), as: UTF8.self))
        return .init(session: .init(sessionID: "location-fixture", startedAt: 100, endedAt: 103, mode: .demo), measurements: [first,bad])
    }
    func testInvalidFutureCoordinatesRejectEntireTimelineBeforeEarlySeek() async throws {
        for (lat,lon) in [(999.0,0.0),(0,181),(-91,0),(0,-181)] {
            do { _ = try await MeasurementReplay.timeline(export(latitude: lat,longitude: lon)); XCTFail("Impossible LOCATION accepted") }
            catch { XCTAssertEqual(error as? MeasurementReplayError, .malformedRow("LOCATION")) }
        }
    }
    func testNegativeAltitudeAndOptionalSentinelsAreNotTreatedAsInvalidCoordinates() async throws {
        let timeline = try await MeasurementReplay.timeline(export(latitude: -90, longitude: 180))
        let snapshot = try await timeline.snapshot(at: timeline.duration)
        XCTAssertEqual(snapshot.location?.altitude, -30)
        XCTAssertEqual(snapshot.location?.speed, -1, "Keep raw sentinel evidence; the display policy must not label it as speed")
        XCTAssertEqual(snapshot.location?.course, -1)
        XCTAssertEqual(snapshot.location?.verticalAccuracy, -1)
        XCTAssertEqual(snapshot.location?.originalTimestamp, 102)
    }
}
