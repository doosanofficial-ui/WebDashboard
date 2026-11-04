import Foundation

// Standalone preparation; not integrated with application targets or delivery services.
public enum SupportReportError: Error { case invalidSchema, invalidVersion, invalidCounters, invalidLatency }
public enum SupportPlatform: String, Codable, Sendable { case iOS, macOS }
public enum SupportTransport: String, Codable, Sendable { case none, ble, wifi, simulated }
public enum SupportConnectionState: String, Codable, Sendable {
    case disconnected, connecting, connected, disconnecting, failed
}
private struct SupportKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func requireSupportKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let container = try decoder.container(keyedBy: SupportKey.self)
    guard Set(container.allKeys.map(\.stringValue)) == expected else { throw SupportReportError.invalidSchema }
}

public struct SupportCounters: Codable, Equatable, Sendable {
    public let requests: Int64
    public let succeeded: Int64
    public let failed: Int64
    public let cancelled: Int64
    public let pending: Int64
    private enum CodingKeys: String, CodingKey { case requests, succeeded, failed, cancelled, pending }
    public init(requests: Int64, succeeded: Int64, failed: Int64, cancelled: Int64, pending: Int64) throws {
        let values = [requests, succeeded, failed, cancelled, pending]
        guard values.allSatisfy({ (0...1_000_000_000).contains($0) }),
              requests == succeeded + failed + cancelled + pending else { throw SupportReportError.invalidCounters }
        self.requests = requests; self.succeeded = succeeded; self.failed = failed
        self.cancelled = cancelled; self.pending = pending
    }
    public init(from decoder: Decoder) throws {
        try requireSupportKeys(decoder, ["requests", "succeeded", "failed", "cancelled", "pending"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(requests: c.decode(Int64.self, forKey: .requests),
                      succeeded: c.decode(Int64.self, forKey: .succeeded),
                      failed: c.decode(Int64.self, forKey: .failed),
                      cancelled: c.decode(Int64.self, forKey: .cancelled),
                      pending: c.decode(Int64.self, forKey: .pending))
    }
}
public struct SupportLatency: Codable, Equatable, Sendable {
    public let samples: Int64
    public let minimumMs: Double
    public let meanMs: Double
    public let maximumMs: Double
    private enum CodingKeys: String, CodingKey { case samples, minimumMs, meanMs, maximumMs }
    public init(samples: Int64, minimumMs: Double, meanMs: Double, maximumMs: Double) throws {
        guard (1...1_000_000_000).contains(samples),
              [minimumMs, meanMs, maximumMs].allSatisfy({ $0.isFinite && (0...86_400_000).contains($0) }),
              minimumMs <= meanMs, meanMs <= maximumMs,
              samples != 1 || minimumMs == maximumMs else { throw SupportReportError.invalidLatency }
        self.samples = samples; self.minimumMs = minimumMs; self.meanMs = meanMs; self.maximumMs = maximumMs
    }
    public init(from decoder: Decoder) throws {
        try requireSupportKeys(decoder, ["samples", "minimumMs", "meanMs", "maximumMs"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(samples: c.decode(Int64.self, forKey: .samples),
                      minimumMs: c.decode(Double.self, forKey: .minimumMs),
                      meanMs: c.decode(Double.self, forKey: .meanMs),
                      maximumMs: c.decode(Double.self, forKey: .maximumMs))
    }
}

/// Exact schema, local generation only. No dates, identifiers, logs, arbitrary strings or transport APIs.
public struct LocalSupportReport: Codable, Equatable, Sendable {
    public let appVersion: [Int]
    public let osVersion: [Int]
    public let platform: SupportPlatform
    public let transport: SupportTransport
    public let state: SupportConnectionState
    public let counters: SupportCounters?
    public let latency: SupportLatency?
    public var schemaVersion: Int { 1 }
    public var scope: String { "localAggregateOnly" }
    public var disclosure: String { "versionsConnectionStateAndCountersOnly" }
    public var allowsRemoteDelivery: Bool { false }
    private enum CodingKeys: String, CodingKey {
        case appVersion, osVersion, platform, transport, state, counters, latency
        case schemaVersion, scope, disclosure, allowsRemoteDelivery
    }
    public init(appVersion: [Int], osVersion: [Int], platform: SupportPlatform,
                transport: SupportTransport, state: SupportConnectionState,
                counters: SupportCounters?, latency: SupportLatency?) throws {
        guard [appVersion, osVersion].allSatisfy({ (2...3).contains($0.count) && $0.allSatisfy({ (0...65535).contains($0) }) })
        else { throw SupportReportError.invalidVersion }
        if let latency {
            guard let counters, latency.samples <= counters.requests - counters.pending else { throw SupportReportError.invalidLatency }
        }
        self.appVersion = appVersion; self.osVersion = osVersion; self.platform = platform
        self.transport = transport; self.state = state; self.counters = counters; self.latency = latency
    }
    public init(from decoder: Decoder) throws {
        try requireSupportKeys(decoder, ["appVersion", "osVersion", "platform", "transport", "state", "counters", "latency",
                                        "schemaVersion", "scope", "disclosure", "allowsRemoteDelivery"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1,
              try c.decode(String.self, forKey: .scope) == "localAggregateOnly",
              try c.decode(String.self, forKey: .disclosure) == "versionsConnectionStateAndCountersOnly",
              try c.decode(Bool.self, forKey: .allowsRemoteDelivery) == false else { throw SupportReportError.invalidSchema }
        try self.init(appVersion: c.decode([Int].self, forKey: .appVersion),
                      osVersion: c.decode([Int].self, forKey: .osVersion),
                      platform: c.decode(SupportPlatform.self, forKey: .platform),
                      transport: c.decode(SupportTransport.self, forKey: .transport),
                      state: c.decode(SupportConnectionState.self, forKey: .state),
                      counters: c.decodeIfPresent(SupportCounters.self, forKey: .counters),
                      latency: c.decodeIfPresent(SupportLatency.self, forKey: .latency))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appVersion, forKey: .appVersion); try c.encode(osVersion, forKey: .osVersion)
        try c.encode(platform, forKey: .platform); try c.encode(transport, forKey: .transport); try c.encode(state, forKey: .state)
        // encode Optional directly so unavailable is explicitly null, never silently zero or absent.
        try c.encode(counters, forKey: .counters); try c.encode(latency, forKey: .latency)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(scope, forKey: .scope)
        try c.encode(disclosure, forKey: .disclosure); try c.encode(allowsRemoteDelivery, forKey: .allowsRemoteDelivery)
    }
    /// Deterministic key order for the same runtime. Not a cross-language canonical signing format.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
