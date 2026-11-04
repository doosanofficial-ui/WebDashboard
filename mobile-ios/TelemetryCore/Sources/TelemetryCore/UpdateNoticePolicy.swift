import Foundation

/// Pure notification policy. Does not authenticate metadata, check the network,
/// prove signing/entitlements, persist preferences, open destinations or install apps.
public enum UpdateNoticePolicy {
    public static let automaticChecksAllowed = false
    public static let automaticInstallationAllowed = false

    public enum Channel: String, Equatable, Sendable { case appStore, testFlight }
    public enum Motion: Equatable, Sendable { case parked, driving, unknown }

    public struct Identity: Equatable, Sendable {
        public let app: String
        public let bundle: String
        public let channel: Channel
        public let store: String
        public init(app: String, bundle: String, channel: Channel, store: String) {
            self.app = app; self.bundle = bundle; self.channel = channel; self.store = store
        }
        public var isValid: Bool {
            [app, bundle, store].allSatisfy { value in
                // Bounded ASCII identity tokens only; no URL parsing or normalization.
                let bytes = value.utf8
                return (1...128).contains(bytes.count) && bytes.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) ||
                    (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
                }
            }
        }
    }

    /// Application contract releaseTripleV1, NOT a general SemVer/build-number parser.
    /// Exactly three canonical ASCII decimal components in 0...999999.
    public struct ReleaseVersion: Equatable, Comparable, Sendable {
        public let major: UInt32
        public let minor: UInt32
        public let patch: UInt32
        public init?(_ raw: String) {
            guard (5...20).contains(raw.utf8.count) else { return nil }
            let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            var values: [UInt32] = []
            for part in parts {
                guard (1...6).contains(part.utf8.count),
                      part.utf8.allSatisfy({ (48...57).contains($0) }),
                      part.count == 1 || part.first != "0",
                      let value = UInt32(part), value <= 999999 else { return nil }
                values.append(value)
            }
            major = values[0]; minor = values[1]; patch = values[2]
        }
        public static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }

    /// Opaque reference from a separately verified app/provider destination registry.
    /// Construction is NOT proof of trust. Never deserialize arbitrary remote data into
    /// this type and assume verification. Registry lookup/revalidation stays outside Core.
    public struct VerifiedDestinationReference: Equatable, Sendable {
        public let opaqueID: UUID
        public let identity: Identity
        public let version: String
        public init(opaqueID: UUID, identity: Identity, version: String) {
            self.opaqueID = opaqueID; self.identity = identity; self.version = version
        }
    }
    public struct Metadata: Equatable, Sendable {
        public let identity: Identity
        public let schema: String
        public let version: String
        public let generation: UInt64
        public let issuedAt: UInt64
        public let expiresAt: UInt64
        public let destination: VerifiedDestinationReference
        public init(identity: Identity, schema: String, version: String, generation: UInt64,
                    issuedAt: UInt64, expiresAt: UInt64, destination: VerifiedDestinationReference) {
            self.identity = identity; self.schema = schema; self.version = version
            self.generation = generation; self.issuedAt = issuedAt; self.expiresAt = expiresAt
            self.destination = destination
        }
    }
    public struct Request: Equatable, Sendable {
        public let generation: UInt64
        public let userInitiated: Bool
        public let cancelled: Bool
        public init(generation: UInt64, userInitiated: Bool = false, cancelled: Bool = false) {
            self.generation = generation; self.userInitiated = userInitiated; self.cancelled = cancelled
        }
    }
    public struct SkippedRelease: Equatable, Sendable {
        public let identity: Identity
        public let version: ReleaseVersion
        public init?(identity: Identity, version: String) {
            guard identity.isValid, let parsed = ReleaseVersion(version) else { return nil }
            self.identity = identity; self.version = parsed
        }
    }
    public struct Preferences: Equatable, Sendable {
        public var noticesEnabled: Bool
        public private(set) var skippedRelease: SkippedRelease?
        public init(noticesEnabled: Bool = false) {
            self.noticesEnabled = noticesEnabled; self.skippedRelease = nil
        }
        /// Explicit caller action; invalid input preserves the existing preference.
        @discardableResult public mutating func skip(identity: Identity, version: String) -> Bool {
            guard let value = SkippedRelease(identity: identity, version: version) else { return false }
            skippedRelease = value
            return true
        }
        public mutating func resetSkippedVersion() { skippedRelease = nil }
    }
    public enum Result: Equatable, Sendable {
        case rejected, noUpdate, suppressed, deferred
        case available(version: ReleaseVersion, destination: VerifiedDestinationReference)
    }

    /// All times are caller-supplied trusted seconds on the SAME clock basis. A rollback,
    /// identity change, cancellation or newer request requires a new generation and reevaluation.
    /// Reevaluate immediately before presentation/action; no result is a durable authorization.
    public static func evaluate(installedIdentity: Identity, installedVersion: String,
                                metadata: Metadata, request: Request, now: UInt64,
                                motion: Motion, preferences: Preferences) -> Result {
        guard !request.cancelled, request.userInitiated, request.generation > 0,
              request.generation == metadata.generation,
              metadata.schema == "releaseTripleV1", installedIdentity.isValid,
              metadata.identity == installedIdentity,
              metadata.destination.identity == installedIdentity,
              metadata.destination.version == metadata.version,
              let installed = ReleaseVersion(installedVersion),
              let offered = ReleaseVersion(metadata.version) else { return .rejected }
        guard metadata.issuedAt <= now, now < metadata.expiresAt,
              metadata.expiresAt - metadata.issuedAt <= 86400 else { return .rejected }
        guard offered > installed else { return .noUpdate }
        if !preferences.noticesEnabled { return .suppressed }
        if let skipped = preferences.skippedRelease,
           skipped.identity == installedIdentity, skipped.version == offered { return .suppressed }
        guard motion == .parked else { return .deferred }
        return .available(version: offered, destination: metadata.destination)
    }
}
