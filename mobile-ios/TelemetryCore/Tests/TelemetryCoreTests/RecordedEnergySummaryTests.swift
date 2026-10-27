import XCTest
@testable import TelemetryCore

final class RecordedEnergySummaryTests: XCTestCase {
    func testConstantRecordedPowerIntegratesToOneHundredthKilowattHour() throws {
        let summary = try calculate(constantSamples(voltage: 360, current: 10, from: 0, through: 10))

        XCTAssertEqual(summary.consumedKWh, 0.01, accuracy: 1e-12)
        XCTAssertEqual(summary.regeneratedKWh, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.signedKWh, 0.01, accuracy: 1e-12)
        XCTAssertEqual(summary.validDurationSeconds, 10, accuracy: 1e-12)
        XCTAssertTrue(summary.excludedIntervals.isEmpty)
        XCTAssertEqual(summary.availability, .available)
    }

    func testNegativeCurrentIsRegenerationWhenPositiveCurrentMeansConsumption() throws {
        let observations = constantSamples(voltage: 360, current: -10, from: 0, through: 10)
        let summary = try calculate(observations)

        XCTAssertEqual(summary.consumedKWh, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.regeneratedKWh, 0.01, accuracy: 1e-12)
        XCTAssertEqual(summary.signedKWh, -0.01, accuracy: 1e-12)
    }

    func testCurrentSignConventionIsExplicit() throws {
        let summary = try calculate(
            constantSamples(voltage: 360, current: -10, from: 0, through: 10),
            convention: .negativeCurrentMeansConsumption
        )

        XCTAssertEqual(summary.consumedKWh, 0.01, accuracy: 1e-12)
        XCTAssertEqual(summary.regeneratedKWh, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.currentSignConvention, .negativeCurrentMeansConsumption)
    }

    func testTrapezoidCrossingZeroReportsConsumptionAndRegenerationSeparately() throws {
        let summary = try calculate([
            sample(.voltage, 0, 360, "V", 1), sample(.current, 0, 10, "A", 2),
            sample(.voltage, 10, 360, "V", 3), sample(.current, 10, -10, "A", 4)
        ], maxGapSeconds: 10)

        XCTAssertEqual(summary.consumedKWh, 0.0025, accuracy: 1e-12)
        XCTAssertEqual(summary.regeneratedKWh, 0.0025, accuracy: 1e-12)
        XCTAssertEqual(summary.signedKWh, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.validDurationSeconds, 10, accuracy: 1e-12)
    }

    func testGapSkewQualityAndUnknownUnitsAreReportedInsteadOfIntegrated() throws {
        let gap = try calculate([
            sample(.voltage, 0, 360, "V", 1), sample(.current, 0, 10, "A", 2),
            sample(.voltage, 3, 360, "V", 3), sample(.current, 3, 10, "A", 4)
        ])
        XCTAssertTrue(reasons(in: gap).contains(.maxGapExceeded))
        XCTAssertEqual(gap.validDurationSeconds, 0, accuracy: 1e-12)

        let skew = try calculate([
            sample(.voltage, 0, 360, "V", 1), sample(.current, 0.5, 10, "A", 2)
        ])
        XCTAssertTrue(reasons(in: skew).contains { if case .maxSampleSkewExceeded = $0 { true } else { false } })

        let unknownQuality = try calculate([
            sample(.voltage, 0, 360, "V", 1), sample(.current, 0, 10, "A", 2, quality: nil),
            sample(.voltage, 1, 360, "V", 3), sample(.current, 1, 10, "A", 4, quality: nil)
        ])
        XCTAssertTrue(reasons(in: unknownQuality).contains(.qualityUnknown(signal: .current)))
        XCTAssertEqual(unknownQuality.availability, .unavailable(.noQualifiedInterval))

        let staleQuality = try calculate([
            sample(.voltage, 0, 360, "V", 1), sample(.current, 0, 10, "A", 2, quality: .stale),
            sample(.voltage, 1, 360, "V", 3), sample(.current, 1, 10, "A", 4, quality: .stale)
        ])
        XCTAssertTrue(reasons(in: staleQuality).contains(
            .qualityNotValid(signal: .current, quality: SignalQuality.stale.rawValue)
        ))

        let unknownUnit = try calculate([
            sample(.voltage, 0, 360, "V", 1), sample(.current, 0, 10, "amps", 2),
            sample(.voltage, 1, 360, "V", 3), sample(.current, 1, 10, "amps", 4)
        ])
        XCTAssertTrue(reasons(in: unknownUnit).contains(.unknownSignalUnit(signal: .current, unit: "amps")))

        let unknownTimeUnit = try calculate([
            sample(.voltage, 0, 360, "V", 1, timeUnit: "ms"), sample(.current, 0, 10, "A", 2),
            sample(.voltage, 1, 360, "V", 3, timeUnit: "ms"), sample(.current, 1, 10, "A", 4)
        ])
        XCTAssertTrue(reasons(in: unknownTimeUnit).contains(.unknownTimeUnit(signal: .voltage, unit: "ms")))

        let nonFinite = try calculate([
            sample(.voltage, 0, 360, "V", 1), sample(.current, 0, .nan, "A", 2),
            sample(.voltage, 1, 360, "V", 3), sample(.current, 1, 10, "A", 4)
        ])
        XCTAssertTrue(reasons(in: nonFinite).contains(.nonFiniteValue(signal: .current)))

        let nonFiniteTime = try calculate([
            sample(.voltage, .nan, 360, "V", 1), sample(.current, 0, 10, "A", 2),
            sample(.voltage, 1, 360, "V", 3), sample(.current, 1, 10, "A", 4)
        ])
        XCTAssertTrue(reasons(in: nonFiniteTime).contains(.nonFiniteTimestamp(signal: .voltage)))
    }

