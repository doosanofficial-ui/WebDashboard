import Foundation

/// The two recorded signals required to calculate signed electrical power.
public enum RecordedEnergySignal: String, CaseIterable, Hashable, Sendable {
    case voltage
    case current
}

/// Defines how a recorded current sign maps to consumption and regeneration.
public enum RecordedEnergyCurrentSignConvention: String, Equatable, Sendable {
    case positiveCurrentMeansConsumption
    case negativeCurrentMeansConsumption
}

/// Numerical limits for a recorded-energy calculation. Times are in seconds.
public struct RecordedEnergyPolicy: Equatable, Sendable {
    public let maxGapSeconds: Double
    public let maxSampleSkewSeconds: Double
    public let currentSignConvention: RecordedEnergyCurrentSignConvention

    public init(
        maxGapSeconds: Double,
        maxSampleSkewSeconds: Double,
        currentSignConvention: RecordedEnergyCurrentSignConvention
    ) {
        self.maxGapSeconds = maxGapSeconds
        self.maxSampleSkewSeconds = maxSampleSkewSeconds
        self.currentSignConvention = currentSignConvention
    }
}

/// One recorded voltage or current reading. Quality is optional because older
/// recordings do not persist per-row quality; nil is always treated as unknown.
public struct RecordedEnergyObservation: Equatable, Sendable {
    public let signal: RecordedEnergySignal
    public let timestampSeconds: Double
    public let timeUnit: String
    public let value: Double
    public let valueUnit: String
    public let sourceSequence: Int64
    public let quality: SignalQuality?

    public init(
        signal: RecordedEnergySignal,
        timestampSeconds: Double,
        timeUnit: String,
        value: Double,
        valueUnit: String,
        sourceSequence: Int64,
        quality: SignalQuality?
    ) {
        self.signal = signal
        self.timestampSeconds = timestampSeconds
        self.timeUnit = timeUnit
        self.value = value
        self.valueUnit = valueUnit
        self.sourceSequence = sourceSequence
        self.quality = quality
    }
}

public enum RecordedEnergySummaryError: Error, Equatable, Sendable {
    case invalidWindow
    case invalidPolicy
    case ambiguousSourceSequence(sequence: Int64)
    case reversedTimestamp(
        previousSignal: RecordedEnergySignal,
        signal: RecordedEnergySignal,
        previousSequence: Int64,
        previousSeconds: Double,
        currentSequence: Int64,
        currentSeconds: Double
    )
}

/// An interval is shown with all reasons that kept it out of the energy total.
public enum RecordedEnergyExclusionReason: Hashable, Sendable {
    case afterCursor
    case beforeSelectedWindow
    case nonFiniteTimestamp(signal: RecordedEnergySignal)
    case unknownTimeUnit(signal: RecordedEnergySignal, unit: String)
    case unknownSignalUnit(signal: RecordedEnergySignal, unit: String)
    case qualityUnknown(signal: RecordedEnergySignal)
    case qualityNotValid(signal: RecordedEnergySignal, quality: String)
    case nonFiniteValue(signal: RecordedEnergySignal)
    case negativeVoltage
    case nonFinitePower
    case nonFiniteEnergy
    case maxGapExceeded
    case maxSampleSkewExceeded(signal: RecordedEnergySignal, deltaSeconds: Double)
    case noPairedSample(signal: RecordedEnergySignal)
}

public struct RecordedEnergyExcludedInterval: Identifiable, Equatable, Sendable {
    public let startSeconds: Double?
    public let endSeconds: Double?
    public let sourceSequences: [Int64]
    public let reasons: [RecordedEnergyExclusionReason]

    public var durationSeconds: Double? {
        guard let startSeconds, let endSeconds else { return nil }
        return max(0, endSeconds - startSeconds)
    }

    /// Sequence/time identity stays stable while the summary is rendered.
    public var id: String {
        let sequences = sourceSequences.map { String($0) }.joined(separator: ",")
        let start = startSeconds.map { String($0.bitPattern) } ?? "unknown"
        let end = endSeconds.map { String($0.bitPattern) } ?? "unknown"
        return "\(sequences):\(start):\(end):\(String(reflecting: reasons))"
    }

