import Foundation

/// One original recorded volumetric fuel-rate observation, not a display refresh or interpolated value.
public struct RecordedFuelObservation: Equatable, Sendable {
    public let sessionID: String
    public let signalID: String
    /// Persisted source-continuity segment, copied from the original recorded point.
    public let sourceSegment: Int
    public let sourceSequence: Int64
    public let timestampSeconds: Double
    public let value: Double?
    public let unit: String
    public let quality: SignalQuality?

    public init(sessionID: String, signalID: String, sourceSegment: Int, sourceSequence: Int64,
                timestampSeconds: Double, value: Double?, unit: String, quality: SignalQuality?) {
        self.sessionID = sessionID
        self.signalID = signalID
        self.sourceSegment = sourceSegment
        self.sourceSequence = sourceSequence
        self.timestampSeconds = timestampSeconds
        self.value = value
        self.unit = unit
        self.quality = quality
    }
}

public struct RecordedFuelPolicy: Equatable, Sendable {
    public let maxGapSeconds: Double

    public init(maxGapSeconds: Double) {
        self.maxGapSeconds = maxGapSeconds
    }
}

public enum RecordedFuelSummaryError: Error, Equatable, Sendable {
    case invalidWindow
    case invalidPolicy
    case scopeMismatch
    case invalidSourceSegment(Int64)
    case invalidTimestamp(Int64)
    case duplicateSequence(Int64)
    case nonIncreasingTimestamp(Int64)
}

public enum RecordedFuelExclusionReason: String, Equatable, Sendable {
    case outsideSelectedWindow
    case qualityNotValidOrUnknown
    case unknownUnit
    case invalidFuelRate
    case sourceChanged
    case maximumGapExceeded
    case unrepresentableCalculation
}

public struct RecordedFuelExcludedInterval: Equatable, Sendable {
    public let sourceSequences: [Int64]
    public let reasons: [RecordedFuelExclusionReason]
}

/// Qualified observed-window fuel integration, not a complete-trip consumption claim.
/// Linear interpolation applies only inside admitted adjacent recorded intervals.
public struct RecordedFuelSummary: Equatable, Sendable {
    public let sessionID: String
    public let signalID: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let policy: RecordedFuelPolicy
    /// Nil means no qualified interval. Measured zero remains numeric zero.
    public let observedLiters: Double?
    public let coveredDurationSeconds: Double
    public let meanRateLitersPerHour: Double?
    /// No matched distance/time coverage proof is available in this calculator.
    public let fuelEconomyUnavailableReason: RecordedFuelEconomyUnavailableReason
    public var litersPer100Kilometers: Double? { nil }
    public let excludedIntervals: [RecordedFuelExcludedInterval]

    public var coverageFraction: Double {
        let duration = endSeconds - startSeconds
        return duration > 0 ? coveredDurationSeconds / duration : 0
    }
}

public enum RecordedFuelEconomyUnavailableReason: String, Equatable, Sendable {
    case matchedDistanceCoverageNotProven
}

public enum RecordedFuelSummaryCalculator {
    private struct Qualified {
        let observation: RecordedFuelObservation
        let rateLitersPerHour: Double
        let reasons: [RecordedFuelExclusionReason]
    }

