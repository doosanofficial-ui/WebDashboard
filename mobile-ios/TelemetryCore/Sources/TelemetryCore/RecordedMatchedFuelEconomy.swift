import Foundation

public struct RecordedMatchedFuelEconomyPolicy: Equatable, Sendable {
    /// Separate limits bound interpolation inside each original adjacent sample pair.
    public let maximumSpeedIntervalSeconds: Double
    public let maximumFuelIntervalSeconds: Double
    /// Combined original row count, including invalid rows. Hard ceiling: 200,000.
    public let maximumTotalObservations: Int
    public init(maximumSpeedIntervalSeconds: Double, maximumFuelIntervalSeconds: Double,
                maximumTotalObservations: Int = 200_000) {
        self.maximumSpeedIntervalSeconds = maximumSpeedIntervalSeconds
        self.maximumFuelIntervalSeconds = maximumFuelIntervalSeconds
        self.maximumTotalObservations = maximumTotalObservations
    }
}

public enum RecordedMatchedFuelEconomyError: Error, Equatable, Sendable {
    case invalidWindow, invalidPolicy, inputLimitExceeded, scopeMismatch
    case malformedProvenance, invalidTimestamp, duplicateSequence, nonIncreasingTimestamp
    case crossSignalSequenceCollision(Int64)
    case globalTimestampRollback(previousSequence: Int64, previousSeconds: Double,
                                 currentSequence: Int64, currentSeconds: Double)
}

public enum RecordedMatchedFuelEconomyUnavailable: String, Equatable, Sendable {
    case noQualifiedCommonInterval, zeroMatchedDistance, unrepresentableRatio
}

/// Every interval retains the original brackets. They need not have synchronous timestamps.
/// All raw timestamps must share the session's original monotonic timeline, not display time.
public struct RecordedMatchedFuelEconomyInterval: Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let speedStart: RecordedTripObservation
    public let speedEnd: RecordedTripObservation
    public let fuelStart: RecordedFuelObservation
    public let fuelEnd: RecordedFuelObservation
    public let distanceKilometers: Double
    public let fuelLiters: Double
}

/// Partial matched-coverage estimate, never a complete-trip or synchronous-measurement claim.
/// Uses linear interpolation within two individually qualified original adjacent intervals.
/// No fuel-type, MAF, engine-idle, fuel-cut or DPF inference is performed.
public struct RecordedMatchedFuelEconomy: Equatable, Sendable {
    public let sessionID: String
    public let speedSignalID: String
    public let fuelSignalID: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let policy: RecordedMatchedFuelEconomyPolicy
    public let distanceKilometers: Double?
    public let fuelLiters: Double?
    public let litersPer100Kilometers: Double?
    public let unavailableReason: RecordedMatchedFuelEconomyUnavailable?
    public let coveredDurationSeconds: Double
    public let matchedIntervals: [RecordedMatchedFuelEconomyInterval]
    /// Adjacent original pairs rejected before matching, including quality/unit/source/gap barriers.
    public let excludedSpeedPairCount: Int
    public let excludedFuelPairCount: Int
    /// Common intervals rejected jointly. Neither stream contributes independently.
    public let numericRejectedCommonIntervalCount: Int
    public var interpolationAssumption: String { "linearWithinQualifiedOriginalAdjacentIntervals" }
    public var coverageFraction: Double {
        endSeconds > startSeconds ? coveredDurationSeconds / (endSeconds - startSeconds) : 0
    }
}

public enum RecordedMatchedFuelEconomyCalculator {
    private struct Interval {
        let lowerIndex: Int
        let start: Double
        let end: Double
        let first: Double
        let second: Double
    }