    fileprivate init(
        startSeconds: Double?,
        endSeconds: Double?,
        sourceSequences: [Int64],
        reasons: [RecordedEnergyExclusionReason]
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.sourceSequences = Array(Set(sourceSequences)).sorted()
        self.reasons = reasons.reduce(into: []) { result, reason in
            if !result.contains(reason) { result.append(reason) }
        }
    }
}

public enum RecordedEnergyUnavailableReason: Equatable, Sendable {
    case noQualifiedInterval
}

public enum RecordedEnergyAvailability: Equatable, Sendable {
    case available
    case unavailable(RecordedEnergyUnavailableReason)
}

/// Selected-window energy based only on qualified recorded observations.
public struct RecordedEnergySummary: Equatable, Sendable {
    public let availability: RecordedEnergyAvailability
    public let consumedKWh: Double
    public let regeneratedKWh: Double
    /// Consumed energy minus regenerated energy under the selected sign convention.
    public var signedKWh: Double { consumedKWh - regeneratedKWh }
    public var currentSignConvention: RecordedEnergyCurrentSignConvention { policy.currentSignConvention }
    public let validDurationSeconds: Double
    public let selectedWindowStartSeconds: Double
    public let cursorSeconds: Double
    public let policy: RecordedEnergyPolicy
    public let excludedIntervals: [RecordedEnergyExcludedInterval]

    fileprivate init(
        availability: RecordedEnergyAvailability,
        consumedKWh: Double,
        regeneratedKWh: Double,
        validDurationSeconds: Double,
        selectedWindowStartSeconds: Double,
        cursorSeconds: Double,
        policy: RecordedEnergyPolicy,
        excludedIntervals: [RecordedEnergyExcludedInterval]
    ) {
        self.availability = availability
        self.consumedKWh = consumedKWh
        self.regeneratedKWh = regeneratedKWh
        self.validDurationSeconds = validDurationSeconds
        self.selectedWindowStartSeconds = selectedWindowStartSeconds
        self.cursorSeconds = cursorSeconds
        self.policy = policy
        self.excludedIntervals = excludedIntervals
    }
}

/// Pure recorded-series integration. Input order is canonicalized by persisted
/// source sequence, then checked for timestamp reversals before any time sorting.
public enum RecordedEnergySummaryCalculator {
    private struct DuplicateKey: Hashable {
        let signal: RecordedEnergySignal
        let timestampSeconds: Double
    }

    private struct Pair {
        let timestampSeconds: Double
        let supportStartSeconds: Double
        let supportEndSeconds: Double
        let powerWatts: Double?
        let sourceSequences: [Int64]
        let reasons: [RecordedEnergyExclusionReason]
    }

    private struct Barrier {
        let timestampSeconds: Double?
        let sourceSequence: Int64
        let reasons: [RecordedEnergyExclusionReason]
    }

