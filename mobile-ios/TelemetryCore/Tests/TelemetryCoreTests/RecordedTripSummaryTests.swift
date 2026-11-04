import XCTest
@testable import TelemetryCore

final class RecordedTripSummaryTests: XCTestCase {
    private func sample(_ sequence: Int64, _ time: Double, _ value: Double,
                        sourceSegment: Int = 0, quality: SignalQuality? = .valid, unit: String = "km/h",
                        sessionID: String = "session", signalID: String = "obd-speed") -> RecordedTripObservation {
        .init(sessionID: sessionID, signalID: signalID, sourceSegment: sourceSegment, sourceSequence: sequence,
              timestampSeconds: time, value: value, unit: unit, quality: quality)
    }

    private func summary(_ samples: [RecordedTripObservation], start: Double = 0, end: Double = 10,
                         gap: Double = 10, threshold: Double = 2) throws -> RecordedTripSummary {
        try RecordedTripSummaryCalculator.calculate(observations: samples,
            sessionID: "session", signalID: "obd-speed", startSeconds: start, endSeconds: end,
            policy: .init(maxGapSeconds: gap, movingThresholdKmh: threshold))
    }

    func testSourceChangesBlockOnlyTransitionIntervals() throws {
        let result = try summary([sample(1, 0, 36, sourceSegment: 0), sample(2, 2, 36, sourceSegment: 0),
                                  sample(3, 4, 36, sourceSegment: 1), sample(4, 6, 36, sourceSegment: 1)])
        XCTAssertEqual(try XCTUnwrap(result.distanceKilometers), 0.04, accuracy: 1e-12)
        XCTAssertEqual(result.coveredDurationSeconds, 4)
        XCTAssertEqual(result.excludedIntervals, [.init(sourceSequences: [2, 3], reasons: [.sourceChanged])])
    }

    func testReturningSourceSegmentDoesNotBridgeTransitions() throws {
        let result = try summary([sample(1, 0, 36, sourceSegment: 0), sample(2, 5, 36, sourceSegment: 1),
                                  sample(3, 10, 36, sourceSegment: 0)])
        XCTAssertNil(result.distanceKilometers)
        XCTAssertEqual(result.coveredDurationSeconds, 0)
        XCTAssertEqual(result.excludedIntervals, [.init(sourceSequences: [1, 2], reasons: [.sourceChanged]),
                                                 .init(sourceSequences: [2, 3], reasons: [.sourceChanged])])
    }

    func testNegativeSourceSegmentIsRejected() {
        XCTAssertThrowsError(try summary([sample(1, 0, 36, sourceSegment: -1)])) { error in
            XCTAssertEqual(error as? RecordedTripSummaryError, .invalidSourceSegment(1))
        }
    }

    func testConstantSpeedIntegratesOnlyObservedInterval() throws {
        let result = try summary([sample(1, 0, 36), sample(2, 10, 36)])
        XCTAssertEqual(try XCTUnwrap(result.distanceKilometers), 0.1, accuracy: 1e-12)
        XCTAssertEqual(result.coveredDurationSeconds, 10)
        XCTAssertEqual(result.movingDurationSeconds, 10)
        XCTAssertEqual(try XCTUnwrap(result.averageSpeedKmh), 36, accuracy: 1e-12)
        XCTAssertEqual(result.observedMaximumSpeedKmh, 36)
    }

    func testMetersPerSecondConversionIsExplicit() throws {
        let result = try summary([sample(1, 0, 10, unit: "m/s"), sample(2, 10, 10, unit: "m/s")])
        XCTAssertEqual(try XCTUnwrap(result.distanceKilometers), 0.1, accuracy: 1e-12)
    }

    func testRealZeroIsAvailableZero() throws {
        let result = try summary([sample(1, 0, 0), sample(2, 10, 0)])
        XCTAssertEqual(result.distanceKilometers, 0)
        XCTAssertEqual(result.averageSpeedKmh, 0)
        XCTAssertEqual(result.movingDurationSeconds, 0)
        XCTAssertEqual(result.coveredDurationSeconds, 10)
    }

    func testSingleReadingDoesNotImplyDistance() throws {
        let result = try summary([sample(1, 5, 36)])
        XCTAssertNil(result.distanceKilometers)
        XCTAssertEqual(result.observedMaximumSpeedKmh, 36)
    }

    func testInvalidQualityFormsBarrierInsteadOfBeingDropped() throws {
        let qualities: [SignalQuality?] = [nil, .stale, .disconnected, .invalid]
        for quality in qualities {
            let result = try summary([sample(1, 0, 36), sample(2, 5, 36, quality: quality), sample(3, 10, 36)])
            XCTAssertNil(result.distanceKilometers)
            XCTAssertEqual(result.excludedIntervals.count, 2)
        }
    }