    public static func calculate(speedObservations: [RecordedTripObservation],
                                 fuelObservations: [RecordedFuelObservation],
                                 sessionID: String, speedSignalID: String, fuelSignalID: String,
                                 startSeconds: Double, endSeconds: Double,
                                 policy: RecordedMatchedFuelEconomyPolicy) throws -> RecordedMatchedFuelEconomy {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0,
              endSeconds >= startSeconds else { throw RecordedMatchedFuelEconomyError.invalidWindow }
        guard policy.maximumSpeedIntervalSeconds.isFinite, policy.maximumSpeedIntervalSeconds > 0,
              policy.maximumFuelIntervalSeconds.isFinite, policy.maximumFuelIntervalSeconds > 0,
              policy.maximumTotalObservations > 0, policy.maximumTotalObservations <= 200_000 else {
            throw RecordedMatchedFuelEconomyError.invalidPolicy
        }
        // Subtraction only after the first bound, avoiding integer overflow in a count sum.
        guard speedObservations.count <= policy.maximumTotalObservations,
              fuelObservations.count <= policy.maximumTotalObservations - speedObservations.count else {
            throw RecordedMatchedFuelEconomyError.inputLimitExceeded
        }
        guard !sessionID.isEmpty, !speedSignalID.isEmpty, !fuelSignalID.isEmpty,
              speedSignalID != fuelSignalID else { throw RecordedMatchedFuelEconomyError.scopeMismatch }
        let speed = speedObservations.sorted { $0.sourceSequence < $1.sourceSequence }
        let fuel = fuelObservations.sorted { $0.sourceSequence < $1.sourceSequence }
        // Canonical archive identity is (sessionID, sequence), not (signalID, sequence).
        // A scalar row cannot be claimed by both distinct selected signals, even outside the window.
        var speedIdentityIndex = 0, fuelIdentityIndex = 0
        while speedIdentityIndex < speed.count && fuelIdentityIndex < fuel.count {
            let a = speed[speedIdentityIndex].sourceSequence
            let b = fuel[fuelIdentityIndex].sourceSequence
            guard a != b else { throw RecordedMatchedFuelEconomyError.crossSignalSequenceCollision(a) }
            if a < b { speedIdentityIndex += 1 } else { fuelIdentityIndex += 1 }
        }
        let speedIntervals = try qualify(count: speed.count, sessionID: sessionID, signalID: speedSignalID,
            gap: policy.maximumSpeedIntervalSeconds, isSpeed: true) { i in
                let p = speed[i]
                return (p.sessionID, p.signalID, p.sourceSegment, p.sourceSequence,
                        p.timestampSeconds, p.value, p.unit, p.quality == .valid)
            }
        let fuelIntervals = try qualify(count: fuel.count, sessionID: sessionID, signalID: fuelSignalID,
            gap: policy.maximumFuelIntervalSeconds, isSpeed: false) { i in
                let p = fuel[i]
                return (p.sessionID, p.signalID, p.sourceSegment, p.sourceSequence,
                        p.timestampSeconds, p.value, p.unit, p.quality == .valid)
            }
        // Canonical persisted sequence is authoritative across both selected scalars.
        // Equal cross-signal timestamps are possible; decreasing raw time is ambiguous.
        var chronologySpeed = 0, chronologyFuel = 0
        var previousSequence: Int64?
        var previousTime = 0.0
        while chronologySpeed < speed.count || chronologyFuel < fuel.count {
            let takeSpeed = chronologyFuel == fuel.count ||
                (chronologySpeed < speed.count && speed[chronologySpeed].sourceSequence < fuel[chronologyFuel].sourceSequence)
            let sequence: Int64
            let time: Double
            if takeSpeed {
                sequence = speed[chronologySpeed].sourceSequence
                time = speed[chronologySpeed].timestampSeconds
                chronologySpeed += 1
            } else {
                sequence = fuel[chronologyFuel].sourceSequence
                time = fuel[chronologyFuel].timestampSeconds
                chronologyFuel += 1
            }
            if let previousSequence, time < previousTime {
                throw RecordedMatchedFuelEconomyError.globalTimestampRollback(
                    previousSequence: previousSequence, previousSeconds: previousTime,
                    currentSequence: sequence, currentSeconds: time)
            }
            previousSequence = sequence
            previousTime = time
        }
        var i = 0, j = 0, rejected = 0
        var distance = 0.0, liters = 0.0, covered = 0.0
        var matches: [RecordedMatchedFuelEconomyInterval] = []
        // At least one cursor advances per iteration; <= speedPairs + fuelPairs iterations.
        while i < speedIntervals.count && j < fuelIntervals.count {
            let s = speedIntervals[i], f = fuelIntervals[j]
            let lower = max(startSeconds, max(s.start, f.start))
            let upper = min(endSeconds, min(s.end, f.end))
            if upper > lower {
                if let d = integral(s, lower: lower, upper: upper),
                   let l = integral(f, lower: lower, upper: upper),
                   (distance + d).isFinite, (liters + l).isFinite,
                   (covered + (upper - lower)).isFinite {
                    distance += d
                    liters += l
                    covered = min(covered + (upper - lower), endSeconds - startSeconds)
                    matches.append(.init(startSeconds: lower, endSeconds: upper,
                        speedStart: speed[s.lowerIndex], speedEnd: speed[s.lowerIndex + 1],
                        fuelStart: fuel[f.lowerIndex], fuelEnd: fuel[f.lowerIndex + 1],
                        distanceKilometers: d, fuelLiters: l))
                } else {
                    rejected += 1
                }
            }
            if s.end <= f.end { i += 1 }
            if f.end <= s.end { j += 1 }
        }
        var economy: Double?
        var unavailable: RecordedMatchedFuelEconomyUnavailable?
        if matches.isEmpty {
            unavailable = .noQualifiedCommonInterval
        } else if distance == 0 {
            unavailable = .zeroMatchedDistance
        } else {
            let ratio = scaledProduct(liters, 100, divisor: distance)
            if ratio.isFinite && (ratio > 0 || liters == 0) { economy = ratio }
            else { unavailable = .unrepresentableRatio }
        }
        return .init(sessionID: sessionID, speedSignalID: speedSignalID, fuelSignalID: fuelSignalID,
            startSeconds: startSeconds, endSeconds: endSeconds, policy: policy,
            distanceKilometers: matches.isEmpty ? nil : distance,
            fuelLiters: matches.isEmpty ? nil : liters, litersPer100Kilometers: economy,
            unavailableReason: unavailable, coveredDurationSeconds: covered, matchedIntervals: matches,
            excludedSpeedPairCount: max(0, speed.count - 1) - speedIntervals.count,
            excludedFuelPairCount: max(0, fuel.count - 1) - fuelIntervals.count,
            numericRejectedCommonIntervalCount: rejected)
    }

