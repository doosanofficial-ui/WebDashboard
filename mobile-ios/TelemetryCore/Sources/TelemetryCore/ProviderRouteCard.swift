import Foundation

/// PREPARATION ONLY. Pure provider-neutral values; no provider, network, permission or location effects.
/// Identity and provenance labels bind data; they DO NOT authenticate a provider or confer permission.
/// A verified adapter must map provider observation time into this session's monotonic clock domain.
public struct ProviderRouteCard: Sendable {
    public struct Identity: Equatable, Sendable {
        public let scopeID: String
        public let providerID: String
        public let routeID: String
        public let destinationID: String
        public let generation: UInt64
        public init(scopeID: String, providerID: String, routeID: String, destinationID: String, generation: UInt64) {
            self.scopeID = scopeID; self.providerID = providerID; self.routeID = routeID; self.destinationID = destinationID; self.generation = generation
        }
    }
    public struct Values: Equatable, Sendable {
        // nil is unknown; zero is valid. Wall timestamps are Unix seconds, not local time strings.
        public let currentStreet: String?
        public let remainingMeters: Double?
        public let remainingSeconds: Double?
        public let providerObservedUnix: Double?
        public let estimatedArrivalUnix: Double?
        public init(currentStreet: String? = nil, remainingMeters: Double? = nil,
                    remainingSeconds: Double? = nil, providerObservedUnix: Double? = nil,
                    estimatedArrivalUnix: Double? = nil) {
            self.currentStreet = ProviderRouteCard.plainText(currentStreet, limit: 512)
            self.remainingMeters = ProviderRouteCard.number(remainingMeters, maximum: 50_000_000)
            self.remainingSeconds = ProviderRouteCard.number(remainingSeconds, maximum: 31_536_000)
            let observed = ProviderRouteCard.number(providerObservedUnix)
            let arrival = ProviderRouteCard.number(estimatedArrivalUnix)
            self.providerObservedUnix = observed
            if let observed, let arrival, arrival >= observed { self.estimatedArrivalUnix = arrival }
            else { self.estimatedArrivalUnix = nil }
        }
    }

    public enum Provenance: String, Sendable { case providerRouteEstimate }
    public struct Snapshot: Equatable, Sendable {
        public let identity: Identity
        public let sequence: Int
        public let observedMonotonic: Double
        public let receivedMonotonic: Double
        public let attribution: String
        public let values: Values
        public let provenance: Provenance = .providerRouteEstimate
        public var localizationKey: String { "route.estimate.not_guaranteed" }
    }
    private let maximumAge: Double
    private var active: Identity?
    private var snapshot: Snapshot?
    private var generation: UInt64 = 0
    private var clock: Double = 0
    private var sequence: Int = -1
    private var observed: Double = -1
    public init?(maximumAge: Double) {
        guard maximumAge.isFinite, maximumAge > 0, maximumAge <= 3600 else { return nil }
        self.maximumAge = maximumAge
    }
    // Call on cancellation, stop, failure, scope/provider change, backgrounding or lost authorization.
    public mutating func cancel() { active = nil; snapshot = nil }
    @discardableResult public mutating func activate(_ identity: Identity, now: Double) -> Bool {
        cancel()
        guard advance(now), identity.generation > generation,
              Self.validID(identity.scopeID), Self.validID(identity.providerID), Self.validID(identity.routeID), Self.validID(identity.destinationID) else { return false }
        active = identity; generation = identity.generation; sequence = -1; observed = -1
        return true
    }
    /// Full replacement, never a merge. Unknown fields therefore clear older fields.
    /// Serialize calls. The observation timestamp MUST represent provider observation, not receipt time.
    @discardableResult public mutating func accept(identity: Identity, sequence: Int,
        observedMonotonic: Double, now: Double, attribution: String, values: Values) -> Bool {
        guard advance(now), active == identity, active != nil,
              sequence >= 0, sequence > self.sequence,
              Self.number(observedMonotonic) != nil, observedMonotonic >= observed,
              observedMonotonic <= now, now - observedMonotonic < maximumAge,
              Self.plainText(attribution, limit: 2048) != nil else { return false }
        self.sequence = sequence; observed = observedMonotonic
        snapshot = Snapshot(identity: identity, sequence: sequence, observedMonotonic: observedMonotonic,
                            receivedMonotonic: now, attribution: attribution, values: values)
        return true
    }
    /// Must be called on every render and on a timer even if no updates arrive; expired fields are nil.
    public mutating func render(now: Double) -> Snapshot? {
        guard advance(now) else { return nil }
        return snapshot
    }
    private mutating func advance(_ now: Double) -> Bool {
        guard Self.number(now) != nil, now >= clock else { cancel(); return false }
        clock = now
        if let snapshot, now - snapshot.observedMonotonic >= maximumAge { self.snapshot = nil }
        return true
    }
    private static func validID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    fileprivate static func number(_ value: Double?, maximum: Double = 1_000_000_000_000) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= maximum else { return nil }
        return value
    }
    fileprivate static func plainText(_ value: String?, limit: Int) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= limit, !value.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
              }) else { return nil }
        return value // Render with Text(verbatim:), never HTML/Markdown, URL links or commands.
    }
}