    /// All observations must belong to one selected session. Callers validate
    /// each source row's session ID against that session before mapping it here.
    ///
    public static func calculate(
        observations: [RecordedEnergyObservation],
        selectedWindowStartSeconds: Double,
        cursorSeconds: Double,
        policy: RecordedEnergyPolicy
    ) throws -> RecordedEnergySummary {
        guard selectedWindowStartSeconds.isFinite, cursorSeconds.isFinite,
              selectedWindowStartSeconds >= 0, cursorSeconds >= selectedWindowStartSeconds else {
            throw RecordedEnergySummaryError.invalidWindow
        }
        guard policy.maxGapSeconds.isFinite, policy.maxGapSeconds > 0,
              policy.maxSampleSkewSeconds.isFinite, policy.maxSampleSkewSeconds >= 0 else {
            throw RecordedEnergySummaryError.invalidPolicy
        }

        var exclusions: [RecordedEnergyExcludedInterval] = []
        var barriers: [Barrier] = []
        var inWindow: [RecordedEnergyObservation] = []
        var unlocated: [RecordedEnergyObservation] = []
        for observation in observations {
            guard observation.timestampSeconds.isFinite else {
                let reasons = unique(observationReasons(observation) + [.nonFiniteTimestamp(signal: observation.signal)])
                barriers.append(Barrier(timestampSeconds: nil, sourceSequence: observation.sourceSequence, reasons: reasons))
                exclusions.append(.init(startSeconds: nil, endSeconds: nil,
                    sourceSequences: [observation.sourceSequence],
                    reasons: reasons))
                unlocated.append(observation)
                continue
            }
            guard observation.timeUnit == "s" else {
                let reasons = unique(observationReasons(observation) + [
                    .unknownTimeUnit(signal: observation.signal, unit: observation.timeUnit)
                ])
                barriers.append(Barrier(timestampSeconds: nil, sourceSequence: observation.sourceSequence, reasons: reasons))
                exclusions.append(.init(startSeconds: nil, endSeconds: nil,
                    sourceSequences: [observation.sourceSequence],
                    reasons: reasons))
                unlocated.append(observation)
                continue
            }
            if observation.timestampSeconds > cursorSeconds {
                exclusions.append(.init(startSeconds: observation.timestampSeconds, endSeconds: observation.timestampSeconds,
                    sourceSequences: [observation.sourceSequence], reasons: [.afterCursor]))
                continue
            }
            if observation.timestampSeconds < selectedWindowStartSeconds {
                exclusions.append(.init(startSeconds: observation.timestampSeconds, endSeconds: observation.timestampSeconds,
                    sourceSequences: [observation.sourceSequence], reasons: [.beforeSelectedWindow]))
                continue
            }
            inWindow.append(observation)
        }

        // SQLite sequence is the recorded source order. Exact duplicated rows
        // collapse; conflicting reuse of a sequence is ambiguous and rejected.
        let candidates = (inWindow + unlocated).sorted { $0.sourceSequence < $1.sourceSequence }
        var uniqueSequence: [Int64: RecordedEnergyObservation] = [:]
        var sourceOrdered: [RecordedEnergyObservation] = []
        for observation in candidates {
            if let previous = uniqueSequence[observation.sourceSequence] {
                guard previous == observation else {
                    throw RecordedEnergySummaryError.ambiguousSourceSequence(sequence: observation.sourceSequence)
                }
                continue
            }
            uniqueSequence[observation.sourceSequence] = observation
            if observation.timeUnit == "s", observation.timestampSeconds.isFinite,
               observation.timestampSeconds >= selectedWindowStartSeconds,
               observation.timestampSeconds <= cursorSeconds {
                sourceOrdered.append(observation)
            }
        }

        var previousSourceObservation: RecordedEnergyObservation?
        for observation in sourceOrdered {
            if let previous = previousSourceObservation,
               observation.timestampSeconds < previous.timestampSeconds {
                throw RecordedEnergySummaryError.reversedTimestamp(
                    previousSignal: previous.signal,
                    signal: observation.signal,
                    previousSequence: previous.sourceSequence,
                    previousSeconds: previous.timestampSeconds,
                    currentSequence: observation.sourceSequence,
                    currentSeconds: observation.timestampSeconds
                )
            }
            previousSourceObservation = observation
        }

        // At a duplicate time/signal, the greatest persisted sequence wins.
        var latestAtTime: [DuplicateKey: RecordedEnergyObservation] = [:]
        for observation in sourceOrdered {
            latestAtTime[DuplicateKey(signal: observation.signal, timestampSeconds: observation.timestampSeconds)] = observation
        }
        let selected = latestAtTime.values.sorted {
            if $0.timestampSeconds != $1.timestampSeconds { return $0.timestampSeconds < $1.timestampSeconds }
            if $0.signal != $1.signal { return $0.signal.rawValue < $1.signal.rawValue }
            return $0.sourceSequence < $1.sourceSequence
        }
        let voltages = selected.filter { $0.signal == .voltage }
        let currents = selected.filter { $0.signal == .current }

        // One-to-one chronological pairing: consume both pending samples only
        // when they fit the skew bound; otherwise exclude the earlier sample.
        var pairs: [Pair] = []
        var voltageIndex = 0
        var currentIndex = 0
        while voltageIndex < voltages.count && currentIndex < currents.count {
            let voltage = voltages[voltageIndex]
            let current = currents[currentIndex]
            let skew = abs(voltage.timestampSeconds - current.timestampSeconds)
            if skew <= policy.maxSampleSkewSeconds {
                pairs.append(makePair(voltage: voltage, current: current, policy: policy))
                voltageIndex += 1
                currentIndex += 1
            } else if voltage.timestampSeconds < current.timestampSeconds {
                let barrier = unpaired(voltage, counterparts: currents, maxSkewSeconds: policy.maxSampleSkewSeconds)
                barriers.append(barrier)
                exclusions.append(.init(startSeconds: barrier.timestampSeconds, endSeconds: barrier.timestampSeconds,
                    sourceSequences: [barrier.sourceSequence], reasons: barrier.reasons))
                voltageIndex += 1
            } else {
                let barrier = unpaired(current, counterparts: voltages, maxSkewSeconds: policy.maxSampleSkewSeconds)
                barriers.append(barrier)
                exclusions.append(.init(startSeconds: barrier.timestampSeconds, endSeconds: barrier.timestampSeconds,
                    sourceSequences: [barrier.sourceSequence], reasons: barrier.reasons))
                currentIndex += 1
            }
        }
        while voltageIndex < voltages.count {
            let barrier = unpaired(voltages[voltageIndex], counterparts: currents,
                maxSkewSeconds: policy.maxSampleSkewSeconds)
            barriers.append(barrier)
            exclusions.append(.init(startSeconds: barrier.timestampSeconds, endSeconds: barrier.timestampSeconds,
                sourceSequences: [barrier.sourceSequence], reasons: barrier.reasons))
            voltageIndex += 1
        }
        while currentIndex < currents.count {
            let barrier = unpaired(currents[currentIndex], counterparts: voltages,
                maxSkewSeconds: policy.maxSampleSkewSeconds)
            barriers.append(barrier)
            exclusions.append(.init(startSeconds: barrier.timestampSeconds, endSeconds: barrier.timestampSeconds,
                sourceSequences: [barrier.sourceSequence], reasons: barrier.reasons))
            currentIndex += 1
        }

        var consumedWs = 0.0
        var regeneratedWs = 0.0
        var validDurationSeconds = 0.0
        if pairs.count == 1, let only = pairs.first, !only.reasons.isEmpty {
            exclusions.append(.init(startSeconds: only.timestampSeconds, endSeconds: only.timestampSeconds,
                sourceSequences: only.sourceSequences, reasons: only.reasons))
        }
        if pairs.count > 1 {
            for index in 1..<pairs.count {
                let start = pairs[index - 1]
                let end = pairs[index]
                let duration = end.timestampSeconds - start.timestampSeconds
                guard duration > 0 else { continue }

                var reasons = start.reasons + end.reasons
                let intervalBarriers = barriers.filter { barrier in
                    guard let time = barrier.timestampSeconds else { return true }
                    return time >= start.supportStartSeconds && time <= end.supportEndSeconds
                }
                reasons.append(contentsOf: intervalBarriers.flatMap(\.reasons))
                let intervalSequences = start.sourceSequences + end.sourceSequences
                    + intervalBarriers.map(\.sourceSequence)
                if duration > policy.maxGapSeconds { reasons.append(.maxGapExceeded) }
                if !reasons.isEmpty {
                    exclusions.append(.init(startSeconds: start.timestampSeconds, endSeconds: end.timestampSeconds,
                        sourceSequences: intervalSequences, reasons: reasons))
                    continue
                }
                guard let startPower = start.powerWatts, let endPower = end.powerWatts else { continue }
                let energy = trapezoidEnergy(startPower, endPower, duration: duration)
                let nextConsumedWs = consumedWs + energy.consumedWs
                let nextRegeneratedWs = regeneratedWs + energy.regeneratedWs
                let nextDuration = validDurationSeconds + duration
                guard energy.consumedWs.isFinite, energy.regeneratedWs.isFinite,
                      nextConsumedWs.isFinite, nextRegeneratedWs.isFinite, nextDuration.isFinite else {
                    exclusions.append(.init(startSeconds: start.timestampSeconds, endSeconds: end.timestampSeconds,
                        sourceSequences: start.sourceSequences + end.sourceSequences, reasons: [.nonFiniteEnergy]))
                    continue
                }
                consumedWs = nextConsumedWs
                regeneratedWs = nextRegeneratedWs
                validDurationSeconds = nextDuration
            }
        }

        let consumedKWh = consumedWs / 3_600_000
        let regeneratedKWh = regeneratedWs / 3_600_000
        let availability: RecordedEnergyAvailability = validDurationSeconds > 0
            ? .available : .unavailable(.noQualifiedInterval)
        return RecordedEnergySummary(
            availability: availability,
            consumedKWh: consumedKWh,
            regeneratedKWh: regeneratedKWh,
            validDurationSeconds: validDurationSeconds,
            selectedWindowStartSeconds: selectedWindowStartSeconds,
            cursorSeconds: cursorSeconds,
            policy: policy,
            excludedIntervals: exclusions
        )
    }

