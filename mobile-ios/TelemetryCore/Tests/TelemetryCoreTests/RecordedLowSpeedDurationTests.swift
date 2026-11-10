import XCTest
@testable import TelemetryCore

// UNRUN: Swift compilation and native tests are explicitly deferred.
final class RecordedLowSpeedDurationTests: XCTestCase {
    private func row(_ id: Int64, _ t: Double, _ v: Double = 0, unit: String = "km/h",
                     valid: Bool = true, segment: Int = 0) -> RecordedTripObservation {
        .init(sessionID: "s", signalID: "v", sourceSegment: segment, sourceSequence: id,
              timestampSeconds: t, value: v, unit: unit, quality: valid ? .valid : nil)
    }
    private func run(_ rows: [RecordedTripObservation], start: Double = 0, end: Double = 10,
                     threshold: Double = 5, gap: Double = 3) throws -> RecordedLowSpeedReport {
        try RecordedLowSpeedCalculator.calculate(observations: rows, sessionID: "s", signalID: "v",
            startSeconds: start, endSeconds: end,
            policy: .init(thresholdKmh: threshold, maxGapSeconds: gap))
    }
    func testGlobalSequencesAndProvenance() throws {
        let a = row(10, 0), b = row(30, 2)
        let r = try run([b,a])
        XCTAssertEqual(r.belowThresholdDurationEstimateSeconds, 2)
        XCTAssertEqual(r.originalObservations, [a,b])
        XCTAssertEqual(r.brackets.first?.before, a)
        XCTAssertEqual(r.unclassifiedDurationSeconds, 8)
    }
    func testUnavailableVersusMeasuredZero() throws {
        XCTAssertNil(try run([]).belowThresholdDurationEstimateSeconds)
        XCTAssertNil(try run([row(1,0)]).belowThresholdDurationEstimateSeconds)
        XCTAssertEqual(try run([row(1,0,5),row(2,2,5)]).belowThresholdDurationEstimateSeconds, 0)
        XCTAssertEqual(try run([row(1,0),row(2,2)], threshold: 0).belowThresholdDurationEstimateSeconds, 0)
    }
    func testEqualityAndCrossingsRemainUnclassified() throws {
        for speed in [5.0, 10.0] {
            let r = try run([row(1,0,4),row(2,2,speed)])
            XCTAssertNil(r.belowThresholdDurationEstimateSeconds)
            XCTAssertEqual(r.brackets.first?.exclusion, .crossingUnclassified)
        }
    }
    func testWindowAndGapBounds() throws {
        let rows = [row(1,0),row(2,2)]
        XCTAssertNil(try run(rows,start: 1).belowThresholdDurationEstimateSeconds)
        XCTAssertNil(try run(rows,end: 0).belowThresholdDurationEstimateSeconds)
        XCTAssertEqual(try run(rows,gap: 2).classifiedDurationSeconds, 2)
        XCTAssertNil(try run(rows,gap: 1).belowThresholdDurationEstimateSeconds)
    }
    func testQualityUnitAndSegmentBarriers() throws {
        XCTAssertNil(try run([row(1,0),row(2,1,valid: false),row(3,2)]).belowThresholdDurationEstimateSeconds)
        XCTAssertNil(try run([row(1,0),row(2,2,segment: 1)]).belowThresholdDurationEstimateSeconds)
        XCTAssertNil(try run([row(1,0,unit: "mph"),row(2,2)]).belowThresholdDurationEstimateSeconds)
        XCTAssertEqual(try run([row(1,0,2,unit: "m/s"),row(2,2,2,unit: "m/s")]).belowThresholdDurationEstimateSeconds, 0)
    }
    func testInvalidSpeeds() throws {
        for v in [-1.0, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertNil(try run([row(1,0,v,unit: "m/s"),row(2,2)]).belowThresholdDurationEstimateSeconds)
        }
    }
    func testInvalidStructure() {
        for rows in [[row(1,0),row(1,2)], [row(1,2),row(2,1)], [row(-1,0)],
                     [row(1,-1)], [row(1,.infinity)], [row(1,0,segment: -1)]] {
            XCTAssertThrowsError(try run(rows))
        }
    }
    func testInvalidPoliciesAndScope() {
        XCTAssertThrowsError(try run([],start: -1))
        XCTAssertThrowsError(try run([],end: .infinity))
        XCTAssertThrowsError(try run([],threshold: -.infinity))
        XCTAssertThrowsError(try run([],threshold: .nan))
        XCTAssertThrowsError(try run([],gap: 0))
        XCTAssertThrowsError(try RecordedLowSpeedCalculator.calculate(observations: [row(1,0)],
            sessionID: "other", signalID: "v", startSeconds: 0, endSeconds: 10,
            policy: .init(thresholdKmh: 5, maxGapSeconds: 3)))
    }
    func testPartitionAndNumericExtremes() throws {
        let r = try run([row(1,0),row(2,2),row(3,3,10),row(4,4,10)])
        XCTAssertEqual(r.belowThresholdDurationEstimateSeconds, 2)
        XCTAssertEqual(r.classifiedDurationSeconds, 3)
        XCTAssertEqual(r.unclassifiedDurationSeconds, 7)
        let tiny = Double.leastNonzeroMagnitude
        XCTAssertEqual(try run([row(1,0),row(2,tiny)],end: tiny).belowThresholdDurationEstimateSeconds,tiny)
        let huge = try run([row(1,0),row(2,1e308)],end: 1.7e308,gap: 1.7e308)
        XCTAssertEqual(huge.belowThresholdDurationEstimateSeconds,1e308)
        XCTAssertTrue(huge.unclassifiedDurationSeconds.isFinite)
    }
}
