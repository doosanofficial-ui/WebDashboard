import Foundation

/// One original recorded speed observation, not a display refresh or interpolated value.
public struct RecordedTripObservation: Equatable, Sendable {
    public let sessionID: String
    public let signalID: String
    /// Persisted source-continuity segment, copied from the original recorded point.
    public let sourceSegment: Int
    public let sourceSequence: Int64
    public let timestampSeconds: Double
    public let value: Double
    public let unit: String
    public let quality: SignalQuality?

    public init(sessionID: String, signalID: String, sourceSegment: Int, sourceSequence: Int64,
                timestampSeconds: Double, value: Double, unit: String, quality: SignalQuality?) {
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

public struct RecordedTripPolicy: Equatable, Sendable {
    public let maxGapSeconds: Double
    public let movingThresholdKmh: Double

    public init(maxGapSeconds: Double, movingThresholdKmh: Double) {
        self.maxGapSeconds = maxGapSeconds
        self.movingThresholdKmh = movingThresholdKmh
    }
}

public enum RecordedTripSummaryError: Error, Equatable, Sendable {
    case invalidWindow
    case invalidPolicy
    case scopeMismatch
    case invalidSourceSegment(Int64)
    case invalidTimestamp(Int64)
    case duplicateSequence(Int64)
    case nonIncreasingTimestamp(Int64)
}

public enum RecordedTripExclusionReason: String, Equatable, Sendable {
    case outsideSelectedWindow
    case qualityNotValidOrUnknown
    case unknownUnit
    case invalidSpeed
    case sourceChanged
    case maximumGapExceeded
    case unrepresentableCalculation
}

public struct RecordedTripExcludedInterval: Equatable, Sendable {
    public let sourceSequences: [Int64]
    public let reasons: [RecordedTripExclusionReason]
}

/// Qualified observed-window totals, not an odometer or complete-trip claim.
public struct RecordedTripSummary: Equatable, Sendable {
    public let sessionID: String
    public let signalID: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let policy: RecordedTripPolicy
    /// Nil means no qualified interval. Measured zero remains numeric zero.
    public let distanceKilometers: Double?
    public let coveredDurationSeconds: Double
    /// Time at or above the selected speed threshold, not engine-on or engine-idle time.
    public let movingDurationSeconds: Double
    public let averageSpeedKmh: Double?
    public let observedMaximumSpeedKmh: Double?
    public let excludedIntervals: [RecordedTripExcludedInterval]

    public var coverageFraction: Double {
        let duration = endSeconds - startSeconds
        return duration > 0 ? coveredDurationSeconds / duration : 0
    }
}

public enum RecordedTripSummaryCalculator {
    private struct Qualified {
        let observation: RecordedTripObservation
        let speedKmh: Double
        let reasons: [RecordedTripExclusionReason]
    }

    public static func calculate(observations: [RecordedTripObservation],
                                 sessionID: String, signalID: String,
                                 startSeconds: Double, endSeconds: Double,
                                 policy: RecordedTripPolicy) throws -> RecordedTripSummary {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0,
              endSeconds >= startSeconds else { throw RecordedTripSummaryError.invalidWindow }
        guard policy.maxGapSeconds.isFinite, policy.maxGapSeconds > 0,
              policy.movingThresholdKmh.isFinite, policy.movingThresholdKmh > 0 else {
            throw RecordedTripSummaryError.invalidPolicy
        }
        guard !sessionID.isEmpty, !signalID.isEmpty else { throw RecordedTripSummaryError.scopeMismatch }
        let ordered = observations.sorted { $0.sourceSequence < $1.sourceSequence }
        var previous: RecordedTripObservation?
        var qualified: [Qualified] = []
        for observation in ordered {
            guard observation.sessionID == sessionID, observation.signalID == signalID else {
                throw RecordedTripSummaryError.scopeMismatch
            }
            guard observation.sourceSegment >= 0 else {
                throw RecordedTripSummaryError.invalidSourceSegment(observation.sourceSequence)
            }
            guard observation.timestampSeconds.isFinite else {
                throw RecordedTripSummaryError.invalidTimestamp(observation.sourceSequence)
            }
            if let previous {
                guard previous.sourceSequence != observation.sourceSequence else {
                    throw RecordedTripSummaryError.duplicateSequence(observation.sourceSequence)
                }
                guard previous.timestampSeconds < observation.timestampSeconds else {
                    throw RecordedTripSummaryError.nonIncreasingTimestamp(observation.sourceSequence)
                }
            }
            previous = observation
            var reasons: [RecordedTripExclusionReason] = []
            if observation.timestampSeconds < startSeconds || observation.timestampSeconds > endSeconds {
                reasons.append(.outsideSelectedWindow)
            }
            if observation.quality != .valid { reasons.append(.qualityNotValidOrUnknown) }
            let speed: Double
            switch observation.unit {
            case "km/h": speed = observation.value
            case "m/s": speed = observation.value * 3.6
            default: speed = observation.value; reasons.append(.unknownUnit)
            }
            if !speed.isFinite || speed < 0 { reasons.append(.invalidSpeed) }
            qualified.append(.init(observation: observation, speedKmh: speed, reasons: reasons))
        }

        let maximum = qualified.filter { $0.reasons.isEmpty }.map(\.speedKmh).max()
        var distance = 0.0
        var covered = 0.0
        var moving = 0.0
        var average = 0.0
        var exclusions: [RecordedTripExcludedInterval] = []
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
            let scale = max(start.speedKmh, end.speedKmh)
            let normalizedMean = scale > 0 ? (start.speedKmh / scale + end.speedKmh / scale) / 2 : 0
            let midpoint = scale * normalizedMean
            // Scale exponents before multiplying: duration / 3600 may underflow
            // even when the eventual speed * duration / 3600 is representable.
            let increment = scaledProduct(scale, duration, dividingBy: 3600, factor: normalizedMean)
            let newCovered = covered + duration
            guard increment.isFinite, (distance + increment).isFinite, newCovered.isFinite,
                  scale == 0 || (increment > 0 && midpoint > 0) else {
                exclusions.append(.init(sourceSequences: sequences, reasons: [.unrepresentableCalculation]))
                continue
            }
            // Duration-weighted mean avoids dividing an underflowed distance
            // or a subnormal duration converted to hours.
            let newAverage = weightedMean(average, weight: covered, midpoint, weight: duration, denominator: newCovered)
            var movingIncrement = 0.0
            let threshold = policy.movingThresholdKmh
            if start.speedKmh >= threshold && end.speedKmh >= threshold {
                movingIncrement = duration
            } else if start.speedKmh >= threshold || end.speedKmh >= threshold {
                let crossing = (threshold - start.speedKmh) / (end.speedKmh - start.speedKmh)
                movingIncrement = duration * (start.speedKmh >= threshold ? crossing : 1 - crossing)
            }
            guard newAverage.isFinite, newAverage > 0 || (average == 0 && midpoint == 0),
                  (moving + movingIncrement).isFinite else {
                exclusions.append(.init(sourceSequences: sequences, reasons: [.unrepresentableCalculation]))
                continue
            }
            average = newAverage
            distance += increment
            // Admitted intervals are ordered, nonoverlapping, and wholly within the window.
            // Cap roundoff only after validating finite candidates, never conceal overflow.
            let boundedCovered = min(newCovered, endSeconds - startSeconds)
            covered = boundedCovered
            moving = min(moving + movingIncrement, boundedCovered)
        }
        return RecordedTripSummary(sessionID: sessionID, signalID: signalID,
            startSeconds: startSeconds, endSeconds: endSeconds, policy: policy,
            distanceKilometers: covered > 0 ? distance : nil,
            coveredDurationSeconds: covered, movingDurationSeconds: moving,
            averageSpeedKmh: covered > 0 ? average : nil,
            observedMaximumSpeedKmh: maximum, excludedIntervals: exclusions)
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
