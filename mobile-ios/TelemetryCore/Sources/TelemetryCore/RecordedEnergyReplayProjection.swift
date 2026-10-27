import Foundation

/// Adapts accepted replay histories into the pure recorded-energy calculator.
///
/// Callers must obtain each `SignalHistory` from the requested `signalID` for
/// the same accepted replay cursor and session. `SignalHistory` intentionally
/// does not carry its requested ID, so that source relationship is an adapter
/// precondition. The selected session is checked against every persisted row.
public enum RecordedEnergyReplayProjectionError: Error, Equatable, Sendable {
    case missingSessionID
    case missingMonotonicOrigin
    case missingSignalID(signal: RecordedEnergySignal)
    case sameSignalSelected
    case invalidAcceptedWindow
    case historyWindowMismatch(
        signal: RecordedEnergySignal,
        expectedStartSeconds: Double,
        expectedEndSeconds: Double,
        actualStartSeconds: Double,
        actualEndSeconds: Double
    )
    case pointOutsideAcceptedWindow(
        signal: RecordedEnergySignal,
        sourceSequence: Int64,
        elapsedSeconds: Double
    )
    case sessionMismatch(
        signal: RecordedEnergySignal,
        sourceSequence: Int64,
        expectedSessionID: String,
        actualSessionID: String
    )
    case unexpectedUnit(
        signal: RecordedEnergySignal,
        signalID: String,
        sourceSequence: Int64,
        expectedUnit: String,
        actualUnit: String
    )
    case monotonicUnderflow(
        signal: RecordedEnergySignal,
        sourceSequence: Int64,
        receivedAtMonotonicNanos: UInt64,
        originMonotonicNanos: UInt64
    )
    case rawTimestampOutsideAcceptedWindow(
        signal: RecordedEnergySignal,
        sourceSequence: Int64,
        timestampSeconds: Double,
        windowStartSeconds: Double,
        cursorSeconds: Double
    )
    case timestampRollback(
        previousSignal: RecordedEnergySignal,
        signal: RecordedEnergySignal,
        previousSequence: Int64,
        previousSeconds: Double,
        currentSequence: Int64,
        currentSeconds: Double
    )
    case summary(RecordedEnergySummaryError)
}

public enum RecordedEnergyReplayProjection {
    public typealias ProjectionError = RecordedEnergyReplayProjectionError

    public struct Result: Equatable, Sendable {
        public let selectedSessionID: String
        public let voltageSignalID: String
        public let currentSignalID: String
        public let summary: RecordedEnergySummary
        /// True when either selected recorded history omitted rows from its
        /// selected display window due to the replay history cap.
        public let isWindowTruncated: Bool

        fileprivate init(
            selectedSessionID: String,
            voltageSignalID: String,
            currentSignalID: String,
            summary: RecordedEnergySummary,
            isWindowTruncated: Bool
        ) {
            self.selectedSessionID = selectedSessionID
            self.voltageSignalID = voltageSignalID
            self.currentSignalID = currentSignalID
            self.summary = summary
            self.isWindowTruncated = isWindowTruncated
        }
    }

