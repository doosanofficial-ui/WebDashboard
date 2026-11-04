import XCTest
@testable import TelemetryCore

final class TrackBearingEstimateTests: XCTestCase {
    private func fix(archiveSequence: Int64 = 100, predecessorArchiveSequence: Int64? = nil, sessionID: String = "session", scope: String = "route", generation: String = "g1",
                     segment: Int = 0, gpsOrdinal: Int = 0, timestamp: Double = 100,
                     latitude: Double = 0, longitude: Double = 0,
                     accuracy: Double? = 2, course: Double? = nil, qualified: Bool = true) -> TrackBearingEstimate.Fix {
        .init(sessionID: sessionID, archiveSequence: archiveSequence, predecessorArchiveSequence: predecessorArchiveSequence, scope: scope, generation: generation, segment: segment, gpsOrdinal: gpsOrdinal,
              timestamp: timestamp, latitude: latitude, longitude: longitude,
              accuracy: accuracy, course: course, qualified: qualified)
    }
    private func end(latitude: Double = 0, longitude: Double = 0.001, course: Double? = nil) -> TrackBearingEstimate.Fix {
        fix(archiveSequence: 104, predecessorArchiveSequence: 100, gpsOrdinal: 1, timestamp: 102, latitude: latitude, longitude: longitude, course: course)
    }
    func testCardinalDirectionsAndDistance() throws {
        for (lat, lon, degrees) in [(0.0, 0.001, 90.0), (0.001, 0, 0), (0, -0.001, 270), (-0.001, 0, 180)] {
            let result = TrackBearingEstimate.estimate(fix(), end(latitude: lat, longitude: lon))
            XCTAssertEqual(result.reason, .estimated)
            XCTAssertEqual(try XCTUnwrap(result.bearing), degrees, accuracy: 1e-8)
            XCTAssertEqual(try XCTUnwrap(result.distance), 111.1950802335, accuracy: 1e-6)
        }
    }
    func testRawEvidenceAndProviderCourseStaySeparate() throws {
        let a = fix(), b = end(course: 12.5)
        let result = TrackBearingEstimate.estimate(a, b)
        XCTAssertEqual(result.first, a); XCTAssertEqual(result.last, b)
        XCTAssertEqual(result.observedCourse, 12.5)
        XCTAssertEqual(try XCTUnwrap(result.bearing), 90, accuracy: 1e-8)
        for course in [nil, -1, 360, .nan, .infinity] as [Double?] {
            XCTAssertNil(TrackBearingEstimate.estimate(a, end(course: course)).observedCourse)
        }
    }
    func testDiscontinuitiesNeverBridge() {
        for b in [fix(archiveSequence: 104, predecessorArchiveSequence: 100, scope: "other", gpsOrdinal: 1, timestamp: 102, longitude: 0.001),
                  fix(archiveSequence: 104, predecessorArchiveSequence: 100, generation: "g2", gpsOrdinal: 1, timestamp: 102, longitude: 0.001),
                  fix(archiveSequence: 104, predecessorArchiveSequence: 100, segment: 1, gpsOrdinal: 1, timestamp: 102, longitude: 0.001),
                  fix(archiveSequence: 104, predecessorArchiveSequence: 100, gpsOrdinal: 2, timestamp: 102, longitude: 0.001),
                  fix(archiveSequence: 100, predecessorArchiveSequence: 100, gpsOrdinal: 1, timestamp: 102, longitude: 0.001)] {
            XCTAssertEqual(TrackBearingEstimate.estimate(fix(), b).reason, .discontinuity)
        }
    }
    func testInvalidEvidence() {
        for a in [fix(accuracy: nil), fix(accuracy: -1), fix(accuracy: 21), fix(accuracy: .nan),
                  fix(latitude: .nan), fix(longitude: .infinity), fix(latitude: 91), fix(longitude: 181),
                  fix(timestamp: -1), fix(timestamp: .nan), fix(qualified: false), fix(scope: ""),
                  fix(generation: " "), fix(sessionID: ""), fix(segment: -1), fix(gpsOrdinal: -1)] {
            XCTAssertEqual(TrackBearingEstimate.estimate(a, end()).reason, .invalidEvidence)
            XCTAssertEqual(TrackBearingEstimate.estimate(end(), a).reason, .invalidEvidence)
        }
    }
    func testTimeWindow() {
        for t in [99.0, 100, 100.49999, 110.00001] {
            XCTAssertNil(TrackBearingEstimate.estimate(fix(), fix(archiveSequence: 104, predecessorArchiveSequence: 100, gpsOrdinal: 1, timestamp: t, longitude: 0.001)).bearing)
        }
        for t in [100.5, 110.0] {
            XCTAssertNotNil(TrackBearingEstimate.estimate(fix(), fix(archiveSequence: 104, predecessorArchiveSequence: 100, gpsOrdinal: 1, timestamp: t, longitude: 0.001)).bearing)
        }
    }
    func testUnknownStationaryNoiseJumpPoleAntipode() {
        for b in [end(longitude: 0), end(longitude: 0.0001), end(longitude: 0.01), end(longitude: 180),
                  end(latitude: 90), end(latitude: 80.0001),
                  fix(archiveSequence: 104, predecessorArchiveSequence: 100, gpsOrdinal: 1, timestamp: 102, longitude: 0.0005, accuracy: 20)] {
            XCTAssertNil(TrackBearingEstimate.estimate(fix(), b).bearing)
        }
        XCTAssertNil(TrackBearingEstimate.estimate(fix(latitude: 81), end(latitude: 81, longitude: 0.002)).bearing)
    }
    func testDatelineBothDirections() throws {
        let east = TrackBearingEstimate.estimate(fix(longitude: 179.9995), end(longitude: -179.9995))
        let west = TrackBearingEstimate.estimate(fix(longitude: -179.9995), end(longitude: 179.9995))
        XCTAssertEqual(try XCTUnwrap(east.bearing), 90, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(west.bearing), 270, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(east.distance), 111.1950802335, accuracy: 1e-5)
    }
    func testNoStaleStateAndAccuracyBaseline() {
        XCTAssertNotNil(TrackBearingEstimate.estimate(fix(), end()).bearing)
        XCTAssertNil(TrackBearingEstimate.estimate(fix(), end(longitude: 0)).bearing)
        XCTAssertNotNil(TrackBearingEstimate.estimate(fix(), end()).bearing)
        let b = fix(archiveSequence: 104, predecessorArchiveSequence: 100, gpsOrdinal: 1, timestamp: 102, longitude: 0.00072, accuracy: 10)
        XCTAssertNotNil(TrackBearingEstimate.estimate(fix(accuracy: 10), b).bearing)
        XCTAssertNil(TrackBearingEstimate.estimate(fix(accuracy: 10.1), b).bearing)
    }

