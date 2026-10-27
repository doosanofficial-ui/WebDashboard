import XCTest
@testable import TelemetryCore

final class RecordedEnergyReplayProjectionTests: XCTestCase {
    private let origin: UInt64 = 1_000_000_000

    func testProjectionKeepsHistoricalQualityUnknownAndPassesTruncation() throws {
        let result = try project(
            voltageHistory: history([
                point(signal: .voltage, sequence: 1, session: "drive-1", nanos: origin, elapsed: 0, value: 360, unit: "V"),
                point(signal: .voltage, sequence: 3, session: "drive-1", nanos: origin + 1_000_000_000, elapsed: 1, value: 360, unit: "V")
            ], totalSamples: 3),
            currentHistory: history([
                point(signal: .current, sequence: 2, session: "drive-1", nanos: origin, elapsed: 0, value: 10, unit: "A"),
                point(signal: .current, sequence: 4, session: "drive-1", nanos: origin + 1_000_000_000, elapsed: 1, value: 10, unit: "A")
            ])
        )

        XCTAssertTrue(result.isWindowTruncated)
        XCTAssertEqual(result.summary.availability, .unavailable(.noQualifiedInterval))
        XCTAssertEqual(result.summary.validDurationSeconds, 0, accuracy: 1e-12)
        XCTAssertTrue(result.summary.excludedIntervals.flatMap(\.reasons).contains(.qualityUnknown(signal: .voltage)))
        XCTAssertTrue(result.summary.excludedIntervals.flatMap(\.reasons).contains(.qualityUnknown(signal: .current)))
    }

    func testMissingSelectedSessionAndOriginAreExplicitErrors() {
        let empty = history([])
        XCTAssertThrowsError(try project(voltageHistory: empty, currentHistory: empty, sessionID: nil)) { error in
            XCTAssertEqual(error as? RecordedEnergyReplayProjectionError, .missingSessionID)
        }
        XCTAssertThrowsError(try project(voltageHistory: empty, currentHistory: empty, originNanos: nil)) { error in
            XCTAssertEqual(error as? RecordedEnergyReplayProjectionError, .missingMonotonicOrigin)
        }
    }

    func testMissingSignalIDAndInvalidWindowAreExplicitErrors() {
        let empty = history([])
        XCTAssertThrowsError(try project(voltageHistory: empty, currentHistory: empty, voltageSignalID: nil)) { error in
            XCTAssertEqual(error as? RecordedEnergyReplayProjectionError, .missingSignalID(signal: .voltage))
        }
        XCTAssertThrowsError(try RecordedEnergyReplayProjection.summarize(
            selectedSessionID: "drive-1",
            recordedMonotonicOrigin: origin,
            voltageSignalID: "battery-voltage",
            voltageHistory: empty,
            currentSignalID: "battery-current",
            currentHistory: empty,
            selectedWindowStartSeconds: 3,
            cursorSeconds: 2,
            policy: RecordedEnergyPolicy(
                maxGapSeconds: 2,
                maxSampleSkewSeconds: 0.1,
                currentSignConvention: .positiveCurrentMeansConsumption
            )
        )) { error in
            XCTAssertEqual(error as? RecordedEnergyReplayProjectionError, .invalidAcceptedWindow)
        }
    }

    func testEveryVoltageAndCurrentRowMustBelongToSelectedSession() {
        let voltage = history([
            point(signal: .voltage, sequence: 1, session: "drive-1", nanos: origin, elapsed: 0, value: 360, unit: "V")
        ])
        let current = history([
            point(signal: .current, sequence: 2, session: "drive-2", nanos: origin, elapsed: 0, value: 10, unit: "A")
        ])

        XCTAssertThrowsError(try project(voltageHistory: voltage, currentHistory: current)) { error in
            XCTAssertEqual(error as? RecordedEnergyReplayProjectionError, .sessionMismatch(
                signal: .current,
                sourceSequence: 2,
                expectedSessionID: "drive-1",
                actualSessionID: "drive-2"
            ))
        }
    }

