import Foundation

public enum ECUCapabilityCatalogueError: Error, Equatable, Sendable {
    case unknownQuery
    case contextMismatch
    case outOfOrderObservation
    case invalidObservationTime
    case invalidEvidence
    case invalidSchedulerSupport
    case duplicateQueryID(String)
    case unsupportedSnapshotVersion(Int)
    case definitionMismatch(String)
    case invalidSnapshot
}

public struct ECUCapabilityQueryID: Hashable, Sendable {
    public let queryID: String
    public let requestCANID: UInt32
    public let responseCANID: UInt32
    public let isExtended: Bool
    public let service: String
    public let command: String
    public let sourceRepository: String
    public let sourcePath: String
    public let sourceCommit: String

    public init(_ query: OBDQueryDefinition) {
        queryID = query.id
        requestCANID = query.requestCANID
        responseCANID = query.responseCANID
        isExtended = query.isExtended
        service = query.service.rawValue
        command = query.command
        sourceRepository = query.sourceRepository
        sourcePath = query.sourcePath
        sourceCommit = query.sourceCommit
    }
}

/// A read-only presentation of exact-query evidence; never schedules queries
/// or infers vehicle identity. The existing scheduler supplies live support.
public struct ECUCapabilityCatalogue: Equatable, Sendable {
    public enum Origin: String, Codable, Equatable, Sendable {
        case vehicleSession
        case syntheticFixture
    }

    public enum EvidenceBasis: String, Codable, Equatable, Sendable {
        case positiveResponse
        case schedulerSupport
    }

    public enum VehicleQueryEvidenceStatus: String, Equatable, Sendable {
        case candidate
        case supported
        case unsupported
    }

    public enum Availability: String, Equatable, Sendable {
        case unknown, responseReceived, noData, timedOut, disconnected, failed
    }

    public enum Freshness: String, Equatable, Sendable {
        case unknown, fresh, stale
    }

    public struct SupportEvidence: Codable, Equatable, Sendable {
        public let context: VehicleContext
        public let support: OBDQuerySupport
        public let basis: EvidenceBasis
        public let origin: Origin
        public let observedAtEpoch: Double
        public let observationSequence: UInt64

        public init(context: VehicleContext, support: OBDQuerySupport, basis: EvidenceBasis,
                    origin: Origin, observedAtEpoch: Double, observationSequence: UInt64) throws {
            guard observedAtEpoch.isFinite else { throw ECUCapabilityCatalogueError.invalidObservationTime }
            guard support != .unknown, basis != .positiveResponse || support == .supported else {
                throw ECUCapabilityCatalogueError.invalidEvidence
            }
            self.context = context
            self.support = support
            self.basis = basis
            self.origin = origin
            self.observedAtEpoch = observedAtEpoch
            self.observationSequence = observationSequence
        }

        fileprivate func sharesSlot(with other: Self) -> Bool {
            origin == other.origin && basis == other.basis && support == other.support
        }

        private enum CodingKeys: String, CodingKey {
            case context, support, basis, origin, observedAtEpoch, observationSequence
        }

        private enum StoredSupport: String, Codable {
            case unknown, supported, unsupported
            var value: OBDQuerySupport {
                switch self {
                case .unknown: return .unknown
                case .supported: return .supported
                case .unsupported: return .unsupported
                }
            }
            init(_ support: OBDQuerySupport) {
                switch support {
                case .unknown: self = .unknown
                case .supported: self = .supported
                case .unsupported: self = .unsupported
                }
            }
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(context: values.decode(VehicleContext.self, forKey: .context),
                support: values.decode(StoredSupport.self, forKey: .support).value,
                basis: values.decode(EvidenceBasis.self, forKey: .basis),
                origin: values.decode(Origin.self, forKey: .origin),
                observedAtEpoch: values.decode(Double.self, forKey: .observedAtEpoch),
                observationSequence: values.decode(UInt64.self, forKey: .observationSequence))
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(context, forKey: .context)
            try values.encode(StoredSupport(support), forKey: .support)
            try values.encode(basis, forKey: .basis)
            try values.encode(origin, forKey: .origin)
            try values.encode(observedAtEpoch, forKey: .observedAtEpoch)
            try values.encode(observationSequence, forKey: .observationSequence)
        }
    }

    /// A callback-time snapshot, not a continuously evaluated freshness clock.
    /// A parent may project freshness at its display time without new evidence.
    public struct CurrentState: Equatable, Sendable {
        public let schedulerSupport: OBDQuerySupport
        public let availability: Availability
        public let freshness: Freshness
        public let origin: Origin
        public let observedAtEpoch: Double
        public let observationSequence: UInt64

        public init(schedulerSupport: OBDQuerySupport, availability: Availability, freshness: Freshness,
                    origin: Origin, observedAtEpoch: Double, observationSequence: UInt64) throws {
            guard observedAtEpoch.isFinite else { throw ECUCapabilityCatalogueError.invalidObservationTime }
            self.schedulerSupport = schedulerSupport
            self.availability = availability
            self.freshness = freshness
            self.origin = origin
            self.observedAtEpoch = observedAtEpoch
            self.observationSequence = observationSequence
        }
    }

    public struct Entry: Equatable, Sendable {
        public let query: OBDQueryDefinition
        /// Latest observation per (origin, basis, support), at most six slots.
        /// Full request history belongs to the diagnostic audit, not this view.
        public fileprivate(set) var historicalEvidence: [SupportEvidence] = []
        public fileprivate(set) var currentState: CurrentState?
        public var currentSchedulerSupport: OBDQuerySupport { currentState?.schedulerSupport ?? .unknown }
        public var latestVehicleEvidence: SupportEvidence? {
            historicalEvidence.last { $0.origin == .vehicleSession }
        }
        /// Historical exact-query support only; never current admission or a
        /// vehicle/profile verification badge. Synthetic evidence stays separate.
        public var vehicleQueryEvidenceStatus: VehicleQueryEvidenceStatus {
            switch latestVehicleEvidence?.support {
            case .supported: return .supported
            case .unsupported: return .unsupported
            default: return .candidate
            }
        }
    }

