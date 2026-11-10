import Foundation

/// The caller must verify these absolute UTC instants with its calendar adapter.
/// No fixed 604800-second week and no current-device timezone are assumed here.
public struct VerifiedWeekPair: Equatable, Sendable {
    public let priorStartUTC: Double
    public let currentStartUTC: Double
    public let currentEndUTC: Double
    public let timeZoneIdentifier: String
    public let calendarIdentifier: String
    public let firstWeekday: Int
    public let minimumDaysInFirstWeek: Int
    public init(priorStartUTC: Double, currentStartUTC: Double, currentEndUTC: Double,
                timeZoneIdentifier: String, calendarIdentifier: String,
                firstWeekday: Int, minimumDaysInFirstWeek: Int) {
        self.priorStartUTC = priorStartUTC; self.currentStartUTC = currentStartUTC
        self.currentEndUTC = currentEndUTC; self.timeZoneIdentifier = timeZoneIdentifier
        self.calendarIdentifier = calendarIdentifier; self.firstWeekday = firstWeekday
        self.minimumDaysInFirstWeek = minimumDaysInFirstWeek
    }
}

public enum WeeklySpeedSourceUnit: String, Sendable { case kilometersPerHour = "km/h", metersPerSecond = "m/s" }
public struct WeeklyTripProvenance: Equatable, Sendable {
    public let signalID: String
    public let sourceUnit: WeeklySpeedSourceUnit
    /// Versioned archive projection, quality/gap policy and normalization contract.
    public let policyRevision: String
    public init(signalID: String, sourceUnit: WeeklySpeedSourceUnit, policyRevision: String) {
        self.signalID = signalID; self.sourceUnit = sourceUnit; self.policyRevision = policyRevision
    }
}

/// Adapter input only, deliberately not Codable. IDs never appear in aggregate outputs.
/// UTC bounds must describe exactly the bounded source summary, not the full trip.
/// Convert elapsed timestamps with verified archive epoch mapping before constructing.
public struct QualifiedWeeklyTrip: Equatable, Sendable {
    let sessionKey: String
    let archiveScopeKey: String
    let provenance: WeeklyTripProvenance
    let startUTC: Double
    let endUTC: Double
    let coveredSeconds: Double
    let distanceKilometers: Double?
    let averageSpeedKmh: Double?
    let excludedIntervalCount: Int
    public init(sessionKey: String, archiveScopeKey: String, provenance: WeeklyTripProvenance,
                startUTC: Double, endUTC: Double, coveredSeconds: Double,
                distanceKilometers: Double?, averageSpeedKmh: Double?, excludedIntervalCount: Int) {
        self.sessionKey = sessionKey; self.archiveScopeKey = archiveScopeKey; self.provenance = provenance
        self.startUTC = startUTC; self.endUTC = endUTC; self.coveredSeconds = coveredSeconds
        self.distanceKilometers = distanceKilometers; self.averageSpeedKmh = averageSpeedKmh
        self.excludedIntervalCount = excludedIntervalCount
    }
}

public enum WeeklyTripExclusion: String, Hashable, Sendable {
    case provenanceMismatch, boundaryRequiresBoundedSummary, overlap
}
public enum WeeklyTripError: Error { case invalidWeekContract, invalidSelection, inputLimitExceeded, unrepresentableTotal }

/// Partial observed archive totals, not full-week driving or engine-on totals.
public struct RecordedWeeklyTrip: Equatable, Sendable {
    public let startUTC: Double
    public let endUTC: Double
    public let qualifiedSessionCount: Int
    public let acceptedSummaryCount: Int
    public let duplicateCount: Int
    public let distanceKilometers: Double?
    public let coveredSeconds: Double
    /// Duration-weighted mean of qualified summary means, never a mean of trip means.
    public let averageSpeedKmh: Double?
    /// Sum across accepted sessions; not wall-clock coverage of the entire week.
    public let summaryWindowSeconds: Double
    public let upstreamExcludedIntervalCount: Int
    public let exclusions: [WeeklyTripExclusion: Int]
    public var coverageFraction: Double? {
        summaryWindowSeconds > 0 ? coveredSeconds / summaryWindowSeconds : nil
    }
}
public struct WeeklyTripComparison: Equatable, Sendable {
    public let weeks: VerifiedWeekPair
    public let selected: WeeklyTripProvenance
    public let prior: RecordedWeeklyTrip
    public let current: RecordedWeeklyTrip
    /// Count once for the comparison. Invalid bounds may prevent week assignment.
    public let unallocatedInvalidInputCount: Int
    // No percent change when baseline is absent/zero, no invented idle/fuel/score.
}

public enum RecordedWeeklyTripCalculator {
    /// Bounded quadratic duplicate/overlap validation. Reject, never truncate input.
    public static let maximumSummaryCount = 2000

    public static func calculate(_ rows: [QualifiedWeeklyTrip], weeks: VerifiedWeekPair,
                                 selected: WeeklyTripProvenance) throws -> WeeklyTripComparison {
        guard rows.count <= maximumSummaryCount else { throw WeeklyTripError.inputLimitExceeded }
        let b = [weeks.priorStartUTC, weeks.currentStartUTC, weeks.currentEndUTC]
        guard b.allSatisfy({ $0.isFinite }), b[0] < b[1], b[1] < b[2],
              (b[1] - b[0]).isFinite, (b[2] - b[1]).isFinite,
              !weeks.timeZoneIdentifier.isEmpty, weeks.calendarIdentifier == "gregorian",
              (1...7).contains(weeks.firstWeekday), (1...7).contains(weeks.minimumDaysInFirstWeek) else {
            throw WeeklyTripError.invalidWeekContract
        }
        guard !selected.signalID.isEmpty, !selected.policyRevision.isEmpty else {
            throw WeeklyTripError.invalidSelection
        }
        let valid = rows.filter(isValid)
        return try .init(weeks: weeks, selected: selected,
                         prior: summarize(valid, start: b[0], end: b[1], selected: selected),
                         current: summarize(valid, start: b[1], end: b[2], selected: selected),
                         unallocatedInvalidInputCount: rows.count - valid.count)
    }

