import XCTest
@testable import TelemetryCore

final class RecordedTripReplayProjectionTests: XCTestCase {
    private func point(_ sequence: Int64 = 1, nanos: UInt64 = 1_000_000_000,
                       elapsed: Double = 0, session: String = "drive-1", value: Double = 36,
                       unit: String = "km/h", quality: SignalQuality? = .valid,
                       segment: Int = 0, source: String = "recorded") -> MeasurementReplay.RecordedSignalPoint {
        let row = PersistedMeasurement(sequence: sequence, sessionID: session, kind: "SIGNAL",
            sourceTimestamp: Double(nanos) / 1_000_000_000,
            receivedAtEpoch: Double(nanos) / 1_000_000_000,
            receivedAtMonotonicNanos: nanos, payloadJSON: "{}")
        return MeasurementReplay.RecordedSignalPoint(elapsedSeconds: elapsed, value: value,
            unit: unit, source: .init(kind: source, adapter: nil, transport: nil),
            recordedQuality: quality, sourceSegment: segment, measurement: row)
    }
    private func history(_ points: [MeasurementReplay.RecordedSignalPoint] = [], total: Int? = nil,
                         start: Double = 0, end: Double = 2) -> MeasurementReplay.SignalHistory {
        .init(samples: points, totalSamplesInWindow: total ?? points.count, startSeconds: start, endSeconds: end)
    }
    private func project(_ history: MeasurementReplay.SignalHistory? = nil,
                         session: String? = "drive-1", signal: String? = "speed",
                         origin: UInt64? = 1_000_000_000, start: Double = 0, end: Double = 2,
                         gap: Double = 2, threshold: Double = 1) throws -> RecordedTripReplayProjection.Result {
        try RecordedTripReplayProjection.summarize(selectedSessionID: session,
            recordedMonotonicOrigin: origin, speedSignalID: signal, speedHistory: history,
            selectedWindowStartSeconds: start, cursorSeconds: end,
            policy: .init(maxGapSeconds: gap, movingThresholdKmh: threshold))
    }
    private func assertFailure(_ expected: RecordedTripReplayProjectionError,
                               _ action: @autoclosure () throws -> RecordedTripReplayProjection.Result,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? RecordedTripReplayProjectionError, expected, file: file, line: line)
        }
    }
    func testValidAndEvidence() throws {
        let rows = [point(), point(2, nanos: 2_000_000_000, elapsed: 1)]
        let result = try project(history(rows))
        XCTAssertEqual(try XCTUnwrap(result.summary.distanceKilometers), 0.01, accuracy: 1e-12)
        XCTAssertEqual(result.evidence, rows)
        XCTAssertEqual(result.speedSignalID, "speed")
    }
    func testUnits() throws {
        let result = try project(history([point(value: 10, unit: "m/s"),
            point(2, nanos: 2_000_000_000, elapsed: 1, value: 10, unit: "m/s")]))
        XCTAssertEqual(try XCTUnwrap(result.summary.distanceKilometers), 0.01, accuracy: 1e-12)
    }
    func testEmptyAndMissing() throws {
        XCTAssertNil(try project().summary.distanceKilometers)
        XCTAssertNil(try project(history()).summary.distanceKilometers)
    }
    func testZero() throws {
        XCTAssertEqual(try project(history([point(value: 0),
            point(2, nanos: 2_000_000_000, elapsed: 1, value: 0)])).summary.distanceKilometers, 0)
    }
    func testMissingMetadata() {
        assertFailure(.missingSessionID, try project(session: nil))
        assertFailure(.missingSignalID, try project(signal: ""))
        assertFailure(.missingMonotonicOrigin, try project(origin: nil))
    }
    func testSessionSwitch() {
        assertFailure(.sessionMismatch(2), try project(history([point(),
            point(2, nanos: 2_000_000_000, elapsed: 1, session: "drive-2")])))
    }
    func testUnitMismatch() { assertFailure(.unexpectedUnit(1), try project(history([point(unit: "mph")]))) }
    func testWindow() { assertFailure(.historyWindowMismatch, try project(history(start: 1))) }
    func testInvalidWindow() { assertFailure(.invalidAcceptedWindow, try project(start: -1)) }
    func testInvalidPolicy() {
        assertFailure(.summary(.invalidPolicy), try project(gap: 0))
        assertFailure(.summary(.invalidPolicy), try project(threshold: .nan))
    }
    func testRawRollbackDespiteIncreasingDisplayTime() {
        // A different signal at raw 1.5 s between these speed rows makes the
        // display clamp advance to 1.5 although speed's raw time rolled to 0.5.
        assertFailure(.summary(.nonIncreasingTimestamp(2)), try project(history([
            point(nanos: 2_000_000_000, elapsed: 1),
            point(2, nanos: 1_500_000_000, elapsed: 1.5)])))
    }
    func testActualDisplayClamp() {
        assertFailure(.summary(.nonIncreasingTimestamp(2)), try project(history([
            point(nanos: 2_000_000_000, elapsed: 1),
            point(2, nanos: 1_500_000_000, elapsed: 1)])))
    }
    func testRawWindow() { assertFailure(.rawTimestampOutsideAcceptedWindow(1), try project(history([point(nanos: 4_000_000_000)]))) }
    func testDisplayWindow() { assertFailure(.pointOutsideAcceptedWindow(1), try project(history([point(elapsed: 3)]))) }
    func testOriginUnderflow() { assertFailure(.monotonicUnderflow(1), try project(history([point(nanos: 999_999_999)]))) }
    func testSourceRetained() throws {
        let rows = [point(), point(2, nanos: 2_000_000_000, elapsed: 1, segment: 1, source: "diagnostic")]
        let result = try project(history(rows))
        XCTAssertNil(result.summary.distanceKilometers)
        XCTAssertTrue(result.summary.excludedIntervals.flatMap(\.reasons).contains(.sourceChanged))
        XCTAssertEqual(result.evidence, rows)
    }
    func testSourceMissing() { assertFailure(.missingSource(1), try project(history([point(source: "")]))) }
    func testSourceSegmentNegative() { assertFailure(.summary(.invalidSourceSegment(1)), try project(history([point(segment: -1)]))) }
    func testSourceInconsistent() {
        assertFailure(.inconsistentSourceSegment(2), try project(history([point(),
            point(2, nanos: 2_000_000_000, elapsed: 1, source: "diagnostic")])))
    }
    func testUnknownQuality() throws {
        let result = try project(history([point(quality: nil), point(2, nanos: 2_000_000_000, elapsed: 1)]))
        XCTAssertNil(result.summary.distanceKilometers)
        XCTAssertNil(result.evidence.first?.recordedQuality)
    }
    func testTruncated() throws {
        let result = try project(history([point(), point(2, nanos: 2_000_000_000, elapsed: 1)], total: 4))
        XCTAssertTrue(result.isWindowTruncated)
        XCTAssertEqual(result.totalSamplesInWindow, 4)
    }
    func testBadCount() { assertFailure(.invalidHistoryCount, try project(history([point()], total: 0))) }
    func testDuplicate() {
        assertFailure(.summary(.duplicateSequence(1)), try project(history([point(), point(nanos: 2_000_000_000, elapsed: 1)])))
    }
    func testGap() throws {
        XCTAssertNil(try project(history([point(), point(2, nanos: 2_000_000_000, elapsed: 1)]), gap: 0.5).summary.distanceKilometers)
    }
}
