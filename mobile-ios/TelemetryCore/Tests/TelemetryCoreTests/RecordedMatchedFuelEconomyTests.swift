import XCTest
@testable import TelemetryCore

final class RecordedMatchedFuelEconomyTests: XCTestCase {
    // Sequence slots in one synthetic canonical archive; timestamp ties are distinct rows.
    private func sequence(_ time: Double, fuel: Bool) -> Int64 {
        let times: [Double] = [0, .leastNonzeroMagnitude, 1, 3, 5, 7, 8, 10, 15, 20, 30, 9e307, 1e308, 1.7e308]
        return Int64(2 * times.prefix { $0 < time }.count + (fuel ? 1 : 0))
    }
    private func s(_ times: [Double] = [0, 10], _ values: [Double]? = nil,
                   unit: String = "km/h", quality: SignalQuality? = .valid,
                   segments: [Int]? = nil, sequences: [Int64]? = nil,
                   session: String = "s", signal: String = "speed") -> [RecordedTripObservation] {
        times.enumerated().map { i, t in
            .init(sessionID: session, signalID: signal, sourceSegment: segments?[i] ?? 0,
                  sourceSequence: sequences?[i] ?? sequence(t, fuel: false), timestampSeconds: t,
                  value: values?[i] ?? 60, unit: unit, quality: quality)
        }
    }
    private func f(_ times: [Double] = [0, 10], _ values: [Double?]? = nil,
                   unit: String = "L/h", quality: SignalQuality? = .valid) -> [RecordedFuelObservation] {
        times.enumerated().map { i, t in
            .init(sessionID: "s", signalID: "fuel", sourceSegment: 0,
                  sourceSequence: sequence(t, fuel: true), timestampSeconds: t,
                  value: values == nil ? 6 : values![i], unit: unit, quality: quality)
        }
    }
    private func calculateEconomy(_ speed: [RecordedTripObservation]? = nil, _ fuel: [RecordedFuelObservation]? = nil,
                     start: Double = 0, end: Double = 10_000, speedGap: Double = 30,
                     fuelGap: Double = 30, limit: Int = 200_000) throws -> RecordedMatchedFuelEconomy {
        try RecordedMatchedFuelEconomyCalculator.calculate(speedObservations: speed ?? s(),
            fuelObservations: fuel ?? f(), sessionID: "s", speedSignalID: "speed", fuelSignalID: "fuel",
            startSeconds: start, endSeconds: end,
            policy: .init(maximumSpeedIntervalSeconds: speedGap, maximumFuelIntervalSeconds: fuelGap,
                          maximumTotalObservations: limit))
    }
    func testConstant() throws { XCTAssertEqual(try XCTUnwrap(calculateEconomy().litersPer100Kilometers), 10, accuracy: 1e-12) }
    func testDisjoint() throws { XCTAssertNil(try calculateEconomy(nil, f([20, 30])).litersPer100Kilometers) }
    func testPartial() throws {
        let r = try calculateEconomy(nil, f([5, 15]))
        XCTAssertEqual(try XCTUnwrap(r.distanceKilometers), 60 * 5 / 3600, accuracy: 1e-12)
        XCTAssertEqual(r.coveredDurationSeconds, 5)
    }
    func testDifferentCadences() throws {
        let r = try calculateEconomy(s([0, 10, 20]), f([5, 8, 15]))
        XCTAssertEqual(try XCTUnwrap(r.litersPer100Kilometers), 10, accuracy: 1e-12)
        XCTAssertEqual(r.matchedIntervals.count, 3)
        XCTAssertEqual(r.coveredDurationSeconds, 10)
    }
    func testLinear() throws {
        XCTAssertEqual(try XCTUnwrap(calculateEconomy(s([0, 10], [0, 100]), f([5, 10], [10, 10])).litersPer100Kilometers), 1000 / 75, accuracy: 1e-12)
    }
    func testZeroDistance() throws {
        let r = try calculateEconomy(s([0, 10], [0, 0]))
        XCTAssertNil(r.litersPer100Kilometers); XCTAssertEqual(r.unavailableReason, .zeroMatchedDistance)
    }
    func testObservedZeroFuel() throws { XCTAssertEqual(try calculateEconomy(nil, f([0, 10], [0, 0])).litersPer100Kilometers, 0) }
    func testMissing() throws { XCTAssertNil(try calculateEconomy(nil, f([0, 10], [nil, 6])).litersPer100Kilometers) }
    func testInvalidBarrier() throws {
        let fuel = [f([0])[0], f([5], quality: nil)[0], f([10])[0]].enumerated().map { i, p in
            RecordedFuelObservation(sessionID: p.sessionID, signalID: p.signalID,
                sourceSegment: p.sourceSegment, sourceSequence: sequence(p.timestampSeconds, fuel: true), timestampSeconds: p.timestampSeconds,
                value: p.value, unit: p.unit, quality: p.quality)
        }
        XCTAssertNil(try calculateEconomy(nil, fuel).litersPer100Kilometers)
    }
    func testUnknownQuality() throws { XCTAssertNil(try calculateEconomy(nil, f(quality: nil)).litersPer100Kilometers) }
    func testSourceBarrier() throws { XCTAssertNil(try calculateEconomy(s(segments: [0, 1])).litersPer100Kilometers) }
    func testGap() throws { XCTAssertNil(try calculateEconomy(speedGap: 9).litersPer100Kilometers) }
    func testFuelGap() throws { XCTAssertNil(try calculateEconomy(fuelGap: 9).litersPer100Kilometers) }
    func testUnits() throws {
        XCTAssertEqual(try XCTUnwrap(calculateEconomy(s([0, 10], [10, 10], unit: "m/s")).litersPer100Kilometers), 100 / 6, accuracy: 1e-12)
    }
    func testUnknownUnit() throws { XCTAssertNil(try calculateEconomy(nil, f(unit: "g/s")).litersPer100Kilometers) }
    func testBadValue() throws {
        for x in [-1, Double.infinity, Double.nan] { XCTAssertNil(try calculateEconomy(s([0, 10], [x, 60])).litersPer100Kilometers) }
    }
    func testDuplicateSequence() { XCTAssertThrowsError(try calculateEconomy(s(sequences: [0, 0]), [])) }
    func testDuplicateTime() { XCTAssertThrowsError(try calculateEconomy(s([0, 0]))) }
    func testRollback() { XCTAssertThrowsError(try calculateEconomy(s([10, 0], sequences: [0, 2]))) }
    func testMixedScope() { XCTAssertThrowsError(try calculateEconomy(s(session: "other"))) }
    func testMixedSignal() { XCTAssertThrowsError(try calculateEconomy(s(signal: "other"))) }
    func testBadSegment() { XCTAssertThrowsError(try calculateEconomy(s(segments: [-1, 0]))) }
    func testBadTimestamp() {
        for t in [-1, Double.infinity, Double.nan] { XCTAssertThrowsError(try calculateEconomy(s([t, 10]))) }
    }
    func testLimit() { XCTAssertThrowsError(try calculateEconomy(limit: 3)) }
    func testPolicy() {
        for gap in [0, -1, Double.infinity, Double.nan] { XCTAssertThrowsError(try calculateEconomy(speedGap: gap)) }
    }
    func testWindow() throws {
        let r = try calculateEconomy(start: 3, end: 7)
        XCTAssertEqual(r.coveredDurationSeconds, 4); XCTAssertEqual(r.matchedIntervals.first?.startSeconds, 3)
    }
    func testBadWindow() { XCTAssertThrowsError(try calculateEconomy(start: 10, end: 0)) }
    func testEmpty() throws { XCTAssertNil(try calculateEconomy([]).distanceKilometers) }
    func testProvenance() throws {
        let m = try XCTUnwrap(calculateEconomy().matchedIntervals.first)
        XCTAssertEqual(m.speedStart, s()[0]); XCTAssertEqual(m.speedEnd, s()[1])
        XCTAssertEqual(m.fuelStart, f()[0]); XCTAssertEqual(m.fuelEnd, f()[1])
    }
    func testUnsortedSequence() throws {
        let expected = try calculateEconomy()
        XCTAssertEqual(try calculateEconomy(Array(s().reversed())).litersPer100Kilometers, expected.litersPer100Kilometers)
    }
    func testTinyDurationLargeRates() throws {
        let t = Double.leastNonzeroMagnitude
        let r = try calculateEconomy(s([0, t], [1e300, 1e300]), f([0, t], [1e299, 1e299]))
        XCTAssertEqual(try XCTUnwrap(r.litersPer100Kilometers), 10, accuracy: 1e-12)
    }
    func testOverflowRejectedJointly() throws {
        let r = try calculateEconomy(s([0, 1e308], [1e308, 1e308]), f([0, 1e308], [1, 1]),
                        end: 1e308, speedGap: 1e308, fuelGap: 1e308)
        XCTAssertNil(r.distanceKilometers); XCTAssertEqual(r.numericRejectedCommonIntervalCount, 1)
    }
    func testUnderflowNotZero() throws {
        XCTAssertNil(try calculateEconomy(nil, f([0, 10], [Double.leastNonzeroMagnitude, Double.leastNonzeroMagnitude])).litersPer100Kilometers)
    }
    func testRatioOverflow() throws {
        let r = try calculateEconomy(s([0, 10], [1e-300, 1e-300]), f([0, 10], [1e300, 1e300]))
        XCTAssertNil(r.litersPer100Kilometers); XCTAssertNotNil(r.distanceKilometers)
        XCTAssertEqual(r.unavailableReason, .unrepresentableRatio)
    }
    func testTouchingNotOverlap() throws { XCTAssertNil(try calculateEconomy(nil, f([10, 20])).litersPer100Kilometers) }
    func testLargeTimestampDurationSum() throws {
        let t: [Double] = [0, 9e307, 1.7e308]
        let r = try calculateEconomy(s(t, [1, 1, 1]), f(t, [0.1, 0.1, 0.1]), end: t[2], speedGap: 1e308, fuelGap: 1e308)
        XCTAssertEqual(r.matchedIntervals.count, 2); XCTAssertEqual(r.numericRejectedCommonIntervalCount, 0)
    }
    func testNegativeSequence() { XCTAssertThrowsError(try calculateEconomy(s(sequences: [-1, 1]))) }
    func testHardLimit() { XCTAssertThrowsError(try calculateEconomy(limit: 200_001)) }
    func testZeroLimit() { XCTAssertThrowsError(try calculateEconomy(limit: 0)) }
    func testSameSignal() {
        XCTAssertThrowsError(try RecordedMatchedFuelEconomyCalculator.calculate(speedObservations: s(),
            fuelObservations: f(), sessionID: "s", speedSignalID: "speed", fuelSignalID: "speed",
            startSeconds: 0, endSeconds: 10,
            policy: .init(maximumSpeedIntervalSeconds: 30, maximumFuelIntervalSeconds: 30)))
    }
    func testNoBridgeAfterBadRow() throws {
        let original = s([0, 5, 10, 15])
        let speed = original.enumerated().map { i, p in
            RecordedTripObservation(sessionID: p.sessionID, signalID: p.signalID,
                sourceSegment: p.sourceSegment, sourceSequence: p.sourceSequence, timestampSeconds: p.timestampSeconds,
                value: p.value, unit: p.unit, quality: i == 1 ? nil : p.quality)
        }
        let r = try calculateEconomy(speed, f([0, 15]))
        XCTAssertEqual(r.coveredDurationSeconds, 5); XCTAssertEqual(r.matchedIntervals.first?.speedStart.sourceSequence, 14)
    }
    func testSubnormalRateLongDuration() throws {
        let t: [Double] = [0, 1e308], v = Double.leastNonzeroMagnitude
        let r = try calculateEconomy(s(t, [v, v]), f(t, [v, v]), end: t[1], speedGap: 1e308, fuelGap: 1e308)
        XCTAssertEqual(try XCTUnwrap(r.litersPer100Kilometers), 100, accuracy: 1e-12)
    }
    func testRatioUnderflowUnavailable() throws {
        let r = try calculateEconomy(s([0, 10], [1e300, 1e300]), f([0, 10], [1e-300, 1e-300]))
        XCTAssertNotNil(r.fuelLiters); XCTAssertNil(r.litersPer100Kilometers)
    }
    func testCrossSignalSequenceCollision() {
        let original = f()
        let fuel = original.enumerated().map { i, p in
            RecordedFuelObservation(sessionID: p.sessionID, signalID: p.signalID,
                sourceSegment: p.sourceSegment, sourceSequence: i == 0 ? 0 : p.sourceSequence,
                timestampSeconds: p.timestampSeconds, value: p.value, unit: p.unit, quality: p.quality)
        }
        XCTAssertThrowsError(try calculateEconomy(nil, fuel)) { error in
            XCTAssertEqual(error as? RecordedMatchedFuelEconomyError, .crossSignalSequenceCollision(0))
        }
    }
    func testCrossSignalCollisionOutsideWindow() {
        let original = f([20, 30])
        let fuel = original.enumerated().map { i, p in
            RecordedFuelObservation(sessionID: p.sessionID, signalID: p.signalID,
                sourceSegment: p.sourceSegment, sourceSequence: i == 1 ? 14 : p.sourceSequence,
                timestampSeconds: p.timestampSeconds, value: p.value, unit: p.unit, quality: p.quality)
        }
        XCTAssertThrowsError(try calculateEconomy(nil, fuel, end: 10)) { error in
            XCTAssertEqual(error as? RecordedMatchedFuelEconomyError, .crossSignalSequenceCollision(14))
        }
    }
    func testCrossSignalTimestampRollback() {
        let original = f([5, 15])
        let fuel = original.enumerated().map { i, p in
            RecordedFuelObservation(sessionID: p.sessionID, signalID: p.signalID,
                sourceSegment: p.sourceSegment, sourceSequence: i == 0 ? 16 : p.sourceSequence,
                timestampSeconds: p.timestampSeconds, value: p.value, unit: p.unit, quality: p.quality)
        }
        XCTAssertThrowsError(try calculateEconomy(nil, fuel)) { error in
            XCTAssertEqual(error as? RecordedMatchedFuelEconomyError,
                .globalTimestampRollback(previousSequence: 14, previousSeconds: 10, currentSequence: 16, currentSeconds: 5))
        }
    }
    func testCrossSignalEqualTimestampsValid() throws {
        XCTAssertEqual(try XCTUnwrap(calculateEconomy().litersPer100Kilometers), 10, accuracy: 1e-12)
    }
}