    private static func makePair(
        voltage: RecordedEnergyObservation,
        current: RecordedEnergyObservation,
        policy: RecordedEnergyPolicy
    ) -> Pair {
        var reasons: [RecordedEnergyExclusionReason] = []
        reasons.append(contentsOf: observationReasons(voltage))
        reasons.append(contentsOf: observationReasons(current))
        var powerWatts: Double?
        if reasons.isEmpty {
            let rawPower = voltage.value * current.value
            if rawPower.isFinite {
                powerWatts = policy.currentSignConvention == .positiveCurrentMeansConsumption ? rawPower : -rawPower
            } else {
                reasons.append(.nonFinitePower)
            }
        }
        return Pair(
            timestampSeconds: max(voltage.timestampSeconds, current.timestampSeconds),
            supportStartSeconds: min(voltage.timestampSeconds, current.timestampSeconds),
            supportEndSeconds: max(voltage.timestampSeconds, current.timestampSeconds),
            powerWatts: powerWatts,
            sourceSequences: [voltage.sourceSequence, current.sourceSequence],
            reasons: unique(reasons)
        )
    }

    private static func observationReasons(_ observation: RecordedEnergyObservation) -> [RecordedEnergyExclusionReason] {
        var reasons: [RecordedEnergyExclusionReason] = []
        if !observation.value.isFinite { reasons.append(.nonFiniteValue(signal: observation.signal)) }
        let expectedUnit = observation.signal == .voltage ? "V" : "A"
        if observation.valueUnit != expectedUnit {
            reasons.append(.unknownSignalUnit(signal: observation.signal, unit: observation.valueUnit))
        }
        if let quality = observation.quality {
            if quality != .valid {
                reasons.append(.qualityNotValid(signal: observation.signal, quality: quality.rawValue))
            }
        } else {
            reasons.append(.qualityUnknown(signal: observation.signal))
        }
        if observation.signal == .voltage, observation.value.isFinite, observation.value < 0 {
            reasons.append(.negativeVoltage)
        }
        return reasons
    }

