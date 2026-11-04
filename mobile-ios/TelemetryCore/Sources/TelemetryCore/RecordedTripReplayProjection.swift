import Foundation

public enum RecordedTripReplayProjectionError: Error, Equatable, Sendable {
    case missingSessionID
    case missingSignalID
    case missingMonotonicOrigin
    case invalidAcceptedWindow
    case historyWindowMismatch
    case invalidHistoryCount
    case sessionMismatch(Int64)
    case unexpectedUnit(Int64)
    case missingSource(Int64)
    case inconsistentSourceSegment(Int64)
    case pointOutsideAcceptedWindow(Int64)
    case monotonicUnderflow(Int64)
    case rawTimestampOutsideAcceptedWindow(Int64)
    case summary(RecordedTripSummaryError)
}

/// Read-only projection of a bounded accepted replay history, not a complete trip.
/// PRECONDITION: retrieve speedHistory using speedSignalID from the SAME accepted
/// Timeline/cursor; use that Timeline's recordedMonotonicOrigin. SignalHistory
/// has no requested ID or origin metadata: these relationships cannot be proved
/// here. The controller must reject stale asynchronous responses before calling.
public enum RecordedTripReplayProjection {
    public struct Result: Equatable, Sendable {
        public let selectedSessionID: String
        public let speedSignalID: String
        public let summary: RecordedTripSummary
        public let isWindowTruncated: Bool
        public let totalSamplesInWindow: Int
        /// Unmodified rows retain sequence, source, unit, quality and segment.
        public let evidence: [MeasurementReplay.RecordedSignalPoint]
    }

    public static func summarize(
        selectedSessionID: String?, recordedMonotonicOrigin: UInt64?,
        speedSignalID: String?, speedHistory: MeasurementReplay.SignalHistory?,
        selectedWindowStartSeconds: Double, cursorSeconds: Double,
        policy: RecordedTripPolicy
    ) throws -> Result {
        typealias Failure = RecordedTripReplayProjectionError
        guard let selectedSessionID, !selectedSessionID.isEmpty else { throw Failure.missingSessionID }
        guard let speedSignalID, !speedSignalID.isEmpty else { throw Failure.missingSignalID }
        guard let recordedMonotonicOrigin else { throw Failure.missingMonotonicOrigin }
        guard selectedWindowStartSeconds.isFinite, cursorSeconds.isFinite,
              selectedWindowStartSeconds >= 0, cursorSeconds >= selectedWindowStartSeconds else {
            throw Failure.invalidAcceptedWindow
        }
        if let speedHistory {
            guard speedHistory.startSeconds == selectedWindowStartSeconds,
                  speedHistory.endSeconds == cursorSeconds else { throw Failure.historyWindowMismatch }
            guard speedHistory.samples.count <= 600,
                  speedHistory.totalSamplesInWindow >= speedHistory.samples.count else {
                throw Failure.invalidHistoryCount
            }
        }
        let evidence = speedHistory?.samples ?? []
        let ordered = evidence.sorted { $0.measurement.sequence < $1.measurement.sequence }
        var previous: MeasurementReplay.RecordedSignalPoint?
        var observations: [RecordedTripObservation] = []
        for point in ordered {
            let row = point.measurement
            guard row.sessionID == selectedSessionID else { throw Failure.sessionMismatch(row.sequence) }
            guard point.unit == "km/h" || point.unit == "m/s" else { throw Failure.unexpectedUnit(row.sequence) }
            guard !point.source.kind.isEmpty else { throw Failure.missingSource(row.sequence) }
            if let previous, previous.source != point.source,
               previous.sourceSegment == point.sourceSegment {
                throw Failure.inconsistentSourceSegment(row.sequence)
            }
            guard point.elapsedSeconds.isFinite,
                  point.elapsedSeconds >= selectedWindowStartSeconds,
                  point.elapsedSeconds <= cursorSeconds else { throw Failure.pointOutsideAcceptedWindow(row.sequence) }
            guard row.receivedAtMonotonicNanos >= recordedMonotonicOrigin else {
                throw Failure.monotonicUnderflow(row.sequence)
            }
            let timestamp = Double(row.receivedAtMonotonicNanos - recordedMonotonicOrigin) / 1_000_000_000
            guard timestamp.isFinite, timestamp >= selectedWindowStartSeconds,
                  timestamp <= cursorSeconds else { throw Failure.rawTimestampOutsideAcceptedWindow(row.sequence) }
            observations.append(RecordedTripObservation(sessionID: row.sessionID,
                signalID: speedSignalID, sourceSegment: point.sourceSegment,
                sourceSequence: row.sequence, timestampSeconds: timestamp,
                value: point.value, unit: point.unit, quality: point.recordedQuality))
            previous = point
        }
        let summary: RecordedTripSummary
        do {
            summary = try RecordedTripSummaryCalculator.calculate(observations: observations,
                sessionID: selectedSessionID, signalID: speedSignalID,
                startSeconds: selectedWindowStartSeconds, endSeconds: cursorSeconds, policy: policy)
        } catch let error as RecordedTripSummaryError { throw Failure.summary(error) }
        return Result(selectedSessionID: selectedSessionID, speedSignalID: speedSignalID,
            summary: summary, isWindowTruncated: speedHistory?.truncated ?? false,
            totalSamplesInWindow: speedHistory?.totalSamplesInWindow ?? 0, evidence: evidence)
    }
}
