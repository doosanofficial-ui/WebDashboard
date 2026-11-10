import Foundation

/// Historical, original observations only. No live trigger, ranking or vehicle certification.
public struct RecordedSpeedWindowPolicy: Equatable, Sendable {
    public let lowerKmh: Double
    public let upperKmh: Double
    public let maxGapSeconds: Double
    public let maxDurationSeconds: Double
    public init(lowerKmh: Double, upperKmh: Double, maxGapSeconds: Double, maxDurationSeconds: Double) {
        self.lowerKmh = lowerKmh
        self.upperKmh = upperKmh
        self.maxGapSeconds = maxGapSeconds
        self.maxDurationSeconds = maxDurationSeconds
    }
}

public enum RecordedSpeedWindowError: Error, Equatable, Sendable {
    case invalidWindow, invalidPolicy, scopeMismatch
    case invalidRow(Int64), duplicateSequence(Int64), nonIncreasingTime(Int64)
}

public struct RecordedSpeedCrossingEstimate: Equatable, Sendable {
    public let timestampSeconds: Double
    /// Unmodified original rows: retain source sequence, raw time, quality, units and segment.
    public let before: RecordedTripObservation
    public let after: RecordedTripObservation
}

public struct RecordedSpeedWindowEstimate: Equatable, Sendable {
    public let lowerCrossing: RecordedSpeedCrossingEstimate
    public let upperCrossing: RecordedSpeedCrossingEstimate
    public let durationSeconds: Double
    /// Explicit presentation label, including when a crossing coincides with an observed endpoint.
    public let interpretation = "Historical linear-interpolation estimate; not vehicle certification"
}

public struct RecordedSpeedWindowReport: Equatable, Sendable {
    public let sessionID: String
    public let signalID: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let policy: RecordedSpeedWindowPolicy
    /// Empty means no complete qualified crossing, never a zero-second run.
    public let estimates: [RecordedSpeedWindowEstimate]
    /// Complete unmodified input sorted by source sequence, for nondestructive audit/recomputation.
    public let originalObservations: [RecordedTripObservation]
}

public enum RecordedSpeedWindowCalculator {
    private struct Qualified {
        let row: RecordedTripObservation
        let speed: Double
    }

    public static func calculate(observations: [RecordedTripObservation], sessionID: String,
                                 signalID: String, startSeconds: Double, endSeconds: Double,
                                 policy: RecordedSpeedWindowPolicy) throws -> RecordedSpeedWindowReport {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0,
              endSeconds >= startSeconds else { throw RecordedSpeedWindowError.invalidWindow }
        guard policy.lowerKmh.isFinite, policy.upperKmh.isFinite, policy.lowerKmh >= 0,
              policy.upperKmh > policy.lowerKmh, policy.maxGapSeconds.isFinite,
              policy.maxGapSeconds > 0, policy.maxDurationSeconds.isFinite,
              policy.maxDurationSeconds > 0 else { throw RecordedSpeedWindowError.invalidPolicy }
        guard !sessionID.isEmpty, !signalID.isEmpty else { throw RecordedSpeedWindowError.scopeMismatch }
        let ordered = observations.sorted { $0.sourceSequence < $1.sourceSequence }
        var prior: RecordedTripObservation?
        // Structural ambiguity rejects the entire calculation instead of repairing chronology.
        for row in ordered {
            guard row.sessionID == sessionID, row.signalID == signalID else {
                throw RecordedSpeedWindowError.scopeMismatch
            }
            guard row.sourceSegment >= 0, row.timestampSeconds.isFinite, row.timestampSeconds >= 0 else {
                throw RecordedSpeedWindowError.invalidRow(row.sourceSequence)
            }
            if let prior {
                guard prior.sourceSequence != row.sourceSequence else {
                    throw RecordedSpeedWindowError.duplicateSequence(row.sourceSequence)
                }
                guard prior.timestampSeconds < row.timestampSeconds else {
                    throw RecordedSpeedWindowError.nonIncreasingTime(row.sourceSequence)
                }
            }
            prior = row
        }
        var previous: Qualified?
        var pending: RecordedSpeedCrossingEstimate?
        var estimates: [RecordedSpeedWindowEstimate] = []
        for row in ordered {
            let speed: Double
            switch row.unit {
            case "km/h": speed = row.value
            case "m/s": speed = row.value * 3.6
            default: previous = nil; pending = nil; continue
            }
            guard row.quality == .valid, speed.isFinite, speed >= 0,
                  row.timestampSeconds >= startSeconds, row.timestampSeconds <= endSeconds else {
                previous = nil; pending = nil; continue
            }
            let current = Qualified(row: row, speed: speed)
            guard let before = previous else { previous = current; continue }
            previous = current
            guard before.row.sourceSegment == row.sourceSegment,
                  row.timestampSeconds - before.row.timestampSeconds <= policy.maxGapSeconds else {
                pending = nil; continue
            }
            // Any observed downward reversal aborts, including jitter. A subsequent event requires
            // a new qualified <= lower baseline. A flat plateau does not itself trigger or abort.
            guard speed >= before.speed else { pending = nil; continue }
            if pending == nil, before.speed <= policy.lowerKmh, speed > policy.lowerKmh {
                pending = crossing(before, current, threshold: policy.lowerKmh)
            }
            if let start = pending {
                if speed >= policy.upperKmh {
                    if let finish = crossing(before, current, threshold: policy.upperKmh) {
                        let duration = finish.timestampSeconds - start.timestampSeconds
                        // Reject rounded-to-zero and nonfinite intervals, never report them as zero.
                        if duration.isFinite, duration > 0, duration <= policy.maxDurationSeconds {
                            estimates.append(.init(lowerCrossing: start, upperCrossing: finish,
                                                   durationSeconds: duration))
                        }
                    }
                    pending = nil
                } else if row.timestampSeconds - start.timestampSeconds > policy.maxDurationSeconds {
                    pending = nil
                }
            }
        }
        return .init(sessionID: sessionID, signalID: signalID, startSeconds: startSeconds,
                     endSeconds: endSeconds, policy: policy, estimates: estimates,
                     originalObservations: ordered)
    }

    private static func crossing(_ before: Qualified, _ after: Qualified,
                                 threshold: Double) -> RecordedSpeedCrossingEstimate? {
        guard after.speed > before.speed, before.speed <= threshold, after.speed >= threshold else { return nil }
        let fraction = (threshold - before.speed) / (after.speed - before.speed)
        let timestamp = before.row.timestampSeconds
            + (after.row.timestampSeconds - before.row.timestampSeconds) * fraction
        guard timestamp.isFinite else { return nil }
        if threshold > before.speed, threshold < after.speed {
            guard fraction > 0, fraction < 1, timestamp > before.row.timestampSeconds,
                  timestamp < after.row.timestampSeconds else { return nil }
        }
        return .init(timestampSeconds: timestamp, before: before.row, after: after.row)
    }
}
