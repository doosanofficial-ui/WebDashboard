import Foundation

/// Pure contract proposal. A separately verified provider supplies evidence.
/// No location, network, speech, persistence or automatic reroute implementation.
public struct NavigationLifecycle {
    public struct Policy {
        public let maximumProgressAge: Double
        public let rerouteCooldown: Double
        public let resumeTTL: Double
        public init?(maximumProgressAge: Double, rerouteCooldown: Double, resumeTTL: Double) {
            guard [maximumProgressAge, rerouteCooldown, resumeTTL].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            self.maximumProgressAge = maximumProgressAge
            self.rerouteCooldown = rerouteCooldown
            self.resumeTTL = resumeTTL
        }
    }
    public struct Route: Equatable {
        public let token: UInt64
        public let routeID: String
        public let destinationID: String
    }
    public enum Quality { case verified, unknown, stale }
    public enum Event {
        case request(destinationID: String)
        case accepted(token: UInt64, routeID: String)
        case start(token: UInt64)
        case failed(token: UInt64)
        case cancel(token: UInt64)
        case stop
        case suspend
        case resume(confirmed: Bool)
        case progress(token: UInt64, routeID: String, sequence: Int, observedAt: Double,
                      quality: Quality, arrival: Bool, offRoute: Bool?)
    }
    public enum Effect: Equatable {
        case requestRoute(token: UInt64, destinationID: String)
        case guidanceStarted, guidanceStopped, guidanceSuspended
        case failed, cancel, arrived, suggestReroute, resumeExpired
    }
    public private(set) var generation: UInt64 = 0
    public private(set) var active: Route?
    public private(set) var candidate: Route?
    public private(set) var pending: (token: UInt64, destinationID: String)?
    private var suspended: (destinationID: String, at: Double)?
    private var clock: Double = 0
    private var sequence = -1
    private var observed: Double = -1
    private var lastSuggestion: Double?
    private var latched = false
    private let policy: Policy
    public init(policy: Policy) { self.policy = policy }
    private static func validID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count) && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    /// `now` and observed timestamps share one nonnegative monotonic clock domain.
    /// Serialize delivery. Never restore this object across clock resets.
    public mutating func send(_ event: Event, now: Double) -> [Effect] {
        guard now.isFinite, now >= clock else { return [] }
        clock = now
        switch event {
        case .request(let destination):
            guard Self.validID(destination), generation < UInt64.max else { return [] }
            generation += 1
            pending = (generation, destination); candidate = nil; suspended = nil
            return [.requestRoute(token: generation, destinationID: destination)]
        case .accepted(let token, let routeID):
            if let pending, token == pending.token, candidate == nil, Self.validID(routeID) {
                candidate = Route(token: token, routeID: routeID, destinationID: pending.destinationID)
            }
        case .start(let token):
            if let candidate, token == candidate.token {
                active = candidate; self.candidate = nil; pending = nil
                sequence = -1; observed = -1; lastSuggestion = nil; latched = false
                return [.guidanceStarted]
            }
        case .failed(let token):
            if pending?.token == token { pending = nil; candidate = nil; return [.failed] }
        case .cancel(let token):
            if pending?.token == token { pending = nil; candidate = nil; return [.cancel] }
        case .stop:
            active = nil; pending = nil; candidate = nil; suspended = nil
            return [.guidanceStopped]
        case .suspend:
            if let active {
                suspended = (active.destinationID, now)
                self.active = nil; pending = nil; candidate = nil
                return [.guidanceSuspended]
            }
        case .resume(let confirmed):
            if let suspended, confirmed {
                if now - suspended.at > policy.resumeTTL {
                    self.suspended = nil; return [.resumeExpired]
                }
                return send(.request(destinationID: suspended.destinationID), now: now)
            }
        case .progress(let token, let routeID, let nextSequence, let at, let quality, let arrival, let offRoute):
            guard let active, active.token == token, active.routeID == routeID,
                  quality == .verified, nextSequence >= 0, nextSequence > sequence,
                  at.isFinite, at >= 0, at >= observed, at <= now, now - at <= policy.maximumProgressAge else { return [] }
            sequence = nextSequence; observed = at
            if arrival {
                self.active = nil; pending = nil; candidate = nil; suspended = nil
                return [.arrived]
            }
            if offRoute == false { latched = false }
            if offRoute == true, !latched,
               lastSuggestion.map({ now - $0 >= policy.rerouteCooldown }) ?? true {
                latched = true; lastSuggestion = now
                return [.suggestReroute]
            }
        }
        return []
    }
}