    func testInterleavedArchiveRowsAndGPSBarriers() {
        // LOCATION 100, CAN 101, SIGNAL 102, SYSTEM 103, LOCATION 104.
        let a = fix(), b = end()
        let otherSession = fix(archiveSequence: 104, predecessorArchiveSequence: 100, sessionID: "other", gpsOrdinal: 1, timestamp: 102, longitude: 0.001)
        XCTAssertNil(TrackBearingEstimate.estimate(a, otherSession).bearing)
        let result = TrackBearingEstimate.estimate(a, b)
        XCTAssertNotNil(result.bearing)
        XCTAssertEqual(result.first.archiveSequence, 100)
        XCTAssertEqual(result.last.archiveSequence, 104)
        let missing = fix(archiveSequence: 108, predecessorArchiveSequence: 104, gpsOrdinal: 2,
                          timestamp: 104, longitude: 0.002)
        XCTAssertNil(TrackBearingEstimate.estimate(a, missing).bearing)
        let compacted = fix(archiveSequence: 108, predecessorArchiveSequence: 104, gpsOrdinal: 1,
                            timestamp: 104, longitude: 0.002)
        XCTAssertNil(TrackBearingEstimate.estimate(a, compacted).bearing)
        let unknown = fix(archiveSequence: 104, gpsOrdinal: 1, timestamp: 102, longitude: 0.001)
        XCTAssertNil(TrackBearingEstimate.estimate(a, unknown).bearing)
        let invalid = fix(archiveSequence: 104, predecessorArchiveSequence: 100, gpsOrdinal: 1,
                          timestamp: 102, longitude: 0.001, qualified: false)
        XCTAssertNil(TrackBearingEstimate.estimate(a, invalid).bearing)
        XCTAssertNil(TrackBearingEstimate.estimate(invalid, missing).bearing)
    }
    private func trail(_ points: [(Double, Double)]) -> [TrackBearingEstimate.Fix] {
        points.enumerated().map { i, point in
            fix(archiveSequence: Int64(100 + 4 * i), predecessorArchiveSequence: i == 0 ? nil : Int64(96 + 4 * i),
                gpsOrdinal: i, timestamp: 100 + Double(2 * i), latitude: point.0, longitude: point.1)
        }
    }
    func testCircularDisplaySmoothingAndWrap() throws {
        let points = trail([(0, 0), (0, 0.001), (0, 0.002)])
        let result = TrackBearingEstimate.smooth(points, asOf: 104)
        XCTAssertEqual(result.fixes, points)
        XCTAssertEqual(result.pairs.count, 2)
        XCTAssertEqual(try XCTUnwrap(result.bearing), 90, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(result.resultant), 1, accuracy: 1e-8)
        let wrap = TrackBearingEstimate.smooth(trail([(0, 0), (0.001, -0.00001), (0.002, 0)]), asOf: 104)
        let angle = try XCTUnwrap(wrap.bearing)
        XCTAssertLessThan(min(angle, 360 - angle), 0.001)
        let turn = TrackBearingEstimate.smooth(trail([(0, 0), (0, 0.001), (0.0005, 0.0018660254038)]), asOf: 104)
        XCTAssertEqual(try XCTUnwrap(turn.bearing), 75, accuracy: 1e-4) // lag, NOT latest track/course
    }
    func testSmoothingRejectsStaleResetUnknownAndLowResultant() {
        let points = trail([(0, 0), (0, 0.001), (0, 0.002), (0, 0.003)])
        for asOf in [105.999, 108.001, Double.nan, Double.infinity] {
            XCTAssertNil(TrackBearingEstimate.smooth(points, asOf: asOf).bearing)
        }
        for asOf in [106.0, 108] { XCTAssertNotNil(TrackBearingEstimate.smooth(points, asOf: asOf).bearing) }
        for points in [[], Array(points.prefix(2)), [points[0], points[2], points[3]],
                       trail([(0, 0), (0, 0.001), (0, 0)]), trail([(0, 0), (0, 0.001), (0.001, 0.001)])] {
            XCTAssertNil(TrackBearingEstimate.smooth(points, asOf: 104).bearing)
        }
        XCTAssertNil(TrackBearingEstimate.smooth(Array(points.prefix(2)), asOf: 102).bearing)
        let five: [TrackBearingEstimate.Fix] = (0..<5).map { (i: Int) in
            let sequence = Int64(100 + 4 * i)
            let predecessor: Int64? = i == 0 ? nil : Int64(96 + 4 * i)
            let timestamp = 100.0 + Double(i)
            let longitude = Double(i) * 0.001
            return fix(archiveSequence: sequence, predecessorArchiveSequence: predecessor,
                       gpsOrdinal: i, timestamp: timestamp, longitude: longitude)
        }
        XCTAssertNil(TrackBearingEstimate.smooth(five, asOf: 104).bearing)
        let longWindow = [points[0],
                          fix(archiveSequence: 104, predecessorArchiveSequence: 100, gpsOrdinal: 1, timestamp: 104, longitude: 0.001),
                          fix(archiveSequence: 108, predecessorArchiveSequence: 104, gpsOrdinal: 2, timestamp: 108, longitude: 0.002)]
        XCTAssertNil(TrackBearingEstimate.smooth(longWindow, asOf: 108).bearing)
        let invalid = fix(archiveSequence: 104, predecessorArchiveSequence: 100, gpsOrdinal: 1,
                          timestamp: 102, longitude: 0.001, qualified: false)
        XCTAssertNil(TrackBearingEstimate.smooth([points[0], invalid, points[2]], asOf: 104).bearing)
        let reset = fix(archiveSequence: 104, predecessorArchiveSequence: 100, generation: "reset", gpsOrdinal: 1,
                        timestamp: 102, longitude: 0.001)
        XCTAssertNil(TrackBearingEstimate.smooth([points[0], reset, points[2]], asOf: 104).bearing)
    }
}
