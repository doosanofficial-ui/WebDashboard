import XCTest
@testable import TelemetryCore

// Synthetic-only mirror of Python specification; Swift compilation and execution deferred.
final class RecordedSpeedWindowTests: XCTestCase {
    private func row(_ sequence: Int64, _ time: Double, _ value: Double, unit: String = "km/h",
                     quality: SignalQuality? = .valid, segment: Int = 0, session: String = "s") -> RecordedTripObservation {
        .init(sessionID: session, signalID: "speed", sourceSegment: segment, sourceSequence: sequence,
              timestampSeconds: time, value: value, unit: unit, quality: quality)
    }
    private func calculate(_ rows: [RecordedTripObservation], lower: Double = 0, upper: Double = 100,
                           start: Double = 0, end: Double = 100, gap: Double = 2,
                           duration: Double = 100) throws -> RecordedSpeedWindowReport {
        try RecordedSpeedWindowCalculator.calculate(observations: rows, sessionID: "s", signalID: "speed",
            startSeconds: start, endSeconds: end, policy: .init(lowerKmh: lower, upperKmh: upper,
                maxGapSeconds: gap, maxDurationSeconds: duration))
    }
    private func speeds(_ values: [Double], lower: Double = 0, upper: Double = 100,
                        duration: Double = 100) throws -> [RecordedSpeedWindowEstimate] {
        try calculate(values.enumerated().map { row(Int64($0.offset), Double($0.offset), $0.element) },
                      lower: lower, upper: upper, duration: duration).estimates
    }
    func testBasic() throws { XCTAssertEqual(try speeds([0,50,100]).first?.durationSeconds, 2) }
    func testNoAssumedStart() throws { XCTAssertTrue(try speeds([20,100]).isEmpty) }
    func testSingleJump() throws {
        let event = try XCTUnwrap(speeds([40,120], lower: 60).first)
        XCTAssertEqual(event.durationSeconds, 0.5)
        XCTAssertEqual(event.lowerCrossing.before.sourceSequence, 0)
        XCTAssertEqual(event.lowerCrossing.after.sourceSequence, 1)
        XCTAssertTrue(event.interpretation.contains("estimate"))
    }
    func testPlateau() throws { XCTAssertEqual(try speeds([0,0,50,100]).first?.durationSeconds, 2) }
    func testEqualPolicy() { XCTAssertThrowsError(try speeds([0,100], lower: 100, upper: 100)) }
    func testReversal() throws { XCTAssertTrue(try speeds([0,70,60,100]).isEmpty) }
    func testRepeat() throws { XCTAssertEqual(try speeds([0,100,20,100,0,100]).count, 2) }
    func testJitter() throws { XCTAssertEqual(try speeds([50,61,59,61,100], lower: 60).count, 1) }
    func testGap() throws { XCTAssertTrue(try calculate([row(0,0,0),row(1,10,100)]).estimates.isEmpty) }
    func testSource() throws { XCTAssertTrue(try calculate([row(0,0,0),row(1,1,100,segment: 1)]).estimates.isEmpty) }
    func testBadQuality() throws { XCTAssertTrue(try calculate([row(0,0,0),row(1,1,50,quality: nil),row(2,2,100)]).estimates.isEmpty) }
    func testUnknownUnit() throws { XCTAssertTrue(try calculate([row(0,0,0,unit: ""),row(1,1,100)]).estimates.isEmpty) }
    func testUnits() throws {
        let result = try XCTUnwrap(calculate([row(0,0,0,unit: "m/s"),row(1,1,100/3.6,unit: "m/s")]).estimates.first)
        XCTAssertEqual(result.durationSeconds, 1, accuracy: 1e-12)
    }
    func testOutside() throws { XCTAssertTrue(try calculate([row(0,0,0),row(1,1,100)],start: 0.1).estimates.isEmpty) }
    func testDuplicateSequence() { XCTAssertThrowsError(try calculate([row(1,0,0),row(1,1,100)])) }
    func testDuplicateTime() { XCTAssertThrowsError(try calculate([row(0,0,0),row(1,0,100)])) }
    func testReverseTime() { XCTAssertThrowsError(try calculate([row(0,1,0),row(1,0,100)])) }
    func testScope() { XCTAssertThrowsError(try calculate([row(0,0,0,session: "other")])) }
    func testUnknownNotZero() throws { XCTAssertTrue(try speeds([.nan,100]).isEmpty) }
    func testNegative() throws { XCTAssertTrue(try speeds([-1,100]).isEmpty) }
    func testOverflowUnit() throws { XCTAssertTrue(try calculate([row(0,0,0),row(1,1,1e308,unit: "m/s")]).estimates.isEmpty) }
    func testMaxDuration() throws { XCTAssertTrue(try speeds([0,50,100],duration: 1).isEmpty) }
    func testInvalidWindow() { XCTAssertThrowsError(try calculate([row(0,0,0)],start: 2,end: 1)) }
    func testInvalidTimestamp() { XCTAssertThrowsError(try calculate([row(0,.nan,0)])) }
    func testRetainsRawRows() throws {
        let rows = [row(0,0,0),row(1,1,100)]
        let report = try calculate(rows)
        XCTAssertEqual(report.originalObservations,rows)
        XCTAssertEqual(report.estimates.first?.lowerCrossing.before,rows[0])
        XCTAssertEqual(report.estimates.first?.lowerCrossing.after,rows[1])
    }
    func testUnrepresentableCrossings() throws {
        XCTAssertTrue(try calculate([row(0,1e300,0),row(1,1e300+1e285,1e308)],upper: 1,
            end: 1.1e300,gap: 1e300,duration: 1e300).estimates.isEmpty)
    }
    func testSortSequence() throws { XCTAssertEqual(try calculate([row(1,1,100),row(0,0,0)]).estimates.first?.durationSeconds,1) }
    func testEmpty() throws { XCTAssertTrue(try calculate([]).estimates.isEmpty) }
    func testInvalidSegment() { XCTAssertThrowsError(try calculate([row(0,0,0,segment: -1)])) }
    func testNoRestartAboveBaseline() throws { XCTAssertTrue(try speeds([0,70,60,80,100]).isEmpty) }
    func testUnderflowCrossing() throws { XCTAssertTrue(try speeds([0,1e308],lower: Double.leastNonzeroMagnitude,upper: 1e308).isEmpty) }
    func testPendingPlateau() throws { XCTAssertEqual(try speeds([0,50,50,100]).first?.durationSeconds,3) }
    func testEqualUpperFirst() throws { XCTAssertTrue(try speeds([100,120]).isEmpty) }
    func testValidResetAfterBad() throws { XCTAssertEqual(try calculate([row(0,0,0),row(1,1,50,quality: nil),row(2,2,0),row(3,3,100)]).estimates.count,1) }
    func testSourceResetBaseline() throws { XCTAssertEqual(try calculate([row(0,0,50),row(1,1,0,segment: 1),row(2,2,100,segment: 1)]).estimates.count,1) }
    func testExactGap() throws { XCTAssertEqual(try calculate([row(0,0,0),row(1,2,100)],gap: 2).estimates.count,1) }
    func testExactDuration() throws { XCTAssertEqual(try speeds([0,50,100],duration: 2).count,1) }
    func testZeroWindow() throws { XCTAssertTrue(try calculate([row(0,0,0),row(1,1,100)],end: 0).estimates.isEmpty) }
    func testZeroGap() { XCTAssertThrowsError(try calculate([row(0,0,0),row(1,1,100)],gap: 0)) }
    func testInfinitePolicy() { XCTAssertThrowsError(try speeds([0,100],upper: .infinity)) }
}