    func testSessionIsCheckedForEveryRowNotOnlyFirstSample() {
        let voltage = history([
            point(signal: .voltage, sequence: 1, session: "drive-1", nanos: origin, elapsed: 0, value: 360, unit: "V"),
            point(signal: .voltage, sequence: 3, session: "drive-2", nanos: origin + 1_000_000_000, elapsed: 1, value: 360, unit: "V")
        ])

        XCTAssertThrowsError(try project(voltageHistory: voltage, currentHistory: history([]))) { error in
            XCTAssertEqual(error as? RecordedEnergyReplayProjectionError, .sessionMismatch(
                signal: .voltage,
                sourceSequence: 3,
                expectedSessionID: "drive-1",
                actualSessionID: "drive-2"
            ))
        }
    }

    func testSameSignalCannotBeSelectedForBothVoltageAndCurrent() {
        let empty = history([])

        XCTAssertThrowsError(try project(
            voltageHistory: empty,
            currentHistory: empty,
            voltageSignalID: "battery-voltage",
            currentSignalID: "battery-voltage"
        )) { error in
            XCTAssertEqual(error as? RecordedEnergyReplayProjectionError, .sameSignalSelected)
        }
    }

    func testUnitMustMatchTheSelectedSignalExactly() {
        let voltage = history([
            point(signal: .voltage, sequence: 1, session: "drive-1", nanos: origin, elapsed: 0, value: 360_000, unit: "mV")
        ])

        XCTAssertThrowsError(try project(voltageHistory: voltage, currentHistory: history([]))) { error in
            XCTAssertEqual(error as? RecordedEnergyReplayProjectionError, .unexpectedUnit(
                signal: .voltage,
                signalID: "battery-voltage",
                sourceSequence: 1,
                expectedUnit: "V",
                actualUnit: "mV"
            ))
        }
    }

    func testHistoryWindowAndEveryPointMustMatchAcceptedWindow() {
        let voltageWindowMismatch = history([], start: 0.5, end: 2)
        XCTAssertThrowsError(try project(voltageHistory: voltageWindowMismatch, currentHistory: history([]))) { error in
            guard let projectionError = error as? RecordedEnergyReplayProjectionError,
                  case .historyWindowMismatch(signal: .voltage, _, _, _, _) = projectionError else {
                return XCTFail("Expected voltage history window mismatch, got \(error)")
            }
        }

        let futureDisplayPoint = history([
            point(signal: .voltage, sequence: 1, session: "drive-1", nanos: origin + 2_100_000_000, elapsed: 2.1, value: 360, unit: "V")
        ])
        XCTAssertThrowsError(try project(voltageHistory: futureDisplayPoint, currentHistory: history([]))) { error in
            guard let projectionError = error as? RecordedEnergyReplayProjectionError,
                  case .pointOutsideAcceptedWindow(signal: .voltage, sourceSequence: 1, _) = projectionError else {
                return XCTFail("Expected future display point rejection, got \(error)")
            }
        }
    }

    func testMonotonicOriginUnderflowAndCursorOverflowAreExplicit() {
        let underflow = history([
            point(signal: .voltage, sequence: 1, session: "drive-1", nanos: origin - 1, elapsed: 0, value: 360, unit: "V")
        ])
        XCTAssertThrowsError(try project(voltageHistory: underflow, currentHistory: history([]))) { error in
            guard let projectionError = error as? RecordedEnergyReplayProjectionError,
                  case .monotonicUnderflow(signal: .voltage, sourceSequence: 1, _, _) = projectionError else {
                return XCTFail("Expected receive-monotonic underflow, got \(error)")
            }
        }

        let futureRawTime = history([
            point(signal: .voltage, sequence: 1, session: "drive-1", nanos: origin + 2_100_000_000, elapsed: 1, value: 360, unit: "V")
        ])
        XCTAssertThrowsError(try project(voltageHistory: futureRawTime, currentHistory: history([]))) { error in
            guard let projectionError = error as? RecordedEnergyReplayProjectionError,
                  case .rawTimestampOutsideAcceptedWindow(signal: .voltage, sourceSequence: 1, _, _, _) = projectionError else {
                return XCTFail("Expected raw future timestamp rejection, got \(error)")
            }
        }
    }

