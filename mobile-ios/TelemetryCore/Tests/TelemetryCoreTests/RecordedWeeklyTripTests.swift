import XCTest
@testable import TelemetryCore

final class RecordedWeeklyTripTests: XCTestCase {
    private let source = WeeklyTripProvenance(signalID: "speed", sourceUnit: .kilometersPerHour, policyRevision: "gap2-v1")
    private func bounds(_ a: Double = 0, _ b: Double = 100, _ c: Double = 200,
                        zone: String = "UTC") -> VerifiedWeekPair {
        .init(priorStartUTC: a, currentStartUTC: b, currentEndUTC: c, timeZoneIdentifier: zone,
              calendarIdentifier: "gregorian", firstWeekday: 2, minimumDaysInFirstWeek: 4)
    }
    private func row(_ session: String = "s", scope: String = "archive-v1", start: Double = 10,
                     end: Double = 20, covered: Double = 10, distance: Double? = 1,
                     average: Double? = 360, excluded: Int = 0,
                     provenance: WeeklyTripProvenance? = nil) -> QualifiedWeeklyTrip {
        .init(sessionKey: session, archiveScopeKey: scope, provenance: provenance ?? source,
              startUTC: start, endUTC: end, coveredSeconds: covered,
              distanceKilometers: distance, averageSpeedKmh: average, excludedIntervalCount: excluded)
    }
    private func calculate(_ rows: [QualifiedWeeklyTrip], _ weeks: VerifiedWeekPair? = nil) throws -> WeeklyTripComparison {
        try RecordedWeeklyTripCalculator.calculate(rows, weeks: weeks ?? bounds(), selected: source)
    }
    func testEmptyIsUnavailable() throws {
        let result = try calculate([]).prior
        XCTAssertNil(result.distanceKilometers); XCTAssertNil(result.averageSpeedKmh)
        XCTAssertEqual(result.qualifiedSessionCount, 0)
    }
    func testTrueZero() throws {
        let result = try calculate([row(distance: 0, average: 0)]).prior
        XCTAssertEqual(result.distanceKilometers, 0); XCTAssertEqual(result.averageSpeedKmh, 0)
    }
    func testDurationWeightedAverage() throws {
        let result = try calculate([row(), row("b", start: 20, end: 50, covered: 30, average: 120)]).prior
        XCTAssertEqual(try XCTUnwrap(result.averageSpeedKmh), 180, accuracy: 1e-10)
    }
    func testExactDuplicateIgnored() throws {
        let result = try calculate([row(), row()]).prior
        XCTAssertEqual(result.distanceKilometers, 1); XCTAssertEqual(result.duplicateCount, 1)
    }
    func testConflictingDuplicateRejectsBoth() throws {
        let result = try calculate([row(), row(distance: 2, average: 720)]).prior
        XCTAssertNil(result.distanceKilometers); XCTAssertEqual(result.exclusions[.overlap], 2)
    }
    func testCrossScopeOverlapRejectsBoth() throws {
        let result = try calculate([row(), row(scope: "other", start: 15, end: 25)]).prior
        XCTAssertEqual(result.exclusions[.overlap], 2)
    }
    func testAdjacentWindowsOneSession() throws {
        let result = try calculate([row(), row(start: 20, end: 30)]).prior
        XCTAssertEqual(result.qualifiedSessionCount, 1); XCTAssertEqual(result.distanceKilometers, 2)
    }
    func testHalfOpenBoundary() throws {
        let result = try calculate([row(start: 90, end: 100), row(start: 100, end: 110)])
        XCTAssertEqual(result.prior.distanceKilometers, 1); XCTAssertEqual(result.current.distanceKilometers, 1)
    }
    func testCrossBoundaryNeverProrates() throws {
        let result = try calculate([row(start: 95, end: 105)])
        XCTAssertNil(result.prior.distanceKilometers); XCTAssertNil(result.current.distanceKilometers)
        XCTAssertEqual(result.prior.exclusions[.boundaryRequiresBoundedSummary], 1)
        XCTAssertEqual(result.current.exclusions[.boundaryRequiresBoundedSummary], 1)
    }
    func testUnavailableCoverage() throws {
        let result = try calculate([row(covered: 0, distance: nil, average: nil, excluded: 3)]).prior
        XCTAssertNil(result.distanceKilometers); XCTAssertEqual(result.upstreamExcludedIntervalCount, 3)
        XCTAssertEqual(result.coverageFraction, 0); XCTAssertEqual(result.qualifiedSessionCount, 0)
    }
    func testSourceMismatch() throws {
        let other = WeeklyTripProvenance(signalID: "rpm", sourceUnit: .kilometersPerHour, policyRevision: "gap2-v1")
        XCTAssertEqual(try calculate([row(provenance: other)]).prior.exclusions[.provenanceMismatch], 1)
    }
    func testInvalidNumbers() throws {
        for number in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(try calculate([row(covered: number)]).unallocatedInvalidInputCount, 1)
        }
        XCTAssertEqual(try calculate([row(covered: 11)]).unallocatedInvalidInputCount, 1)
    }
    func testCoverageIsSummaryWindowCoverageNotWeekCoverage() throws {
        let result = try calculate([row(end: 30)]).prior
        XCTAssertEqual(result.coverageFraction, 0.5); XCTAssertEqual(result.summaryWindowSeconds, 20)
    }
    func testBoundsRejected() {
        XCTAssertThrowsError(try calculate([], bounds(0, 0, 200)))
        XCTAssertThrowsError(try calculate([], bounds(0, .infinity, 200)))
        XCTAssertThrowsError(try calculate([], bounds(zone: "")))
    }
    func testSuppliedDSTBoundsNotFixedSeconds() throws {
        let spring = try calculate([], bounds(0, 167 * 3600, (167 + 168) * 3600, zone: "America/New_York"))
        XCTAssertEqual(spring.prior.endUTC - spring.prior.startUTC, 167 * 3600)
        let fall = try calculate([], bounds(0, 169 * 3600, (169 + 168) * 3600, zone: "America/New_York"))
        XCTAssertEqual(fall.prior.endUTC - fall.prior.startUTC, 169 * 3600)
    }
    func testSumOverflowFailsClosed() {
        XCTAssertThrowsError(try calculate([row(distance: 1e308), row("b", distance: 1e308)]))
    }
    func testLargeWeightedMeanDoesNotOverflow() throws {
        XCTAssertEqual(try calculate([row(average: 1e308), row("b", average: 1e308)]).prior.averageSpeedKmh, 1e308)
    }
    func testInputLimit() throws {
        let allowed = Array(repeating: row(), count: 2000)
        XCTAssertEqual(try calculate(allowed).prior.duplicateCount, 1999)
        XCTAssertThrowsError(try calculate(allowed + [row()]))
    }
    func testExcludedCountOverflow() throws {
        XCTAssertEqual(try calculate([row(excluded: Int.max)]).prior.upstreamExcludedIntervalCount, Int.max)
        XCTAssertThrowsError(try calculate([row(excluded: Int.max), row("b", excluded: 1)]))
    }
    func testPositiveSubnormalTermsSumBeforeRounding() throws {
        let least = Double.leastNonzeroMagnitude
        let rows = [row("a", start: 0, end: 1e307, covered: 1e307,
                        distance: least * 1e307 / 3600, average: least),
                    row("b", scope: "other", start: 1e307, end: 2e307, covered: 1e307,
                        distance: least * 1e307 / 3600, average: least)]
        XCTAssertEqual(try calculate(rows, bounds(0, 2e307, 4e307)).prior.averageSpeedKmh, least)
    }
    func testPositiveUnrepresentableMeanIsNotZero() {
        let least = Double.leastNonzeroMagnitude
        let rows = [row("a", start: 0, end: 1e307, covered: 1e307,
                        distance: least * 1e307 / 3600, average: least),
                    row("b", start: 1e307, end: 4e307, covered: 3e307, distance: 0, average: 0)]
        XCTAssertThrowsError(try calculate(rows, bounds(0, 4e307, 8e307)))
    }
    func testPermutationInvariant() throws {
        let rows = [row(), row(scope: "other", start: 15, end: 25), row("b")]
        XCTAssertEqual(try calculate(rows), try calculate(Array(rows.reversed())))
    }
}
