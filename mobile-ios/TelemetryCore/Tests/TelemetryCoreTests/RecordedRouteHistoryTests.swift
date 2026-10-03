import Foundation
import XCTest
@testable import TelemetryCore

final class RecordedRouteHistoryTests: XCTestCase {
    private func row(_ sequence: Int64, time: UInt64, lat: Double = 0, lon: Double = 0,
                     accuracy: Double? = nil, epoch: Double? = nil) throws -> PersistedMeasurement {
        let receive = epoch ?? (100 + Double(time) / 1_000_000_000)
        let sample = LocationSample(originalTimestamp: receive - 0.25, receivedAtEpoch: receive,
            receivedAtMonotonicNanos: time, latitude: lat, longitude: lon, altitude: -30,
            speed: -1, course: -1, horizontalAccuracy: accuracy, verticalAccuracy: -1, source: .demo)
        return .init(sequence: sequence, sessionID: "route", kind: "LOCATION",
            sourceTimestamp: sample.originalTimestamp, receivedAtEpoch: receive,
            receivedAtMonotonicNanos: time, payloadJSON: String(decoding: try JSONEncoder().encode(sample), as: UTF8.self))
    }
    private func timeline(_ rows: [PersistedMeasurement]) async throws -> MeasurementReplay.Timeline {
        let first = PersistedMeasurement(sequence: 1, sessionID: "route", kind: "SYSTEM",
            sourceTimestamp: 100, receivedAtEpoch: 100, receivedAtMonotonicNanos: 0, payloadJSON: "{\"name\":\"MARK\"}")
        return try await MeasurementReplay.timeline(.init(session: .init(sessionID: "route", startedAt: 100,
            endedAt: 2000, mode: .demo), measurements: [first] + rows))
    }
    func testRoutePrefixRetainsOriginalRowsTimesAndAccuracyAcrossBackwardSeek() async throws {
        let rows = [try row(2, time: 1_000_000_000, lon: 179.9),
                    try row(3, time: 3_000_000_000, lat: 0.001, lon: -179.9, accuracy: 5, epoch: 99),
                    try row(4, time: 4_000_000_000, accuracy: -1)]
        let t = try await timeline(rows)
        let end = try t.locationHistory(at: 4)
        XCTAssertEqual(end.samples.map(\.measurement), rows)
        XCTAssertEqual(end.samples.map(\.location.originalTimestamp), [100.75, 98.75, 103.75])
        XCTAssertEqual(end.samples.map(\.location.horizontalAccuracy), [nil, 5, -1])
        XCTAssertEqual(end.plottableSamples.count, 2)
        XCTAssertFalse(try XCTUnwrap(end.samples.last).isPlottable)
        XCTAssertEqual(try t.locationHistory(at: 2.5).samples.map(\.measurement), [rows[0]])
        XCTAssertTrue(try t.locationHistory(at: 0).samples.isEmpty)
        XCTAssertEqual(end.samples[0].location.altitude, -30)
        XCTAssertEqual(end.samples[0].location.speed, -1)
    }
    func testRejectedFixBreaksLineBeforeFilteringAndCapsRawRows() async throws {
        let t = try await timeline([try row(2, time: 1_000_000_000),
            try row(3, time: 2_000_000_000, accuracy: -1),
            try row(4, time: 3_000_000_000, lat: 1)])
        let h = try t.locationHistory(at: 3)
        XCTAssertEqual(h.projectedPoints.map(\.sourceSegment), [0, 1])
        let capped = try t.locationHistory(at: 3, maximumSamples: 2)
        XCTAssertEqual(capped.samples.count, 2)
        XCTAssertEqual(capped.plottableSamples.count, 1)
        XCTAssertEqual(capped.totalRowsInPrefix, 3)
        XCTAssertTrue(capped.truncated)
        let equal = try await timeline([try row(2, time: 1_000_000_000), try row(3, time: 1_000_000_000, lat: 1)])
        XCTAssertEqual(try equal.locationHistory(at: 1).samples.map(\.measurement.sequence), [2, 3])
    }
    func testDefaultRouteCapCanCorrectlyContainOnlyRejectedFixesAndRejectsBadQueries() async throws {
        var rows: [PersistedMeasurement] = []
        for i in 1...1002 { rows.append(try row(Int64(i + 1), time: UInt64(i) * 1_000_000_000, accuracy: i <= 2 ? nil : -1)) }
        let t = try await timeline(rows); let h = try t.locationHistory(at: t.duration)
        XCTAssertEqual(h.totalRowsInPrefix, 1002); XCTAssertEqual(h.samples.count, 1000)
        XCTAssertTrue(h.truncated); XCTAssertTrue(h.projectedPoints.isEmpty)
        for bad in [Double.nan, Double.infinity, -Double.infinity] { XCTAssertThrowsError(try t.locationHistory(at: bad)) }
        XCTAssertThrowsError(try t.locationHistory(at: 0, maximumSamples: 1001))
        XCTAssertThrowsError(try t.locationHistory(at: 0, maximumSamples: 0))
    }
    func testProjectionWrapsDatelineAndHandlesPolesRepeatedHorizontalAndVerticalPoints() async throws {
        let t = try await timeline([try row(2, time: 1_000_000_000, lon: 179.9),
            try row(3, time: 2_000_000_000, lon: -179.9), try row(4, time: 3_000_000_000, lon: 170)])
        let p = try t.locationHistory(at: 3).projectedPoints
        XCTAssertLessThan(abs(p[0].x - p[1].x), 0.03)
        XCTAssertEqual(p[2].x, 0, accuracy: 0.000001)
        for coordinates in [[(0.0,0.0)],[(0,0),(0,0)],[(90,0),(90,180)],[(-90,0),(-90,-180)],
                            [(1,0),(2,0)],[(0,1),(0,2)],[(0,0),(0,180),(0,0)]] {
            let rows = try coordinates.enumerated().map { try row(Int64($0.offset + 2), time: UInt64($0.offset + 1) * 1_000_000_000, lat: $0.element.0, lon: $0.element.1) }
            let route = try await timeline(rows)
            let points = try route.locationHistory(at: route.duration).projectedPoints
            XCTAssertEqual(points.count, coordinates.count)
            XCTAssertTrue(points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) })
            if coordinates.count == 1 || coordinates.allSatisfy({ $0 == coordinates[0] }) || abs(coordinates[0].0) == 90 {
                XCTAssertTrue(points.allSatisfy { $0.x == 0.5 && $0.y == 0.5 })
            }
        }
    }
}