    private static func unpaired(
        _ observation: RecordedEnergyObservation,
        counterparts: [RecordedEnergyObservation],
        maxSkewSeconds: Double
    ) -> Barrier {
        let reason: RecordedEnergyExclusionReason
        if counterparts.isEmpty {
            reason = .noPairedSample(signal: observation.signal)
        } else {
            let nearestSkew = counterparts.map { abs($0.timestampSeconds - observation.timestampSeconds) }.min() ?? .infinity
            // A nearby sample already consumed by one-to-one matching cannot be
            // reused; a distant one is reported as a skew failure.
            if nearestSkew > maxSkewSeconds {
                reason = .maxSampleSkewExceeded(signal: observation.signal, deltaSeconds: nearestSkew)
            } else {
                reason = .noPairedSample(signal: observation.signal)
            }
        }
        return Barrier(timestampSeconds: observation.timestampSeconds, sourceSequence: observation.sourceSequence,
            reasons: unique(observationReasons(observation) + [reason]))
    }

    private static func trapezoidEnergy(_ startPower: Double, _ endPower: Double, duration: Double)
        -> (consumedWs: Double, regeneratedWs: Double) {
        if startPower >= 0, endPower >= 0 {
            return ((startPower + endPower) * duration / 2, 0)
        }
        if startPower <= 0, endPower <= 0 {
            return (0, -(startPower + endPower) * duration / 2)
        }
        let scale = max(abs(startPower), abs(endPower))
        let startFraction = (abs(startPower) / scale)
        let endFraction = (abs(endPower) / scale)
        let crossingFraction = startFraction / (startFraction + endFraction)
        if startPower > 0 {
            let consumed = startPower * duration * crossingFraction / 2
            let regenerated = -endPower * duration * (1 - crossingFraction) / 2
            return (consumed, regenerated)
        }
        let regenerated = -startPower * duration * crossingFraction / 2
        let consumed = endPower * duration * (1 - crossingFraction) / 2
        return (consumed, regenerated)
    }

    private static func unique(_ reasons: [RecordedEnergyExclusionReason]) -> [RecordedEnergyExclusionReason] {
        reasons.reduce(into: []) { result, reason in
            if !result.contains(reason) { result.append(reason) }
        }
    }
}