    public let context: VehicleContext
    public private(set) var entries: [Entry]

    public struct Snapshot: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let context: VehicleContext
        public let entries: [StoredEntry]
    }

    public struct StoredEntry: Codable, Equatable, Sendable {
        public let query: OBDQueryDefinition
        public let historicalEvidence: [SupportEvidence]
    }

    public init(context: VehicleContext, queries: [OBDQueryDefinition]) throws {
        var ids = Set<String>()
        for query in queries where !ids.insert(query.id).inserted {
            throw ECUCapabilityCatalogueError.duplicateQueryID(query.id)
        }
        self.context = context
        entries = queries.map { Entry(query: $0) }
    }

    /// Excludes all current admission/availability/freshness state.
    public func snapshot() -> Snapshot {
        Snapshot(schemaVersion: 1, context: context, entries: entries.map {
            StoredEntry(query: $0.query, historicalEvidence: $0.historicalEvidence)
        })
    }

    public static func restoring(
        _ snapshot: Snapshot, in context: VehicleContext, queries: [OBDQueryDefinition]
    ) throws -> Self {
        guard snapshot.schemaVersion == 1 else {
            throw ECUCapabilityCatalogueError.unsupportedSnapshotVersion(snapshot.schemaVersion)
        }
        guard snapshot.context.sharesLocalProfile(with: context) else {
            throw ECUCapabilityCatalogueError.contextMismatch
        }
        var restored = try Self(context: context, queries: queries)
        var storedIDs = Set<String>()
        for stored in snapshot.entries {
            guard storedIDs.insert(stored.query.id).inserted else {
                throw ECUCapabilityCatalogueError.duplicateQueryID(stored.query.id)
            }
            guard stored.historicalEvidence.count <= 6 else { throw ECUCapabilityCatalogueError.invalidSnapshot }
            for (index, evidence) in stored.historicalEvidence.enumerated() {
                guard evidence.context.sharesLocalProfile(with: snapshot.context) else {
                    throw ECUCapabilityCatalogueError.contextMismatch
                }
                guard !stored.historicalEvidence.prefix(index).contains(where: { $0.sharesSlot(with: evidence) }) else {
                    throw ECUCapabilityCatalogueError.invalidSnapshot
                }
                if evidence.basis == .schedulerSupport {
                    try validateSchedulerSupport(evidence.support, for: stored.query)
                }
            }
            // Removed definitions stay out of the active catalogue. Newly
            // configured definitions start as candidates without inherited data.
            guard let index = restored.entries.firstIndex(where: { $0.query.id == stored.query.id }) else { continue }
            guard restored.entries[index].query == stored.query else {
                throw ECUCapabilityCatalogueError.definitionMismatch(stored.query.id)
            }
            restored.entries[index].historicalEvidence = stored.historicalEvidence
        }
        return restored
    }

    public mutating func recordEvidence(_ evidence: SupportEvidence, for queryID: ECUCapabilityQueryID) throws {
        guard evidence.context == context else { throw ECUCapabilityCatalogueError.contextMismatch }
        guard let index = entries.firstIndex(where: { ECUCapabilityQueryID($0.query) == queryID }) else {
            throw ECUCapabilityCatalogueError.unknownQuery
        }
        if evidence.basis == .schedulerSupport {
            try Self.validateSchedulerSupport(evidence.support, for: entries[index].query)
        }
        let history = entries[index].historicalEvidence
        if history.contains(evidence) { return }
        if let previous = history.last(where: { $0.context == context && $0.origin == evidence.origin }) {
            guard evidence.observationSequence >= previous.observationSequence else {
                throw ECUCapabilityCatalogueError.outOfOrderObservation
            }
            if evidence.observationSequence == previous.observationSequence {
                guard evidence.observedAtEpoch == previous.observedAtEpoch, evidence.support == previous.support else {
                    throw ECUCapabilityCatalogueError.outOfOrderObservation
                }
            }
        }
        entries[index].historicalEvidence.removeAll { $0.sharesSlot(with: evidence) }
        entries[index].historicalEvidence.append(evidence)
    }

    public mutating func updateCurrentState(
        _ state: CurrentState, for queryID: ECUCapabilityQueryID, in context: VehicleContext
    ) throws {
        guard context == self.context else { throw ECUCapabilityCatalogueError.contextMismatch }
        guard let index = entries.firstIndex(where: { ECUCapabilityQueryID($0.query) == queryID }) else {
            throw ECUCapabilityCatalogueError.unknownQuery
        }
        try Self.validateSchedulerSupport(state.schedulerSupport, for: entries[index].query)
        if let previous = entries[index].currentState {
            if previous == state { return }
            guard state.observationSequence > previous.observationSequence else {
                throw ECUCapabilityCatalogueError.outOfOrderObservation
            }
        }
        entries[index].currentState = state
    }

    /// Validate the existing scheduler's representable domain only. This does
    /// not inspect support-page bits, infer support or cache a second answer.
    private static func validateSchedulerSupport(_ support: OBDQuerySupport, for query: OBDQueryDefinition) throws {
        guard support != .unknown else { return }
        guard query.service == .mode01, let pid = UInt8(query.command, radix: 16), pid > 0 else {
            throw ECUCapabilityCatalogueError.invalidSchedulerSupport
        }
    }
}
