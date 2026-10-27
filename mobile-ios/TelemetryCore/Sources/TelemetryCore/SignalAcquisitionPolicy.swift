import Foundation

public enum SignalAcquisitionPolicyError: Error, Equatable, Sendable {
    case invalidContextID
    case invalidProfileRevision
    case contextMismatch
    case profileMismatch
    case profileRevisionMismatch
    case unknownQueryID(String)
    case queryDefinitionChanged(String)
    case timingOverridesNotAllowed
    case unsupportedSchemaVersion(Int)
    case invalidPolicy
}

/// An explicit selection of existing read-only queries, bound to a local
/// context and an application-supplied profile revision. No vehicle identity
/// is inferred from an adapter endpoint. A nil policy retains the legacy
/// behavior of acquiring all currently configured diagnostic queries.
public struct SignalAcquisitionPolicy: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let localContextID: String
    public let profileID: String
    public let profileRevision: String
    // Snapshots validate restored intent; only definitions from the current
    // profile are ever returned by resolve. They are not executable overrides.
    private let selectedQueries: [OBDQueryDefinition]

    public var selectedQueryIDs: [String] { selectedQueries.map(\.id) }

    public init(queryIDs: [String], profile: AdapterProfile, localContextID: String,
                profileRevision: String, timingOverrides: [String: Double] = [:]) throws {
        try Self.validateBinding(localContextID: localContextID, profileRevision: profileRevision)
        guard timingOverrides.isEmpty else { throw SignalAcquisitionPolicyError.timingOverridesNotAllowed }
        let configuredIDs = Set(profile.diagnosticQueries.map(\.id))
        for id in queryIDs where !configuredIDs.contains(id) {
            throw SignalAcquisitionPolicyError.unknownQueryID(id)
        }
        let selectedIDs = Set(queryIDs)
        schemaVersion = 1
        self.localContextID = localContextID
        profileID = profile.id
        self.profileRevision = profileRevision
        selectedQueries = profile.diagnosticQueries.filter { selectedIDs.contains($0.id) }
    }

    /// Preserves the profile's configured order, definitions, delay and timeout.
    /// Selection has no dashboard, recording, support-discovery or I/O inputs.
    /// Explicit empty returns []; the caller must not start an empty scheduler.
    public static func resolve(_ policy: Self?, profile: AdapterProfile, localContextID: String,
                               profileRevision: String) throws -> [OBDQueryDefinition] {
        try validateBinding(localContextID: localContextID, profileRevision: profileRevision)
        guard let policy else { return profile.diagnosticQueries }
        guard policy.localContextID == localContextID else { throw SignalAcquisitionPolicyError.contextMismatch }
        guard policy.profileID == profile.id else { throw SignalAcquisitionPolicyError.profileMismatch }
        guard policy.profileRevision == profileRevision else {
            throw SignalAcquisitionPolicyError.profileRevisionMismatch
        }
        let current = Dictionary(uniqueKeysWithValues: profile.diagnosticQueries.map { ($0.id, $0) })
        for snapshot in policy.selectedQueries {
            guard let definition = current[snapshot.id] else {
                throw SignalAcquisitionPolicyError.unknownQueryID(snapshot.id)
            }
            guard definition == snapshot else {
                throw SignalAcquisitionPolicyError.queryDefinitionChanged(snapshot.id)
            }
        }
        let selectedIDs = Set(policy.selectedQueryIDs)
        return profile.diagnosticQueries.filter { selectedIDs.contains($0.id) }
    }

    private static func validateBinding(localContextID: String, profileRevision: String) throws {
        guard !localContextID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SignalAcquisitionPolicyError.invalidContextID
        }
        guard !profileRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SignalAcquisitionPolicyError.invalidProfileRevision
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, localContextID, profileID, profileRevision, selectedQueries
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    /// Decoding validates shape only. Always resolve against the current
    /// profile and context before using or restoring a decoded selection.
    public init(from decoder: Decoder) throws {
        let allKeys = try decoder.container(keyedBy: AnyCodingKey.self).allKeys.map(\.stringValue)
        if allKeys.contains("timingOverrides") || allKeys.contains("pollInterval") || allKeys.contains("timeout") {
            throw SignalAcquisitionPolicyError.timingOverridesNotAllowed
        }
        let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        guard allKeys.allSatisfy(allowedKeys.contains) else { throw SignalAcquisitionPolicyError.invalidPolicy }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw SignalAcquisitionPolicyError.unsupportedSchemaVersion(version) }
        let context = try values.decode(String.self, forKey: .localContextID)
        let revision = try values.decode(String.self, forKey: .profileRevision)
        try Self.validateBinding(localContextID: context, profileRevision: revision)
        let profileID = try values.decode(String.self, forKey: .profileID)
        guard !profileID.isEmpty else { throw SignalAcquisitionPolicyError.invalidPolicy }
        let snapshots = try values.decode([OBDQueryDefinition].self, forKey: .selectedQueries)
        guard Set(snapshots.map(\.id)).count == snapshots.count else {
            throw SignalAcquisitionPolicyError.invalidPolicy
        }
        schemaVersion = version
        localContextID = context
        self.profileID = profileID
        profileRevision = revision
        selectedQueries = snapshots
    }
}

/// A validated explicit user action for the application's audit/persistence
/// boundary. IDs describe selection intent, never transport writes or success.
/// Construction has no side effects and does not restart acquisition.
public struct SignalAcquisitionSelectionChange: Equatable, Sendable {
    public enum Action: String, Codable, Equatable, Sendable {
        case setSelection
        case restoreProfileDefaults
    }

    public let action: Action
    public let localContextID: String
    public let profileID: String
    public let profileRevision: String
    public let previousPolicy: SignalAcquisitionPolicy?
    public let policy: SignalAcquisitionPolicy?
    public let previousQueryIDs: [String]
    public let selectedQueryIDs: [String]

    public init(previousPolicy: SignalAcquisitionPolicy?, selectedQueryIDs: [String]?,
                profile: AdapterProfile, localContextID: String, profileRevision: String) throws {
        action = selectedQueryIDs == nil ? .restoreProfileDefaults : .setSelection
        self.localContextID = localContextID
        profileID = profile.id
        self.profileRevision = profileRevision
        self.previousPolicy = previousPolicy
        // Preserve previous stored intent even when explicitly replacing a stale
        // policy; the replacement is independently validated below.
        previousQueryIDs = previousPolicy?.selectedQueryIDs ?? profile.diagnosticQueries.map(\.id)
        policy = try selectedQueryIDs.map {
            try SignalAcquisitionPolicy(queryIDs: $0, profile: profile,
                localContextID: localContextID, profileRevision: profileRevision)
        }
        self.selectedQueryIDs = try SignalAcquisitionPolicy.resolve(policy, profile: profile,
            localContextID: localContextID, profileRevision: profileRevision).map(\.id)
    }
}
