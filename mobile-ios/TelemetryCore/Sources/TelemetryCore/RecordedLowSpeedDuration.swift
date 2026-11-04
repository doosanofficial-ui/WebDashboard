import Foundation

public struct RecordedLowSpeedPolicy: Equatable, Sendable {
    public let thresholdKmh: Double
    public let maxGapSeconds: Double
    public init(thresholdKmh: Double, maxGapSeconds: Double) {
        self.thresholdKmh = thresholdKmh
        self.maxGapSeconds = maxGapSeconds
    }
}

public enum RecordedLowSpeedError: Error, Equatable, Sendable {
    case invalidWindow, invalidPolicy, scopeMismatch
    case invalidRow(Int64), ambiguousChronology(Int64)
}

public enum RecordedLowSpeedExclusion: String, Equatable, Sendable {
    case outsideWindow, invalidEvidence, sourceChanged, gapExceeded
    case crossingUnclassified, numericBound
}

public struct RecordedLowSpeedBracket: Equatable, Sendable {
    public let before: RecordedTripObservation
    public let after: RecordedTripObservation
    public let durationSeconds: Double
    public let exclusion: RecordedLowSpeedExclusion?
    /// Nil for unclassified brackets. Equality with the threshold is not below it.
    public let isBelowThreshold: Bool?
}

public struct RecordedLowSpeedReport: Equatable, Sendable {
    public let sessionID: String
    public let signalID: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let policy: RecordedLowSpeedPolicy
    /// Nil is unavailable. Zero requires at least one classified above/equal bracket.
    public let belowThresholdDurationEstimateSeconds: Double?
    public let classifiedDurationSeconds: Double
    public let unclassifiedDurationSeconds: Double
    public let originalObservations: [RecordedTripObservation]
    public let brackets: [RecordedLowSpeedBracket]
    public let interpretation = "Historical same-side endpoint bracket estimate; intervening motion unknown"
}

/// Original selected-signal archive rows only, never downsampled/filtered good rows.
/// No consecutive-ID requirement: archive sequence IDs are global. Caller must prove
/// selected-signal completeness for this bounded input and retain invalid rows.
/// Same-side endpoints do not prove the speed stayed on that side between samples.
/// This is neither a true-duration bound nor engine idle, parked, gear or fuel state.
public enum RecordedLowSpeedCalculator {
    public static func calculate(observations: [RecordedTripObservation], sessionID: String,
                                 signalID: String, startSeconds: Double, endSeconds: Double,
                                 policy: RecordedLowSpeedPolicy) throws -> RecordedLowSpeedReport {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0,
              endSeconds >= startSeconds else { throw RecordedLowSpeedError.invalidWindow }
        guard policy.thresholdKmh.isFinite, policy.thresholdKmh >= 0,
              policy.maxGapSeconds.isFinite, policy.maxGapSeconds > 0 else {
            throw RecordedLowSpeedError.invalidPolicy
        }
        guard !sessionID.isEmpty, !signalID.isEmpty else { throw RecordedLowSpeedError.scopeMismatch }
        let ordered = observations.sorted { $0.sourceSequence < $1.sourceSequence }
        var prior: RecordedTripObservation?
        for row in ordered {
            guard row.sessionID == sessionID, row.signalID == signalID else {
                throw RecordedLowSpeedError.scopeMismatch
            }
            guard row.sourceSequence >= 0, row.sourceSegment >= 0,
                  row.timestampSeconds.isFinite, row.timestampSeconds >= 0 else {
                throw RecordedLowSpeedError.invalidRow(row.sourceSequence)
            }
            if let prior {
                guard row.sourceSequence != prior.sourceSequence,
                      row.timestampSeconds > prior.timestampSeconds else {
                    throw RecordedLowSpeedError.ambiguousChronology(row.sourceSequence)
                }
            }
            prior = row
        }
        let windowDuration = endSeconds - startSeconds
        var classified = 0.0
        var below = 0.0
        var hasClassified = false
        var brackets: [RecordedLowSpeedBracket] = []
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            let duration = b.timestampSeconds - a.timestampSeconds
            let av = speed(a), bv = speed(b)
            var exclusion: RecordedLowSpeedExclusion?
            if a.timestampSeconds < startSeconds || b.timestampSeconds > endSeconds {
                exclusion = .outsideWindow
            } else if av == nil || bv == nil {
                exclusion = .invalidEvidence
            } else if a.sourceSegment != b.sourceSegment {
                exclusion = .sourceChanged
            } else if duration > policy.maxGapSeconds {
                exclusion = .gapExceeded
            } else if let av, let bv, (av < policy.thresholdKmh) != (bv < policy.thresholdKmh) {
                exclusion = .crossingUnclassified
            } else if !(classified + duration).isFinite || classified + duration > windowDuration {
                exclusion = .numericBound
            }
            var isBelow: Bool?
            if exclusion == nil, let av {
                isBelow = av < policy.thresholdKmh
                classified += duration
                hasClassified = true
                if isBelow == true { below += duration }
            }
            brackets.append(.init(before: a, after: b, durationSeconds: duration,
                                  exclusion: exclusion, isBelowThreshold: isBelow))
        }
        return .init(sessionID: sessionID, signalID: signalID,
                     startSeconds: startSeconds, endSeconds: endSeconds, policy: policy,
                     belowThresholdDurationEstimateSeconds: hasClassified ? below : nil,
                     classifiedDurationSeconds: classified,
                     unclassifiedDurationSeconds: windowDuration - classified,
                     originalObservations: ordered, brackets: brackets)
    }

    private static func speed(_ row: RecordedTripObservation) -> Double? {
        guard row.quality == .valid else { return nil }
        let value: Double
        switch row.unit {
        case "km/h": value = row.value
        case "m/s": value = row.value * 3.6
        default: return nil
        }
        return value.isFinite && value >= 0 ? value : nil
    }
}