    func testLongGapIsNotIntegrated() throws {
        XCTAssertNil(try summary([sample(1, 0, 36), sample(2, 10, 36)], gap: 5).distanceKilometers)
    }

    func testCoverageDisclosesMissingMiddle() throws {
        let result = try summary([sample(1, 0, 36), sample(2, 10, 36), sample(3, 50, 36), sample(4, 60, 36)], end: 60)
        XCTAssertEqual(try XCTUnwrap(result.distanceKilometers), 0.2, accuracy: 1e-12)
        XCTAssertEqual(result.coveredDurationSeconds, 20)
        XCTAssertEqual(result.coverageFraction, 1.0 / 3, accuracy: 1e-12)
    }

    func testOutsideWindowSamplesAreNotInterpolatedIn() throws {
        XCTAssertNil(try summary([sample(1, 0, 36), sample(2, 10, 36)], start: 5).distanceKilometers)
    }

    func testSessionAndSignalScopeMustMatch() {
        XCTAssertThrowsError(try summary([sample(1, 0, 36), sample(2, 10, 36, sessionID: "other")]))
        XCTAssertThrowsError(try summary([sample(1, 0, 36), sample(2, 10, 36, signalID: "gps-speed")]))
    }

    func testDuplicateSequenceIsRejected() {
        XCTAssertThrowsError(try summary([sample(1, 0, 36), sample(1, 10, 36)]))
    }

    func testReversedOrDuplicateTimesAreRejected() {
        XCTAssertThrowsError(try summary([sample(1, 5, 36), sample(2, 4, 36)]))
        XCTAssertThrowsError(try summary([sample(1, 5, 36), sample(2, 5, 36)]))
    }

    func testInputIsOrderedByPersistedSequence() throws {
        let result = try summary([sample(2, 10, 36), sample(1, 0, 36)])
        XCTAssertEqual(try XCTUnwrap(result.distanceKilometers), 0.1, accuracy: 1e-12)
    }

    func testNegativeAndNonfiniteSpeedsAreNotIntegrated() throws {
        for value in [-1.0, Double.nan, Double.infinity] {
            XCTAssertNil(try summary([sample(1, 0, value), sample(2, 10, 36)]).distanceKilometers)
        }
    }

    func testUnknownUnitsAreNotGuessed() throws {
        XCTAssertNil(try summary([sample(1, 0, 36, unit: "mph"), sample(2, 10, 36)]).distanceKilometers)
    }