    /// Projects rows from the same accepted replay session and display window.
    ///
    /// The origin must be the one shared origin for this session, normally the
    /// monotonic timestamp on its first persisted sequence row. Do not pass a
    /// per-signal or per-window origin. Legacy rows without recorded quality
    /// remain unknown. New rows use only their persisted decode-time quality,
    /// never the replay snapshot's current freshness or quality.
    public static func summarize(
        selectedSessionID: String?,
        recordedMonotonicOrigin: UInt64?,
        voltageSignalID: String?,
        voltageHistory: MeasurementReplay.SignalHistory?,
        currentSignalID: String?,
        currentHistory: MeasurementReplay.SignalHistory?,
        selectedWindowStartSeconds: Double,
        cursorSeconds: Double,
        policy: RecordedEnergyPolicy
    ) throws -> Result {
        guard let selectedSessionID, !selectedSessionID.isEmpty else {
            throw ProjectionError.missingSessionID
        }
        guard let recordedMonotonicOrigin else {
            throw ProjectionError.missingMonotonicOrigin
        }
        guard let voltageSignalID, !voltageSignalID.isEmpty else {
            throw ProjectionError.missingSignalID(signal: .voltage)
        }
        guard let currentSignalID, !currentSignalID.isEmpty else {
            throw ProjectionError.missingSignalID(signal: .current)
        }
        guard voltageSignalID != currentSignalID else {
            throw ProjectionError.sameSignalSelected
        }
        guard selectedWindowStartSeconds.isFinite, cursorSeconds.isFinite,
              selectedWindowStartSeconds >= 0, cursorSeconds >= selectedWindowStartSeconds else {
            throw ProjectionError.invalidAcceptedWindow
        }

        let voltageRows = try observations(
            signal: .voltage,
            signalID: voltageSignalID,
            history: voltageHistory,
            sessionID: selectedSessionID,
            originNanos: recordedMonotonicOrigin,
            windowStartSeconds: selectedWindowStartSeconds,
            cursorSeconds: cursorSeconds
        )
        let currentRows = try observations(
            signal: .current,
            signalID: currentSignalID,
            history: currentHistory,
            sessionID: selectedSessionID,
            originNanos: recordedMonotonicOrigin,
            windowStartSeconds: selectedWindowStartSeconds,
            cursorSeconds: cursorSeconds
        )

        let summary: RecordedEnergySummary
        do {
            summary = try RecordedEnergySummaryCalculator.calculate(
                observations: voltageRows + currentRows,
                selectedWindowStartSeconds: selectedWindowStartSeconds,
                cursorSeconds: cursorSeconds,
                policy: policy
            )
        } catch let error as RecordedEnergySummaryError {
            if case let .reversedTimestamp(
                previousSignal,
                signal,
                previousSequence,
                previousSeconds,
                currentSequence,
                currentSeconds
            ) = error {
                throw ProjectionError.timestampRollback(
                    previousSignal: previousSignal,
                    signal: signal,
                    previousSequence: previousSequence,
                    previousSeconds: previousSeconds,
                    currentSequence: currentSequence,
                    currentSeconds: currentSeconds
                )
            }
            throw ProjectionError.summary(error)
        }

        return Result(
            selectedSessionID: selectedSessionID,
            voltageSignalID: voltageSignalID,
            currentSignalID: currentSignalID,
            summary: summary,
            isWindowTruncated: (voltageHistory?.truncated ?? false) || (currentHistory?.truncated ?? false)
        )
    }

    private static func observations(
        signal: RecordedEnergySignal,
        signalID: String,
        history: MeasurementReplay.SignalHistory?,
        sessionID: String,
        originNanos: UInt64,
        windowStartSeconds: Double,
        cursorSeconds: Double
    ) throws -> [RecordedEnergyObservation] {
        guard let history else { return [] }
        guard history.startSeconds == windowStartSeconds, history.endSeconds == cursorSeconds else {
            throw ProjectionError.historyWindowMismatch(
                signal: signal,
                expectedStartSeconds: windowStartSeconds,
                expectedEndSeconds: cursorSeconds,
                actualStartSeconds: history.startSeconds,
                actualEndSeconds: history.endSeconds
            )
        }

        let expectedUnit = signal == .voltage ? "V" : "A"
        return try history.samples.map { point in
            let row = point.measurement
            guard row.sessionID == sessionID else {
                throw ProjectionError.sessionMismatch(
                    signal: signal,
                    sourceSequence: row.sequence,
                    expectedSessionID: sessionID,
                    actualSessionID: row.sessionID
                )
            }
            guard point.unit == expectedUnit else {
                throw ProjectionError.unexpectedUnit(
                    signal: signal,
                    signalID: signalID,
                    sourceSequence: row.sequence,
                    expectedUnit: expectedUnit,
                    actualUnit: point.unit
                )
            }
            guard point.elapsedSeconds.isFinite,
                  point.elapsedSeconds >= windowStartSeconds,
                  point.elapsedSeconds <= cursorSeconds else {
                throw ProjectionError.pointOutsideAcceptedWindow(
                    signal: signal,
                    sourceSequence: row.sequence,
                    elapsedSeconds: point.elapsedSeconds
                )
            }
            guard row.receivedAtMonotonicNanos >= originNanos else {
                throw ProjectionError.monotonicUnderflow(
                    signal: signal,
                    sourceSequence: row.sequence,
                    receivedAtMonotonicNanos: row.receivedAtMonotonicNanos,
                    originMonotonicNanos: originNanos
                )
            }

            let timestampSeconds = Double(row.receivedAtMonotonicNanos - originNanos) / 1_000_000_000
            guard timestampSeconds.isFinite,
                  timestampSeconds >= windowStartSeconds,
                  timestampSeconds <= cursorSeconds else {
                throw ProjectionError.rawTimestampOutsideAcceptedWindow(
                    signal: signal,
                    sourceSequence: row.sequence,
                    timestampSeconds: timestampSeconds,
                    windowStartSeconds: windowStartSeconds,
                    cursorSeconds: cursorSeconds
                )
            }

            return RecordedEnergyObservation(
                signal: signal,
                timestampSeconds: timestampSeconds,
                timeUnit: "s",
                value: point.value,
                valueUnit: point.unit,
                sourceSequence: row.sequence,
                quality: point.recordedQuality
            )
        }
    }
}