    func testCrossSignalSourceTimestampRollbackIsReturnedAsProjectionError() {
        let voltage = history([
            point(signal: .voltage, sequence: 1, session: "drive-1", nanos: origin, elapsed: 0, value: 360, unit: "V"),
            point(signal: .voltage, sequence: 3, session: "drive-1", nanos: origin + 500_000_000, elapsed: 1, value: 360, unit: "V")
        ])
        let current = history([
            point(signal: .current, sequence: 2, session: "drive-1", nanos: origin + 1_000_000_000, elapsed: 1, value: 10, unit: "A"),
            point(signal: .current, sequence: 4, session: "drive-1", nanos: origin + 1_500_000_000, elapsed: 1.5, value: 10, unit: "A")
        ])

        XCTAssertThrowsError(try project(voltageHistory: voltage, currentHistory: current)) { error in
            guard let projectionError = error as? RecordedEnergyReplayProjectionError,
                  case let .timestampRollback(previousSignal, signal, previousSequence, _, currentSequence, _) = projectionError,
                  previousSignal == .current, signal == .voltage,
                  previousSequence == 2, currentSequence == 3 else {
                return XCTFail("Expected cross-signal rollback, got \(error)")
            }
        }
    }

    func testDistinctSignalIDsArePreservedAndMissingRowsStayUnavailable() throws {
        let result = try project(
            voltageHistory: history([]),
            currentHistory: history([]),
            voltageSignalID: "front-pack-voltage",
            currentSignalID: "rear-pack-current"
        )

        XCTAssertEqual(result.voltageSignalID, "front-pack-voltage")
        XCTAssertEqual(result.currentSignalID, "rear-pack-current")
        XCTAssertEqual(result.summary.availability, .unavailable(.noQualifiedInterval))
    }

    private func project(
        voltageHistory: MeasurementReplay.SignalHistory?,
        currentHistory: MeasurementReplay.SignalHistory?,
        sessionID: String? = "drive-1",
        originNanos: UInt64? = 1_000_000_000,
        voltageSignalID: String? = "battery-voltage",
        currentSignalID: String? = "battery-current",
        windowStartSeconds: Double = 0,
        cursorSeconds: Double = 2
    ) throws -> RecordedEnergyReplayProjection.Result {
        try RecordedEnergyReplayProjection.summarize(
            selectedSessionID: sessionID,
            recordedMonotonicOrigin: originNanos,
            voltageSignalID: voltageSignalID,
            voltageHistory: voltageHistory,
            currentSignalID: currentSignalID,
            currentHistory: currentHistory,
            selectedWindowStartSeconds: windowStartSeconds,
            cursorSeconds: cursorSeconds,
            policy: RecordedEnergyPolicy(
                maxGapSeconds: 2,
                maxSampleSkewSeconds: 0.1,
                currentSignConvention: .positiveCurrentMeansConsumption
            )
        )
    }

    private func history(
        _ samples: [MeasurementReplay.RecordedSignalPoint],
        totalSamples: Int? = nil,
        start: Double = 0,
        end: Double = 2
    ) -> MeasurementReplay.SignalHistory {
        MeasurementReplay.SignalHistory(
            samples: samples,
            totalSamplesInWindow: totalSamples ?? samples.count,
            startSeconds: start,
            endSeconds: end
        )
    }

    private func point(
        signal: RecordedEnergySignal,
        sequence: Int64,
        session: String,
        nanos: UInt64,
        elapsed: Double,
        value: Double,
        unit: String
    ) -> MeasurementReplay.RecordedSignalPoint {
        let measurement = PersistedMeasurement(
            sequence: sequence,
            sessionID: session,
            kind: "SIGNAL",
            sourceTimestamp: Double(nanos) / 1_000_000_000,
            receivedAtEpoch: Double(nanos) / 1_000_000_000,
            receivedAtMonotonicNanos: nanos,
            payloadJSON: "{}"
        )
        return MeasurementReplay.RecordedSignalPoint(
            elapsedSeconds: elapsed,
            value: value,
            unit: unit,
            source: .init(kind: "recorded", adapter: nil, transport: nil),
            sourceSegment: 0,
            measurement: measurement
        )
    }
}
