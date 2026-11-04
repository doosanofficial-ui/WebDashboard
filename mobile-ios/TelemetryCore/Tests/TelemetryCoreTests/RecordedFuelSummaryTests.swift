import XCTest
@testable import TelemetryCore

/// Mirrored design fixtures only. These tests have NOT been compiled or run.
final class RecordedFuelSummaryTests: XCTestCase {
    private func row(_ sequence: Int64, _ time: Double, _ rate: Double? = 6,
                     segment: Int = 0, quality: SignalQuality? = .valid, unit: String = "L/h",
                     session: String = "s", signal: String = "fuel") -> RecordedFuelObservation {
        .init(sessionID: session, signalID: signal, sourceSegment: segment, sourceSequence: sequence,
              timestampSeconds: time, value: rate, unit: unit, quality: quality)
    }
    private func calc(_ rows: [RecordedFuelObservation], start: Double = 0, end: Double = 3600,
                      gap: Double = 3600, session: String = "s") throws -> RecordedFuelSummary {
        try RecordedFuelSummaryCalculator.calculate(observations: rows, sessionID: session, signalID: "fuel",
            startSeconds: start, endSeconds: end, policy: .init(maxGapSeconds: gap))
    }
    func testConstant() throws {
        let r = try calc([row(0, 0), row(1, 3600)])
        XCTAssertEqual(r.observedLiters, 6); XCTAssertEqual(r.meanRateLitersPerHour, 6)
        XCTAssertEqual(r.coverageFraction, 1)
    }
    func testTrapezoid() throws {
        let r = try calc([row(0, 0, 0), row(1, 3600, 12)])
        XCTAssertEqual(r.observedLiters, 6); XCTAssertEqual(r.meanRateLitersPerHour, 6)
    }
    func testZero() throws {
        let r = try calc([row(0, 0, 0), row(1, 3600, 0)])
        XCTAssertEqual(r.observedLiters, 0); XCTAssertEqual(r.meanRateLitersPerHour, 0)
    }
    func testEmpty() throws {
        let r = try calc([])
        XCTAssertNil(r.observedLiters); XCTAssertNil(r.meanRateLitersPerHour)
        XCTAssertEqual(r.coveredDurationSeconds, 0)
    }
    func testSingle() throws { XCTAssertNil(try calc([row(0, 100)]).observedLiters) }
    func testQualityBarriers() throws {
        // Unknown legacy quality is nil. All nonvalid raw quality cases are barriers.
        let qualities: [SignalQuality?] = [nil, .stale, .disconnected, .invalid]
        for quality in qualities {
            let r = try calc([row(0, 0), row(1, 10, quality: quality), row(2, 20)])
            XCTAssertNil(r.observedLiters); XCTAssertEqual(r.excludedIntervals.count, 2)
        }
    }
    func testUnits() throws {
        for unit in ["l/h", "L/min", "g/s", "", "km/h"] {
            XCTAssertNil(try calc([row(0, 0, unit: unit), row(1, 10)]).observedLiters)
        }
    }
    func testBadRates() throws {
        let values: [Double?] = [-1, .infinity, -.infinity, .nan, nil]
        for value in values {
            XCTAssertNil(try calc([row(0, 0, value), row(1, 10)]).observedLiters)
        }
    }
    func testSource() throws {
        let r = try calc([row(0, 0), row(1, 10), row(2, 20, segment: 1), row(3, 30, segment: 1)])
        XCTAssertEqual(r.coveredDurationSeconds, 20)
        XCTAssertEqual(r.excludedIntervals, [.init(sourceSequences: [1, 2], reasons: [.sourceChanged])])
    }
    func testReturnToSource() throws {
        XCTAssertNil(try calc([row(0, 0), row(1, 10, segment: 1), row(2, 20)]).observedLiters)
    }
    func testNegativeSource() { XCTAssertThrowsError(try calc([row(0, 0, segment: -1)])) }
    func testScope() {
        XCTAssertThrowsError(try calc([row(0, 0, session: "other")]))
        XCTAssertThrowsError(try calc([row(0, 0, signal: "other")]))
    }
    func testDuplicate() { XCTAssertThrowsError(try calc([row(0, 0), row(0, 10)])) }
    func testTimeReversal() { XCTAssertThrowsError(try calc([row(0, 10), row(1, 0)])) }
    func testNonfiniteTime() { XCTAssertThrowsError(try calc([row(0, .infinity)])) }
    func testSequenceOrder() throws {
        XCTAssertEqual(try calc([row(1, 3600), row(0, 0)]).observedLiters, 6)
    }
    func testGap() throws {
        let r = try calc([row(0, 0), row(1, 10), row(2, 30)], gap: 10)
        XCTAssertEqual(r.coveredDurationSeconds, 10); XCTAssertEqual(r.excludedIntervals.count, 1)
    }
    func testNoClippingOrExtrapolation() throws {
        let r = try calc([row(0, 0), row(1, 10), row(2, 20)], start: 5, end: 25)
        XCTAssertEqual(r.coveredDurationSeconds, 10); XCTAssertEqual(r.coverageFraction, 0.5)
    }
    func testPolicy() {
        XCTAssertThrowsError(try calc([], start: -1)); XCTAssertThrowsError(try calc([], end: -1))
        XCTAssertThrowsError(try calc([], gap: 0)); XCTAssertThrowsError(try calc([], end: .infinity))
        XCTAssertThrowsError(try calc([], gap: .nan)); XCTAssertThrowsError(try calc([], session: ""))
    }
    func testOverflowExcluded() throws {
        let r = try calc([row(0, 0, 1e308), row(1, 1e308, 1e308)], end: 1e308, gap: 1e308)
        XCTAssertNil(r.observedLiters)
        XCTAssertEqual(r.excludedIntervals.first?.reasons, [.unrepresentableCalculation])
    }
    func testScaledProduct() throws {
        let r = try calc([row(0, 0, 1e308), row(1, .leastNonzeroMagnitude, 1e308)], end: .leastNonzeroMagnitude, gap: 1)
        XCTAssertGreaterThan(try XCTUnwrap(r.observedLiters), 0)
        XCTAssertEqual(try XCTUnwrap(r.meanRateLitersPerHour) / 1e308, 1, accuracy: 1e-14)
    }
    func testUnderflowExcluded() throws {
        let tiny = Double.leastNonzeroMagnitude
        XCTAssertNil(try calc([row(0, 0, tiny), row(1, tiny, tiny)], end: tiny, gap: 1).observedLiters)
    }
    func testSafeMidpoint() throws {
        let r = try calc([row(0, 0, 1e308), row(1, 1, 1e308)], end: 1)
        XCTAssertEqual(r.meanRateLitersPerHour, 1e308); XCTAssertTrue(try XCTUnwrap(r.observedLiters).isFinite)
    }
    func testWeightedMeanRetainsPrior() throws {
        let r = try calc([row(0, 0, 2), row(1, 1, 0), row(2, 1e20, 0)], end: 1e20, gap: 1e20)
        XCTAssertGreaterThan(try XCTUnwrap(r.meanRateLitersPerHour), 0)
        XCTAssertEqual(try XCTUnwrap(r.meanRateLitersPerHour) / 1e-20, 1, accuracy: 1e-14)
    }
    func testRawImmutable() throws {
        let rows = [row(0, 0), row(1, 10, quality: nil)]; let original = rows
        _ = try calc(rows); XCTAssertEqual(rows, original)
    }
    func testEconomyGate() throws {
        let r = try calc([row(0, 0), row(1, 3600)])
        XCTAssertNil(r.litersPer100Kilometers)
        XCTAssertEqual(r.fuelEconomyUnavailableReason, .matchedDistanceCoverageNotProven)
    }
    func testDurationRoundoffStaysWithinProvenWindow() throws {
        let times = [0.0, 2.2693756714736725e-09, 2.6928138167144225e-09, 2.4486054696852314e-06,
                     0.018658630345282833, 1.461471356098542, 3.42675616651033, 7.624625833536056,
                     99.74665206980956, 173.31103005723637, 253.2563933236103, 536.4771474060876,
                     172091.84742449663, 16201167.229855713, 26866526.910031587, 56762888.27307951,
                     137896335.0764639, 9227114544.542324, 23457606870.380356, 69757707145.88286,
                     259983544643.13095]
        let end = try XCTUnwrap(times.last)
        let r = try calc(times.enumerated().map { row(Int64($0.offset), $0.element, 1) }, end: end, gap: end)
        XCTAssertEqual(r.excludedIntervals, []); XCTAssertEqual(r.coveredDurationSeconds, end)
        XCTAssertEqual(r.coverageFraction, 1)
    }
    func testDurationTotalOverflowIsExcluded() throws {
        let end = Double.greatestFiniteMagnitude
        let times = [0, 7.074494515330672e307, 7.742118557452366e307, end]
        let r = try calc(times.enumerated().map { row(Int64($0.offset), $0.element, 0) }, end: end, gap: end)
        XCTAssertTrue(r.coveredDurationSeconds.isFinite); XCTAssertTrue(r.coverageFraction.isFinite)
        XCTAssertEqual(r.excludedIntervals.count, 1)
    }
    func testSubnormalMeanIsNotFabricatedZero() throws {
        let r = try calc([row(0, 0, .leastNonzeroMagnitude), row(1, 1e308, 0)], end: 1e308, gap: 1e308)
        XCTAssertNil(r.observedLiters); XCTAssertNil(r.meanRateLitersPerHour)
    }
    func testEqualTimestamps() { XCTAssertThrowsError(try calc([row(0, 0), row(1, 0)])) }
    func testEmptyWindow() throws {
        let r = try calc([], end: 0); XCTAssertNil(r.observedLiters); XCTAssertEqual(r.coverageFraction, 0)
    }
    func testWeightedSubnormalTermsSumBeforeRounding() throws {
        let tiny = Double.leastNonzeroMagnitude
        let r = try calc([row(0, 0, tiny), row(1, 1e307, tiny), row(2, 2e307, tiny)], end: 2e307, gap: 1e307)
        XCTAssertEqual(r.meanRateLitersPerHour, tiny); XCTAssertEqual(r.excludedIntervals, [])
    }

    func testPositiveAggregateMeanUnderflowExcluded() throws {
        let tiny = Double.leastNonzeroMagnitude
        let r = try calc([row(0, 0, tiny), row(1, 1e307, tiny), row(2, 2e307, 0), row(3, 1e308, 0)],
                         end: 1e308, gap: 1e308)
        XCTAssertEqual(r.meanRateLitersPerHour, tiny); XCTAssertEqual(r.coveredDurationSeconds, 1e307)
        XCTAssertEqual(r.excludedIntervals.count, 2)
    }

}