    func testNewestSourceSequenceWinsForSameSignalAndTimestampWithoutDoubleCounting() throws {
        let observations = [
            sample(.voltage, 0, 100, "V", 1), sample(.voltage, 0, 360, "V", 2),
            sample(.current, 0, 10, "A", 3),
            sample(.voltage, 10, 360, "V", 4), sample(.current, 10, 10, "A", 5)
        ]

        let summary = try calculate(observations, maxGapSeconds: 10)

        XCTAssertEqual(summary.consumedKWh, 0.01, accuracy: 1e-12)
        XCTAssertEqual(summary.validDurationSeconds, 10, accuracy: 1e-12)
    }

    func testConflictingDuplicateSourceSequenceIsRejected() {
        let observations = [
            sample(.voltage, 0, 360, "V", 1), sample(.current, 0, 10, "A", 1)
        ]

        XCTAssertThrowsError(try calculate(observations)) { error in
            XCTAssertEqual(error as? RecordedEnergySummaryError, .ambiguousSourceSequence(sequence: 1))
        }
    }

    func testReversedTimestampInSourceSequenceOrderIsAnError() {
        let observations = [
            sample(.voltage, 1, 360, "V", 1),
            sample(.voltage, 0.5, 360, "V", 2), sample(.current, 0.5, 10, "A", 3)
        ]

        XCTAssertThrowsError(try calculate(observations)) { error in
            guard let summaryError = error as? RecordedEnergySummaryError,
                  case let .reversedTimestamp(previousSignal, signal, previousSequence, _, currentSequence, _) = summaryError,
                  previousSignal == .voltage, signal == .voltage,
                  previousSequence == 1, currentSequence == 2 else {
                return XCTFail("Expected a voltage timestamp reversal, got \(error)")
            }
        }
    }

    func testObservationsAfterAcceptedCursorDoNotContribute() throws {
        let observations = constantSamples(voltage: 360, current: 10, from: 0, through: 2)
        let summary = try calculate(observations, cursorSeconds: 1)

        XCTAssertEqual(summary.consumedKWh, 0.001, accuracy: 1e-12)
        XCTAssertEqual(summary.validDurationSeconds, 1, accuracy: 1e-12)
        XCTAssertTrue(reasons(in: summary).contains(.afterCursor))
    }

    func testUnpairedInvalidObservationBlocksIntegrationAcrossItsTimestamp() throws {
        let summary = try calculate([
            sample(.voltage, 0, 360, "V", 1), sample(.current, 0, 10, "A", 2),
            sample(.voltage, 1, 360, "V", 3, quality: .invalid),
            sample(.voltage, 2, 360, "V", 4), sample(.current, 2, 10, "A", 5)
        ], cursorSeconds: 2, maxGapSeconds: 3)

        XCTAssertEqual(summary.consumedKWh, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.validDurationSeconds, 0, accuracy: 1e-12)
        XCTAssertTrue(reasons(in: summary).contains(.qualityNotValid(signal: .voltage, quality: SignalQuality.invalid.rawValue)))
    }