    func testMovingThresholdCrossingUsesObservedTime() throws {
        let result = try summary([sample(1, 0, 0), sample(2, 10, 4)])
        XCTAssertEqual(result.movingDurationSeconds, 5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.distanceKilometers), 20.0 / 3600, accuracy: 1e-12)
    }

    func testNonfiniteTimestampIsRejected() {
        for time in [Double.nan, Double.infinity] {
            XCTAssertThrowsError(try summary([sample(1, time, 36)]))
        }
    }

    func testInvalidWindowAndPolicyAreRejected() {
        XCTAssertThrowsError(try summary([], start: -1))
        XCTAssertThrowsError(try summary([], start: 11))
        XCTAssertThrowsError(try summary([], end: .infinity))
        XCTAssertThrowsError(try summary([], gap: 0))
        XCTAssertThrowsError(try summary([], threshold: 0))
    }

    func testEmptyWindowStaysUnavailable() throws {
        let result = try summary([], end: 0)
        XCTAssertNil(result.distanceKilometers)
        XCTAssertNil(result.averageSpeedKmh)
        XCTAssertEqual(result.coverageFraction, 0)
    }

    func testUnrepresentablePositiveIntervalIsUnavailable() throws {
        let result = try summary([sample(1, 0, 36), sample(2, 1e-323, 36)], end: 1e-323)
        XCTAssertNil(result.distanceKilometers)
        XCTAssertNil(result.averageSpeedKmh)
    }

    func testOverflowIntervalIsExplicitlyExcluded() throws {
        let result = try summary([sample(1, 0, 1e308), sample(2, 10_000, 1e308)], end: 10_000, gap: 10_000)
        XCTAssertNil(result.distanceKilometers)
        XCTAssertEqual(result.coveredDurationSeconds, 0)
        XCTAssertEqual(result.excludedIntervals.first?.reasons, [.unrepresentableCalculation])
    }

    func testDownwardThresholdCrossingIsSplit() throws {
        let result = try summary([sample(1, 0, 4), sample(2, 10, 0)])
        XCTAssertEqual(result.movingDurationSeconds, 5, accuracy: 1e-12)
    }

    func testUnrepresentablePositiveMidpointIsUnavailable() throws {
        let result = try summary([sample(0, 0, Double.leastNonzeroMagnitude), sample(1, 1e308, 0)],
                                 end: 1e308, gap: 1e308)
        XCTAssertNil(result.distanceKilometers)
        XCTAssertNil(result.averageSpeedKmh)
        XCTAssertEqual(result.coveredDurationSeconds, 0)
        XCTAssertEqual(result.excludedIntervals, [.init(sourceSequences: [0, 1], reasons: [.unrepresentableCalculation])])
    }

    func testRepresentableTinyDurationDistanceIsNotLost() throws {
        let tiny = Double.leastNonzeroMagnitude
        let result = try summary([sample(1, 0, 1e308), sample(2, tiny, 1e308)], end: tiny)
        let distance = try XCTUnwrap(result.distanceKilometers)
        XCTAssertGreaterThan(distance, 1.3e-19)
        XCTAssertLessThan(distance, 1.4e-19)
    }

    func testDurationRoundoffStaysWithinProvenWindow() throws {
        let times: [Double] = [0.0, 2.2693756714736725e-09, 2.6928138167144225e-09, 2.4486054696852314e-06,
                              0.018658630345282833, 1.461471356098542, 3.42675616651033, 7.624625833536056,
                              99.74665206980956, 173.31103005723637, 253.2563933236103, 536.4771474060876,
                              172091.84742449663, 16201167.229855713, 26866526.910031587, 56762888.27307951,
                              137896335.0764639, 9227114544.542324, 23457606870.380356, 69757707145.88286,
                              259983544643.13095]
        let end = try XCTUnwrap(times.last)
        let result = try summary(times.enumerated().map { sample(Int64($0.offset), $0.element, 1) },
                                 end: end, gap: end, threshold: 0.5)
        XCTAssertTrue(result.excludedIntervals.isEmpty)
        XCTAssertEqual(result.coveredDurationSeconds, end)
        XCTAssertEqual(result.movingDurationSeconds, end)
        XCTAssertEqual(result.coverageFraction, 1)
    }

    func testDurationTotalOverflowIsExplicitlyExcluded() throws {
        let maximum = Double.greatestFiniteMagnitude
        let samples = [sample(1, 0, 0), sample(2, 7.074494515330672e307, 0),
                       sample(3, 7.742118557452366e307, 0), sample(4, maximum, 0)]
        let result = try summary(samples, end: maximum, gap: maximum)
        XCTAssertTrue(result.coveredDurationSeconds.isFinite)
        XCTAssertTrue(result.coverageFraction.isFinite)
        XCTAssertEqual(result.excludedIntervals.count, 1)
    }

    func testPositiveAggregateMeanUnderflowIsExcluded() throws {
        let tiny = Double.leastNonzeroMagnitude
        let result = try summary([sample(0, 0, tiny), sample(1, 1e307, tiny), sample(2, 2e307, 0), sample(3, 1e308, 0)],
                                 end: 1e308, gap: 1e308)
        let baseline = try summary([sample(0, 0, tiny), sample(1, 1e307, tiny)], end: 1e308, gap: 1e308)
        XCTAssertEqual(result.averageSpeedKmh, tiny)
        XCTAssertEqual(result.coveredDurationSeconds, 1e307)
        XCTAssertEqual(result.distanceKilometers, baseline.distanceKilometers)
        XCTAssertEqual(result.excludedIntervals, [.init(sourceSequences: [1, 2], reasons: [.unrepresentableCalculation]),
                                                 .init(sourceSequences: [2, 3], reasons: [.unrepresentableCalculation])])
    }

    func testWeightedSubnormalTermsSumBeforeRounding() throws {
        let tiny = Double.leastNonzeroMagnitude
        let result = try summary([sample(0, 0, tiny), sample(1, 1e307, tiny), sample(2, 2e307, tiny)],
                                 end: 2e307, gap: 1e307)
        XCTAssertEqual(result.averageSpeedKmh, tiny)
        XCTAssertEqual(result.coveredDurationSeconds, 2e307)
        XCTAssertGreaterThan(try XCTUnwrap(result.distanceKilometers), 0)
        XCTAssertTrue(result.excludedIntervals.isEmpty)
    }

    func testSmallEarlierWeightIsNotCancelled() throws {
        let result = try summary([sample(1, 0, 1e20), sample(2, 1, 0), sample(3, 1e20, 0)], end: 1e20, gap: 1e20)
        XCTAssertEqual(try XCTUnwrap(result.averageSpeedKmh), 0.5, accuracy: 1e-12)
    }
}
