import Foundation

/// Pure proposal only. No native connection, permission, storage, or retry effects.
/// All evidence and restored ledger values require the trusted adapter gates in README.
public struct LaunchConnectionPolicy: Sendable {
    public struct Evidence: Equatable, Sendable {
        public let profile: String
        public let fingerprint: String
        public let launch: String
        public let session: String
        public let generation: UInt64
        public let foreground: Bool
        public let permissions: Bool
        public let observed: Bool
        public let idle: Bool
        public let captured: TimeInterval
        public init(profile: String, fingerprint: String, launch: String, session: String,
                    generation: UInt64, foreground: Bool, permissions: Bool,
                    observed: Bool, idle: Bool, captured: TimeInterval) {
            self.profile = profile; self.fingerprint = fingerprint
            self.launch = launch; self.session = session; self.generation = generation
            self.foreground = foreground; self.permissions = permissions
            self.observed = observed; self.idle = idle; self.captured = captured
        }
    }
    public struct Grant: Sendable {
        public let profile: String
        public let fingerprint: String
        public let generation: UInt64
        public let enabled: Bool
        public let futureLaunches: Bool
        public let maxAttempts: Int
        public init(profile: String, fingerprint: String, generation: UInt64, enabled: Bool = false,
                    futureLaunches: Bool = false, maxAttempts: Int = 1) {
            self.profile = profile; self.fingerprint = fingerprint
            self.generation = generation; self.enabled = enabled
            self.futureLaunches = futureLaunches; self.maxAttempts = maxAttempts
        }
    }
    public struct Intent: Equatable, Sendable {
        public let instance: String
        public let evidence: Evidence
    }
    public enum State: String, Sendable {
        case unknown, ready, pending, uncertain, suppressed, complete, refused, reconciled
    }
    public enum Acknowledgment: Sendable { case accepted, refused, uncertain }
    public private(set) var state: State
    public private(set) var pending: Intent?
    public private(set) var usedLaunches: Set<String>
    private let instance: String
    private let grant: Grant
    public init(instance: String, grant: Grant, restoredLedger: State = .unknown,
                restoredUsedLaunches: Set<String> = []) {
        self.instance = instance; self.grant = grant; self.state = restoredLedger
        self.usedLaunches = restoredUsedLaunches
    }
    private func valid(_ e: Evidence, now: TimeInterval) -> Bool {
        !instance.isEmpty && grant.enabled && !grant.profile.isEmpty && !grant.fingerprint.isEmpty
        && (!grant.futureLaunches || (1...32).contains(grant.maxAttempts))
        && grant.generation > 0 && e.profile == grant.profile && e.fingerprint == grant.fingerprint
        && e.generation == grant.generation && !e.launch.isEmpty && !e.session.isEmpty
        && e.foreground && e.permissions && e.observed && e.idle
        && now.isFinite && e.captured.isFinite && e.captured >= 0
        && now - e.captured >= 0 && now - e.captured <= 2
    }
    public mutating func propose(_ evidence: Evidence, now: TimeInterval) -> Intent? {
        guard state == .ready else { return nil }
        guard valid(evidence, now: now) else { state = .suppressed; return nil }
        guard !usedLaunches.contains(evidence.launch),
              usedLaunches.count < (grant.futureLaunches ? grant.maxAttempts : 1) else { return nil }
        let intent = Intent(instance: instance, evidence: evidence)
        usedLaunches.insert(evidence.launch)
        pending = intent; state = .pending
        return intent
    }
    public func canExecute(_ intent: Intent, evidence: Evidence, now: TimeInterval,
                           reservationCommitted: Bool) -> Bool {
        reservationCommitted && state == .pending && pending != nil && intent == pending
        && evidence == pending?.evidence && valid(evidence, now: now)
    }
    @discardableResult
    public mutating func acknowledge(_ intent: Intent, outcome: Acknowledgment) -> Bool {
        guard state == .pending, pending != nil, intent == pending else { return false }
        switch outcome {
        case .accepted: state = .complete
        case .refused: state = .refused
        case .uncertain: state = .uncertain
        }
        return true
    }
    /// Also use for opt-out, permission revocation, profile change or lifecycle invalidation.
    /// Pending effects must be fenced/reconciled by the native executor, not assumed cancelled.
    public mutating func suppress() {
        state = (state == .pending || state == .uncertain) ? .uncertain : .suppressed
    }
    @discardableResult
    public mutating func reconcile(_ intent: Intent, olderWorkFenced: Bool) -> Bool {
        guard olderWorkFenced, state == .uncertain, pending != nil, intent == pending else { return false }
        state = .reconciled
        return true
    }
    /// Only trusted canonical executor proof of terminal closure permits a later launch.
    /// Acceptance alone is insufficient. Uncertainty/refusal/suppression cannot use this path.
    @discardableResult
    public mutating func close(_ intent: Intent, authoritativeClosed: Bool) -> Bool {
        guard authoritativeClosed, state == .complete, pending != nil, intent == pending else { return false }
        pending = nil
        state = grant.futureLaunches && usedLaunches.count < grant.maxAttempts ? .ready : .complete
        return true
    }

}
