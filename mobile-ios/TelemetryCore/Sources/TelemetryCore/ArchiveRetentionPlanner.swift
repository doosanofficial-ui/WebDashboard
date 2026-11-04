import Foundation

/// Preparation only: this type cannot move, delete, persist, schedule, or authorize anything.
public enum ArchiveRetentionPlanner {
    public struct Entry: Equatable {
        public let id: String
        public let scope: String
        public let endedAt: TimeInterval?
        public let protected: Bool
        public let open: Bool
        public let recoveryPending: Bool
        /// Recovered archives require separate explicit review, not ordinary age pruning.
        public let recovered: Bool
        public init(id: String, scope: String, endedAt: TimeInterval?, protected: Bool = false,
                    open: Bool = false, recoveryPending: Bool = false, recovered: Bool = false) {
            self.id = id; self.scope = scope; self.endedAt = endedAt
            self.protected = protected; self.open = open
            self.recoveryPending = recoveryPending; self.recovered = recovered
        }
    }
    public struct Snapshot: Equatable {
        public let revision: String
        public let scope: String
        public let capturedAt: TimeInterval
        public let entries: [Entry]
        public init(revision: String, scope: String, capturedAt: TimeInterval, entries: [Entry]) {
            self.revision = revision; self.scope = scope; self.capturedAt = capturedAt; self.entries = entries
        }
    }
    public enum Policy: Equatable {
        case keepAll
        case elapsed(seconds: Int)
        /// Boundary: local midnight N civil dates before the date containing `now`.
        case calendarDays(Int, timeZoneID: String)
    }
    public enum Reason: String, Equatable {
        case protected, open, recoveryPending, recovered, invalidOrMissingEnd, futureEnd
        case noSelection, keepAll, olderThanCutoff, withinRetention
    }
    public struct Decision: Equatable {
        public let id: String
        public let reason: Reason
    }
    public struct Plan: Equatable {
        public let snapshot: Snapshot
        public let policy: Policy?
        public let evaluatedAt: TimeInterval
        public let cutoff: TimeInterval?
        public let candidates: [String]
        public let decisions: [Decision]
        public let disposition = "proposalOnly"
    }
    public enum Invalid: Error { case snapshot, clock, policy, calendarBoundary }
    private static func validTime(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= 0 && value <= 253402214400
    }
    private static func identity(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= 256
    }
    public static func plan(snapshot: Snapshot, policy: Policy?, now: TimeInterval) throws -> Plan {
        guard validTime(now), validTime(snapshot.capturedAt), now >= snapshot.capturedAt,
              now - snapshot.capturedAt <= 300 else { throw Invalid.clock }
        guard identity(snapshot.revision), identity(snapshot.scope), snapshot.entries.count <= 10000 else {
            throw Invalid.snapshot
        }
        var ids = Set<String>()
        for entry in snapshot.entries {
            guard identity(entry.id), entry.scope == snapshot.scope, ids.insert(entry.id).inserted else {
                throw Invalid.snapshot
            }
        }
        let cutoff: TimeInterval?
        switch policy {
        case nil, .keepAll?: cutoff = nil
        case let .elapsed(seconds)?:
            guard (1...315576000).contains(seconds) else { throw Invalid.policy }
            cutoff = now - Double(seconds)
        case let .calendarDays(days, timeZoneID)?:
            guard (1...3650).contains(days), identity(timeZoneID),
                  TimeZone.knownTimeZoneIdentifiers.contains(timeZoneID) || timeZoneID == "UTC",
                  let zone = TimeZone(identifier: timeZoneID) else { throw Invalid.policy }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            // Subtract civil dates in a neutral calendar, then resolve that exact local date.
            // This avoids normalizing away an entire skipped civil date (e.g. Samoa 2011-12-30).
            var neutral = Calendar(identifier: .gregorian)
            neutral.timeZone = TimeZone(secondsFromGMT: 0)!
            let todayParts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: now))
            guard let neutralToday = neutral.date(from: todayParts),
                  let target = neutral.date(byAdding: .day, value: -days, to: neutralToday) else {
                throw Invalid.calendarBoundary
            }
            var expected = neutral.dateComponents([.year, .month, .day], from: target)
            expected.hour = 0; expected.minute = 0; expected.second = 0
            guard let boundary = calendar.date(from: expected) else { throw Invalid.calendarBoundary }
            let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: boundary)
            guard actual.year == expected.year, actual.month == expected.month, actual.day == expected.day,
                  actual.hour == 0, actual.minute == 0, actual.second == 0 else { throw Invalid.calendarBoundary }
            cutoff = boundary.timeIntervalSince1970
        }
        var candidates: [String] = []
        var decisions: [Decision] = []
        for entry in snapshot.entries.sorted(by: { $0.id < $1.id }) {
            let reason: Reason
            if entry.protected { reason = .protected }
            else if entry.open { reason = .open }
            else if entry.recoveryPending { reason = .recoveryPending }
            else if entry.recovered { reason = .recovered }
            else if let ended = entry.endedAt, validTime(ended) {
                if ended > snapshot.capturedAt { reason = .futureEnd }
                else if policy == nil { reason = .noSelection }
                else if policy == .keepAll { reason = .keepAll }
                else if let cutoff = cutoff, ended < cutoff {
                    reason = .olderThanCutoff; candidates.append(entry.id)
                } else { reason = .withinRetention }
            } else { reason = .invalidOrMissingEnd }
            decisions.append(Decision(id: entry.id, reason: reason))
        }
        return Plan(snapshot: snapshot, policy: policy, evaluatedAt: now, cutoff: cutoff,
                    candidates: candidates, decisions: decisions)
    }
    /// Exact regeneration is an equivalent stale-check contract, NOT execution authorization.
    /// Every changed timestamp, revision, metadata field, policy, order or evaluation time invalidates it.
    public static func validate(_ proposal: Plan, current: Snapshot, policy: Policy?, now: TimeInterval) -> Bool {
        guard let regenerated = try? plan(snapshot: current, policy: policy, now: now) else { return false }
        return proposal == regenerated
    }
}