    public static func calculate(observations: [RecordedFuelObservation],
                                 sessionID: String, signalID: String,
                                 startSeconds: Double, endSeconds: Double,
                                 policy: RecordedFuelPolicy) throws -> RecordedFuelSummary {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0,
              endSeconds >= startSeconds else { throw RecordedFuelSummaryError.invalidWindow }
        guard policy.maxGapSeconds.isFinite, policy.maxGapSeconds > 0 else {
            throw RecordedFuelSummaryError.invalidPolicy
        }
        guard !sessionID.isEmpty, !signalID.isEmpty else { throw RecordedFuelSummaryError.scopeMismatch }
        let ordered = observations.sorted { $0.sourceSequence < $1.sourceSequence }
        var previous: RecordedFuelObservation?
        var qualified: [Qualified] = []
        for observation in ordered {
            guard observation.sessionID == sessionID, observation.signalID == signalID else {
                throw RecordedFuelSummaryError.scopeMismatch
            }
            guard observation.sourceSegment >= 0 else {
                throw RecordedFuelSummaryError.invalidSourceSegment(observation.sourceSequence)
            }
            guard observation.timestampSeconds.isFinite else {
                throw RecordedFuelSummaryError.invalidTimestamp(observation.sourceSequence)
            }
            if let previous {
                guard previous.sourceSequence != observation.sourceSequence else {
                    throw RecordedFuelSummaryError.duplicateSequence(observation.sourceSequence)
                }
                guard previous.timestampSeconds < observation.timestampSeconds else {
                    throw RecordedFuelSummaryError.nonIncreasingTimestamp(observation.sourceSequence)
                }
            }
            previous = observation
            var reasons: [RecordedFuelExclusionReason] = []
            if observation.timestampSeconds < startSeconds || observation.timestampSeconds > endSeconds {
                reasons.append(.outsideSelectedWindow)
            }
            if observation.quality != .valid { reasons.append(.qualityNotValidOrUnknown) }
            // Only explicit original volumetric L/h values are accepted. No MAF conversion.
            if observation.unit != "L/h" { reasons.append(.unknownUnit) }
            let rate = observation.value
            if let rate {
                if !rate.isFinite || rate < 0 { reasons.append(.invalidFuelRate) }
            } else {
                reasons.append(.invalidFuelRate)
            }
            // Missing stays a barrier; this internal placeholder is never integrated.
            qualified.append(.init(observation: observation, rateLitersPerHour: rate ?? 0, reasons: reasons))
        }

        var liters = 0.0
        var covered = 0.0
        var average = 0.0
        var exclusions: [RecordedFuelExcludedInterval] = []
        for index in qualified.indices.dropFirst() {
            let start = qualified[index - 1]
            let end = qualified[index]
            let duration = end.observation.timestampSeconds - start.observation.timestampSeconds
            var reasons = start.reasons
            for reason in end.reasons where !reasons.contains(reason) { reasons.append(reason) }
            if start.observation.sourceSegment != end.observation.sourceSegment { reasons.append(.sourceChanged) }
            if duration > policy.maxGapSeconds { reasons.append(.maximumGapExceeded) }
            let sequences = [start.observation.sourceSequence, end.observation.sourceSequence]
            guard reasons.isEmpty else {
                exclusions.append(.init(sourceSequences: sequences, reasons: reasons))
                continue
            }
            let scale = max(start.rateLitersPerHour, end.rateLitersPerHour)
            let normalizedMean = scale > 0 ? (start.rateLitersPerHour / scale + end.rateLitersPerHour / scale) / 2 : 0
            let midpoint = scale * normalizedMean
            // Scale exponents before multiplying: duration / 3600 may underflow
            // even when the eventual fuelRate * duration / 3600 is representable.
            let increment = scaledProduct(scale, duration, dividingBy: 3600, factor: normalizedMean)
            let newCovered = covered + duration
            guard increment.isFinite, (liters + increment).isFinite, newCovered.isFinite,
                  scale == 0 || (increment > 0 && midpoint > 0) else {
                exclusions.append(.init(sourceSequences: sequences, reasons: [.unrepresentableCalculation]))
                continue
            }
            // Duration-weighted mean avoids dividing an underflowed volume
            // or a subnormal duration converted to hours.
            let newAverage = weightedMean(average, weight: covered, midpoint, weight: duration, denominator: newCovered)
            guard newAverage.isFinite, newAverage > 0 || (average == 0 && midpoint == 0) else {
                exclusions.append(.init(sourceSequences: sequences, reasons: [.unrepresentableCalculation]))
                continue
            }
            average = newAverage
            liters += increment
            // Admitted intervals are ordered, nonoverlapping, and wholly within the window.
            // Cap roundoff only after validating finite candidates, never conceal overflow.
            let boundedCovered = min(newCovered, endSeconds - startSeconds)
            covered = boundedCovered
        }
        return RecordedFuelSummary(sessionID: sessionID, signalID: signalID,
            startSeconds: startSeconds, endSeconds: endSeconds, policy: policy,
            observedLiters: covered > 0 ? liters : nil,
            coveredDurationSeconds: covered,
            meanRateLitersPerHour: covered > 0 ? average : nil,
            fuelEconomyUnavailableReason: .matchedDistanceCoverageNotProven, excludedIntervals: exclusions)
    }

    /// Add positive scaled products before the final conversion to Double. Separately
    /// rounded contributions can both become zero while their sum is representable.
    private static func weightedMean(_ first: Double, weight firstWeight: Double,
                                     _ second: Double, weight secondWeight: Double,
                                     denominator: Double) -> Double {
        var terms: [(significand: Double, exponent: Int)] = []
        if first > 0 && firstWeight > 0 {
            terms.append((first.significand * firstWeight.significand, first.exponent + firstWeight.exponent))
        }
        if second > 0 && secondWeight > 0 {
            terms.append((second.significand * secondWeight.significand, second.exponent + secondWeight.exponent))
        }
        guard let exponent = terms.map({ $0.exponent }).max() else { return 0 }
        let significand = terms.reduce(0.0) {
            $0 + Double(sign: .plus, exponent: $1.exponent - exponent, significand: $1.significand)
        }
        return Double(sign: .plus, exponent: exponent - denominator.exponent,
                      significand: significand / denominator.significand)
    }

    private static func scaledProduct(_ first: Double, _ second: Double,
                                      dividingBy divisor: Double, factor: Double = 1) -> Double {
        guard first > 0, second > 0, factor > 0 else { return 0 }
        return Double(sign: .plus, exponent: first.exponent + second.exponent - divisor.exponent,
                      significand: first.significand * second.significand * factor / divisor.significand)
    }
}