    func testUnpairedInvalidObservationInsidePairSupportStillBlocksInterval() throws {
        let summary = try calculate([
            sample(.voltage, 0, 360, "V", 1), sample(.voltage, 0.05, 360, "V", 2, quality: .invalid),
            sample(.current, 0.1, 10, "A", 3), sample(.voltage, 1, 360, "V", 4),
            sample(.current, 1, 10, "A", 5)
        ], cursorSeconds: 1, maxGapSeconds: 2, maxSampleSkewSeconds: 0.1)

        XCTAssertEqual(summary.consumedKWh, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.validDurationSeconds, 0, accuracy: 1e-12)
        XCTAssertTrue(reasons(in: summary).contains(.qualityNotValid(signal: .voltage, quality: SignalQuality.invalid.rawValue)))
    }

    func testUnlocatedTimeMetadataBetweenPairsBlocksIntegration() throws {
        let unknownUnit = try calculate([
            sample(.voltage, 0, 360, "V", 1), sample(.current, 0, 10, "A", 2),
            sample(.voltage, 1, 360, "V", 3, timeUnit: "ms"),
            sample(.voltage, 2, 360, "V", 4), sample(.current, 2, 10, "A", 5)
        ], cursorSeconds: 2, maxGapSeconds: 3)
        XCTAssertEqual(unknownUnit.validDurationSeconds, 0, accuracy: 1e-12)
        XCTAssertTrue(reasons(in: unknownUnit).contains(.unknownTimeUnit(signal: .voltage, unit: "ms")))

        let nonFiniteTime = try calculate([
            sample(.voltage, 0, 360, "V", 1), sample(.current, 0, 10, "A", 2),
            sample(.voltage, .nan, 360, "V", 3),
            sample(.voltage, 2, 360, "V", 4), sample(.current, 2, 10, "A", 5)
        ], cursorSeconds: 2, maxGapSeconds: 3)
        XCTAssertEqual(nonFiniteTime.validDurationSeconds, 0, accuracy: 1e-12)
        XCTAssertTrue(reasons(in: nonFiniteTime).contains(.nonFiniteTimestamp(signal: .voltage)))
    }

    func testSourceTimestampRollbackAcrossDifferentSignalsIsRejected() {
        let observations = [
            sample(.voltage, 0, 360, "V", 1), sample(.current, 1, 10, "A", 2),
            sample(.voltage, 0.5, 360, "V", 3), sample(.current, 1.1, 10, "A", 4)
        ]

        XCTAssertThrowsError(try calculate(
            observations,
            cursorSeconds: 1.1,
            maxGapSeconds: 3,
            maxSampleSkewSeconds: 1
        )) { error in
            guard let summaryError = error as? RecordedEnergySummaryError,
                  case let .reversedTimestamp(previousSignal, signal, previousSequence, _, currentSequence, _) = summaryError,
                  previousSignal == .current, signal == .voltage,
                  previousSequence == 2, currentSequence == 3 else {
                return XCTFail("Expected current-to-voltage source-time rollback, got \(error)")
            }
        }
    }

    private func calculate(
        _ observations: [RecordedEnergyObservation],
        cursorSeconds: Double = 10,
        convention: RecordedEnergyCurrentSignConvention = .positiveCurrentMeansConsumption,
        maxGapSeconds: Double = 2,
        maxSampleSkewSeconds: Double = 0.1
    ) throws -> RecordedEnergySummary {
        try RecordedEnergySummaryCalculator.calculate(
            observations: observations,
            selectedWindowStartSeconds: 0,
            cursorSeconds: cursorSeconds,
            policy: RecordedEnergyPolicy(
                maxGapSeconds: maxGapSeconds,
                maxSampleSkewSeconds: maxSampleSkewSeconds,
                currentSignConvention: convention
            )
        )
    }

    private func constantSamples(
        voltage: Double,
        current: Double,
        from start: Int,
        through end: Int
    ) -> [RecordedEnergyObservation] {
        (start...end).flatMap { second in
            [
                sample(.voltage, Double(second), voltage, "V", Int64(second * 2 + 1)),
                sample(.current, Double(second), current, "A", Int64(second * 2 + 2))
            ]
        }
    }

    private func sample(
        _ signal: RecordedEnergySignal,
        _ seconds: Double,
        _ value: Double,
        _ unit: String,
        _ sequence: Int64,
        quality: SignalQuality? = .valid,
        timeUnit: String = "s"
    ) -> RecordedEnergyObservation {
        RecordedEnergyObservation(
            signal: signal,
            timestampSeconds: seconds,
            timeUnit: timeUnit,
            value: value,
            valueUnit: unit,
            sourceSequence: sequence,
            quality: quality
        )
    }

    private func reasons(in summary: RecordedEnergySummary) -> [RecordedEnergyExclusionReason] {
        summary.excludedIntervals.flatMap(\.reasons)
    }
}
