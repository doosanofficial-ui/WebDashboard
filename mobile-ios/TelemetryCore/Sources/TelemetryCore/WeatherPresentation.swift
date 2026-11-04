// Additive preparation only; not integrated or Swift-compiled.
// All effects are declarations. This module performs no networking or persistence.
public struct WeatherConditions: Equatable, Sendable {
    // Canonical, explicit units. nil means unavailable; zero remains a real value.
    public let temperatureCelsius: Double?
    public let pressureHectopascals: Double?
    public let relativeHumidityFraction: Double?
    public let windMetersPerSecond: Double?
    public init(temperatureCelsius: Double? = nil, pressureHectopascals: Double? = nil,
                relativeHumidityFraction: Double? = nil, windMetersPerSecond: Double? = nil) {
        self.temperatureCelsius = temperatureCelsius
        self.pressureHectopascals = pressureHectopascals
        self.relativeHumidityFraction = relativeHumidityFraction
        self.windMetersPerSecond = windMetersPerSecond
    }
    fileprivate var isValid: Bool {
        [(temperatureCelsius, -100.0, 70.0), (pressureHectopascals, 100.0, 1200.0),
         (relativeHumidityFraction, 0.0, 1.0), (windMetersPerSecond, 0.0, 150.0)].allSatisfy { item in
            guard let value = item.0 else { return true }
            return value.isFinite && value >= item.1 && value <= item.2
        }
    }
}

public struct WeatherMetadata: Equatable, Sendable {
    // Always a provider current-condition source; never OBD MAP or a sensor fallback.
    public enum Source: String, Sendable { case providerCurrentConditions }
    public let source: Source = .providerCurrentConditions
    public let providerID: String
    // Provider adapter must supply full required text and render any required marks/links.
    // This bounded text is not proof that all provider attribution requirements are met.
    public let attribution: String
    public init(providerID: String, attribution: String) {
        self.providerID = providerID; self.attribution = attribution
    }
    fileprivate var isValid: Bool {
        !providerID.allSatisfy(\.isWhitespace) && providerID.utf8.count <= 128 &&
        !attribution.allSatisfy(\.isWhitespace) && attribution.utf8.count <= 2048
    }
}

public struct WeatherRequest: Equatable, Sendable {
    // Opaque, session-local identifier. Never pass coordinates or an address as this key.
    public let locationKey: String
    public let generation: UInt64
    fileprivate init(locationKey: String, generation: UInt64) {
        self.locationKey = locationKey; self.generation = generation
    }
}

public struct WeatherSnapshot: Equatable, Sendable {
    public let conditions: WeatherConditions
    public let metadata: WeatherMetadata
    public let providerObservedUnix: Double?
    public let retrievedUnix: Double?
    public let retrievedMonotonic: Double
    public let observedAgeAtRetrieval: Double?
}

public struct WeatherPresentationState: Sendable {
    public enum Status: Equatable, Sendable { case idle, loading, accepted, cancelled, failed }
    public enum Presentation: Equatable, Sendable { case unavailable, fresh, stale, offline, failed }
    // Conservative illustrative bounds, not a provider cache license or refresh schedule.
    public static let freshSeconds: Double = 600
    public static let retentionSeconds: Double = 1800
    public private(set) var locationKey: String?
    public private(set) var pending: WeatherRequest?
    public private(set) var snapshot: WeatherSnapshot?
    public private(set) var status: Status = .idle
    private var generation: UInt64 = 0
    private var highwater: Double = 0
    public init() {}

    @discardableResult public mutating func select(locationKey: String) -> Bool {
        pending = nil; snapshot = nil; status = .idle
        self.locationKey = !locationKey.allSatisfy(\.isWhitespace) && locationKey.utf8.count <= 128 ? locationKey : nil
        return self.locationKey != nil
    }
    // Must be serialized by the eventual owner (e.g. MainActor). No tasks spawned here.
    public mutating func request(now: Double) -> WeatherRequest? {
        guard advance(now), let key = locationKey, generation < UInt64.max else { return nil }
        generation += 1
        let effect = WeatherRequest(locationKey: key, generation: generation)
        pending = effect; status = .loading
        return effect
    }
    public mutating func cancel() { pending = nil; status = .cancelled }
    @discardableResult public mutating func fail(_ request: WeatherRequest, now: Double) -> Bool {
        guard advance(now), request == pending else { return false }
        pending = nil; status = .failed
        return true
    }
    @discardableResult public mutating func accept(_ request: WeatherRequest,
        conditions: WeatherConditions, metadata: WeatherMetadata,
        providerObservedUnix: Double?, retrievedUnix: Double?, now: Double) -> Bool {
        guard advance(now), request == pending, request.locationKey == locationKey else { return false }
        pending = nil
        guard conditions.isValid, metadata.isValid else { status = .failed; return false }
        let observed = Self.validTime(providerObservedUnix)
        let retrieved = Self.validTime(retrievedUnix)
        let age: Double?
        if let observed, let retrieved, observed <= retrieved { age = retrieved - observed } else { age = nil }
        snapshot = WeatherSnapshot(conditions: conditions, metadata: metadata,
            providerObservedUnix: observed, retrievedUnix: retrieved,
            retrievedMonotonic: now, observedAgeAtRetrieval: age)
        status = .accepted
        return true
    }
    // Call on every render/lifecycle transition. Expired bytes are discarded lazily here.
    public mutating func presentation(now: Double, offline: Bool = false) -> Presentation {
        guard advance(now), let snapshot else { return .unavailable }
        if offline { return .offline }
        if status == .failed { return .failed }
        let elapsed = now - snapshot.retrievedMonotonic
        guard let age = snapshot.observedAgeAtRetrieval,
              elapsed < Self.freshSeconds, age + elapsed < Self.freshSeconds else { return .stale }
        return .fresh
    }
    // Integrator must clear on scene teardown or when provider terms require earlier eviction.
    public mutating func clear() {
        locationKey = nil; pending = nil; snapshot = nil; status = .idle
        // Do not reset generation: replies from before clear must never regain eligibility.
    }
    private static func validTime(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
    private mutating func advance(_ now: Double) -> Bool {
        guard now.isFinite, now >= highwater else {
            pending = nil; snapshot = nil; status = .failed
            return false
        }
        highwater = now
        if let snapshot, now - snapshot.retrievedMonotonic >= Self.retentionSeconds { self.snapshot = nil }
        return true
    }
}