    private static func isValid(_ row: QualifiedWeeklyTrip) -> Bool {
        guard !row.sessionKey.isEmpty, !row.archiveScopeKey.isEmpty,
              row.startUTC.isFinite, row.endUTC.isFinite, row.endUTC > row.startUTC,
              (row.endUTC - row.startUTC).isFinite, row.coveredSeconds.isFinite,
              row.coveredSeconds >= 0, row.coveredSeconds <= row.endUTC - row.startUTC,
              row.excludedIntervalCount >= 0 else { return false }
        if row.coveredSeconds == 0 { return row.distanceKilometers == nil && row.averageSpeedKmh == nil }
        guard let distance = row.distanceKilometers, let mean = row.averageSpeedKmh else { return false }
        return distance.isFinite && distance >= 0 && mean.isFinite && mean >= 0
    }

    private static func summarize(_ rows: [QualifiedWeeklyTrip], start: Double, end: Double,
                                  selected: WeeklyTripProvenance) throws -> RecordedWeeklyTrip {
        var exclusions: [WeeklyTripExclusion: Int] = [:]
        var candidates: [QualifiedWeeklyTrip] = []
        var duplicates = 0
        for row in rows {
            // [start, end): adjacent windows can share an endpoint but no duration.
            guard row.endUTC > start, row.startUTC < end else { continue }
            guard row.provenance == selected else { exclusions[.provenanceMismatch, default: 0] += 1; continue }
            guard row.startUTC >= start, row.endUTC <= end else {
                exclusions[.boundaryRequiresBoundedSummary, default: 0] += 1; continue
            }
            if candidates.contains(row) { duplicates += 1 } else { candidates.append(row) }
        }
        var accepted: [QualifiedWeeklyTrip] = []
        for (index, row) in candidates.enumerated() {
            let overlaps = candidates.enumerated().contains { otherIndex, other in
                index != otherIndex && row.sessionKey == other.sessionKey &&
                max(row.startUTC, other.startUTC) < min(row.endUTC, other.endUTC)
            }
            if overlaps { exclusions[.overlap, default: 0] += 1 } else { accepted.append(row) }
        }
        accepted.sort {
            if $0.sessionKey != $1.sessionKey { return $0.sessionKey < $1.sessionKey }
            if $0.startUTC != $1.startUTC { return $0.startUTC < $1.startUTC }
            if $0.endUTC != $1.endUTC { return $0.endUTC < $1.endUTC }
            return $0.archiveScopeKey < $1.archiveScopeKey
        }
        var duration = 0.0, window = 0.0, distance = 0.0
        var upstreamExclusions = 0
        var sessions = Set<String>()
        for row in accepted {
            duration += row.coveredSeconds; window += row.endUTC - row.startUTC
            let (count, overflow) = upstreamExclusions.addingReportingOverflow(row.excludedIntervalCount)
            guard !overflow else { throw WeeklyTripError.unrepresentableTotal }
            upstreamExclusions = count
            if row.coveredSeconds > 0 {
                distance += row.distanceKilometers!; sessions.insert(row.sessionKey)
            }
        }
        guard duration.isFinite, window.isFinite, distance.isFinite else { throw WeeklyTripError.unrepresentableTotal }
        let mean = weightedMean(accepted, denominator: duration)
        let hasPositiveMean = accepted.contains { $0.coveredSeconds > 0 && ($0.averageSpeedKmh ?? 0) > 0 }
        guard mean.isFinite, !hasPositiveMean || mean > 0 else { throw WeeklyTripError.unrepresentableTotal }
        return .init(startUTC: start, endUTC: end, qualifiedSessionCount: sessions.count,
                     acceptedSummaryCount: accepted.count, duplicateCount: duplicates,
                     distanceKilometers: duration > 0 ? distance : nil, coveredSeconds: duration,
                     averageSpeedKmh: duration > 0 ? mean : nil, summaryWindowSeconds: window,
                     upstreamExcludedIntervalCount: upstreamExclusions, exclusions: exclusions)
    }

    /// Sum positive products before final Double rounding. Separately rounded
    /// contributions can all become zero despite a representable total mean.
    private static func weightedMean(_ rows: [QualifiedWeeklyTrip], denominator: Double) -> Double {
        var terms: [(significand: Double, exponent: Int)] = []
        for row in rows where row.coveredSeconds > 0 {
            guard let value = row.averageSpeedKmh, value > 0 else { continue }
            terms.append((value.significand * row.coveredSeconds.significand,
                          value.exponent + row.coveredSeconds.exponent))
        }
        guard let exponent = terms.map({ $0.exponent }).max() else { return 0 }
        let significand = terms.reduce(0.0) {
            $0 + Double(sign: .plus, exponent: $1.exponent - exponent, significand: $1.significand)
        }
        return Double(sign: .plus, exponent: exponent - denominator.exponent,
                      significand: significand / denominator.significand)
    }
}
