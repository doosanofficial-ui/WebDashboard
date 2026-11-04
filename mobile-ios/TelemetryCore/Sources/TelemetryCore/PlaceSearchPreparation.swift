import Foundation

/// Pure, serially driven proposal. No provider, URL, location, persistence or routing effects.
public struct PlaceSearchPreparation {
    public struct Token: Equatable {
        public let generation: Int64
        public let provider: String
        public init(generation: Int64, provider: String) { self.generation = generation; self.provider = provider }
    }
    public struct Suggestion: Equatable {
        public let id: String
        public let label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }
    /// Evidence of selection only. This is NOT a coordinate, verified destination or route request.
    public struct Selection: Equatable {
        public let token: Token
        public let resultID: String
    }
    public static let maximum: Int64 = 9_007_199_254_740_991
    public private(set) var generation: Int64 = 0
    public private(set) var results: [Suggestion] = []
    public private(set) var query: String?
    private var enabled = false
    private var authorized = false
    private var provider: String?
    private var edited: Int64?
    private var lastTime: Int64?
    private var lastRequest: Int64?
    private var pending: Token?
    private var accepted: Token?
    public init() {}
    private static func opaque(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...64).contains(bytes.count) && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }
    private static func bounded(_ value: String, scalars: Int, bytes: Int) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.unicodeScalars.count <= scalars, value.utf8.count <= bytes else { return false }
        return !value.unicodeScalars.contains { scalar in
            let n = scalar.value
            return n < 32 || (127...159).contains(n) || (0xD800...0xDFFF).contains(n)
                || (0x2028...0x202E).contains(n) || (0x2066...0x2069).contains(n)
        }
    }
    private mutating func invalidate() {
        query = nil; edited = nil; pending = nil; accepted = nil; results = []
        if generation < Self.maximum { generation += 1 }
    }
    /// Values supplied only by a trusted coordinator after separate privacy/provider authorization.
    /// Reconfiguration always invalidates old work and requires another explicit user edit.
    public mutating func configure(enabled: Bool, provider: String, authorized: Bool) {
        invalidate()
        self.enabled = enabled; self.authorized = authorized
        self.provider = Self.opaque(provider) ? provider : nil
    }
    private mutating func clock(_ now: Int64) -> Bool {
        guard now >= 0, now <= Self.maximum, lastTime.map({ now >= $0 }) ?? true else { return false }
        lastTime = now; return true
    }
    @discardableResult public mutating func edit(_ query: String, at now: Int64, userInitiated: Bool) -> Bool {
        guard userInitiated, clock(now) else { return false }
        let exhausted = generation >= Self.maximum
        invalidate()
        guard !exhausted, Self.bounded(query, scalars: 128, bytes: 512) else { return false }
        self.query = query; edited = now; return true
    }
    /// Returns a candidate token only. A host may snapshot `query` in the same serial transaction.
    /// Recheck current consent/provider before transmission. A token is not authorization.
    public mutating func poll(at now: Int64) -> Token? {
        guard clock(now), enabled, authorized, let provider = provider,
              query != nil, let edited = edited, pending == nil, accepted == nil else { return nil }
        guard now - edited >= 300 else { return nil }
        if let lastRequest = lastRequest, now - lastRequest < 1000 { return nil }
        let token = Token(generation: generation, provider: provider)
        pending = token; lastRequest = now; self.edited = nil
        return token
    }
    @discardableResult public mutating func receive(_ token: Token, rows: [Suggestion]) -> Bool {
        guard let pending = pending, pending == token, rows.count <= 10 else { return false }
        guard rows.allSatisfy({ Self.opaque($0.id) && Self.bounded($0.label, scalars: 256, bytes: 1024) }),
              Set(rows.map { $0.id }).count == rows.count else { return false }
        results = rows; accepted = token; self.pending = nil; return true
    }
    public func select(_ token: Token, resultID: String) -> Selection? {
        guard let accepted = accepted, accepted == token, results.contains(where: { $0.id == resultID }) else { return nil }
        return Selection(token: token, resultID: resultID)
    }
    public mutating func cancel() { invalidate() }
    @discardableResult public mutating func fail(_ token: Token) -> Bool {
        guard let pending = pending, pending == token else { return false }
        self.pending = nil; return true
    }
}