    private typealias Raw = (session: String, signal: String, segment: Int, sequence: Int64,
                             time: Double, value: Double?, unit: String, valid: Bool)
    private static func qualify(count: Int, sessionID: String, signalID: String, gap: Double,
                                isSpeed: Bool, row: (Int) -> Raw) throws -> [Interval] {
        var result: [Interval] = []
        var previous: Raw?
        var previousValue: Double?
        for index in 0..<count {
            let p = row(index)
            guard p.session == sessionID, p.signal == signalID else {
                throw RecordedMatchedFuelEconomyError.scopeMismatch
            }
            guard p.segment >= 0, p.sequence >= 0 else {
                throw RecordedMatchedFuelEconomyError.malformedProvenance
            }
            guard p.time.isFinite, p.time >= 0 else { throw RecordedMatchedFuelEconomyError.invalidTimestamp }
            if let previous {
                guard p.sequence != previous.sequence else { throw RecordedMatchedFuelEconomyError.duplicateSequence }
                guard p.time > previous.time else { throw RecordedMatchedFuelEconomyError.nonIncreasingTimestamp }
            }
            var value: Double?
            if p.valid, let rawValue = p.value {
                let unitValid = isSpeed ? (p.unit == "km/h" || p.unit == "m/s") : p.unit == "L/h"
                let converted = isSpeed && p.unit == "m/s" ? rawValue * 3.6 : rawValue
                if unitValid && converted.isFinite && converted >= 0 { value = converted }
            }
            if let previous, let a = previousValue, let b = value,
               p.segment == previous.segment, p.time - previous.time <= gap {
                result.append(.init(lowerIndex: index - 1, start: previous.time, end: p.time,
                                    first: a, second: b))
            }
            // Invalid rows remain barriers: never filter them before forming adjacent pairs.
            previous = p
            previousValue = value
        }
        return result
    }

    private static func integral(_ p: Interval, lower: Double, upper: Double) -> Double? {
        let scale = max(p.first, p.second)
        if scale == 0 { return 0 }
        let x = (lower - p.start) / (p.end - p.start)
        let y = (upper - p.start) / (p.end - p.start)
        let a = p.first / scale, b = p.second / scale
        let factor = ((1 - x) * a + x * b + (1 - y) * a + y * b) / 2
        let value = scaledProduct(scale, upper - lower, divisor: 3600, factor: factor)
        // A positive integral rounded to zero is unavailable, not observed zero consumption.
        return value.isFinite && value > 0 ? value : nil
    }

    private static func scaledProduct(_ a: Double, _ b: Double, divisor: Double,
                                      factor: Double = 1) -> Double {
        guard a > 0, b > 0, factor > 0 else { return 0 }
        return Double(sign: .plus, exponent: a.exponent + b.exponent - divisor.exponent,
                      significand: a.significand * b.significand * factor / divisor.significand)
    }
}
