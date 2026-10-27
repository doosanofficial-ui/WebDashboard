import Foundation

public enum DiagnosticWorkspaceSettingsError: Error, Equatable, Sendable {
    case invalidContextID
    case invalidContextName
    case invalidProfileID
    case duplicateContextID(String)
    case duplicateContextName(String)
    case unknownContextID(String)
    case policyContextMismatch
    case policyProfileMismatch
    case unsupportedSchemaVersion(Int)
    case invalidSettings
    case invalidContext
}

/// A pure sidecar value. The caller saves a validated replacement atomically
/// before publishing it; this type never reads files or changes acquisition.
public struct DiagnosticWorkspaceSettings: Codable, Equatable, Sendable {
    /// An explicitly named local scope, not evidence of vehicle identity.
    public struct Context: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) throws {
            try DiagnosticWorkspaceSettings.validateContextID(id)
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else { throw DiagnosticWorkspaceSettingsError.invalidContextName }
            self.id = id
            self.name = displayName
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, name
        }

        public init(from decoder: Decoder) throws {
            try DiagnosticWorkspaceSettings.requireOnlyKeys(decoder,
                allowed: Set(CodingKeys.allCases.map(\.rawValue)), error: .invalidContext)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(id: values.decode(String.self, forKey: .id),
                name: values.decode(String.self, forKey: .name))
        }
    }

    public let schemaVersion: Int
    public let contexts: [Context]
    public let selectedContextID: String?
    /// context ID -> profile ID -> explicit selection. Missing entries mean the
    /// legacy default/all; a stored empty selection continues to mean none.
    public let acquisitionPolicies: [String: [String: SignalAcquisitionPolicy]]

    public var activeContext: Context? {
        guard let selectedContextID else { return nil }
        return contexts.first { $0.id == selectedContextID }
    }

    public init() {
        schemaVersion = 1
        contexts = []
        selectedContextID = nil
        acquisitionPolicies = [:]
    }

    public init(contexts: [Context], selectedContextID: String?,
                acquisitionPolicies: [String: [String: SignalAcquisitionPolicy]] = [:]) throws {
        var contextIDs = Set<String>()
        var contextNames = Set<String>()
        for context in contexts {
            guard contextIDs.insert(context.id).inserted else {
                throw DiagnosticWorkspaceSettingsError.duplicateContextID(context.id)
            }
            let foldedName = context.name.folding(options: .caseInsensitive,
                locale: Locale(identifier: "en_US_POSIX"))
            guard contextNames.insert(foldedName).inserted else {
                throw DiagnosticWorkspaceSettingsError.duplicateContextName(context.name)
            }
        }
        if let selectedContextID {
            try Self.requireContext(selectedContextID, knownIDs: contextIDs)
        }
        for contextID in acquisitionPolicies.keys.sorted() {
            try Self.requireContext(contextID, knownIDs: contextIDs)
            for (profileID, policy) in acquisitionPolicies[contextID] ?? [:] {
                try Self.validatePolicy(policy, localContextID: contextID, profileID: profileID)
            }
        }
        schemaVersion = 1
        self.contexts = contexts
        self.selectedContextID = selectedContextID
        self.acquisitionPolicies = acquisitionPolicies
    }

    public func addingContext(_ context: Context) throws -> Self {
        try Self(contexts: contexts + [context], selectedContextID: selectedContextID,
            acquisitionPolicies: acquisitionPolicies)
    }

    public func selectingContext(id: String?) throws -> Self {
        try Self(contexts: contexts, selectedContextID: id, acquisitionPolicies: acquisitionPolicies)
    }

    public func replacingPolicy(_ policy: SignalAcquisitionPolicy?, localContextID: String,
                                profileID: String) throws -> Self {
        try Self.requireContext(localContextID, knownIDs: Set(contexts.map(\.id)))
        try Self.validateProfileID(profileID)
        if let policy {
            try Self.validatePolicy(policy, localContextID: localContextID, profileID: profileID)
        }
        var profiles = acquisitionPolicies[localContextID] ?? [:]
        profiles[profileID] = policy
        var replacement = acquisitionPolicies
        if profiles.isEmpty {
            replacement.removeValue(forKey: localContextID)
        } else {
            replacement[localContextID] = profiles
        }
        return try Self(contexts: contexts, selectedContextID: selectedContextID,
            acquisitionPolicies: replacement)
    }

    /// No selected context returns the default policy without inventing a local
    /// context. The caller retains legacy acquisition in that unassigned scope.
    public func activePolicy(profileID: String) throws -> SignalAcquisitionPolicy? {
        try Self.validateProfileID(profileID)
        guard let selectedContextID else { return nil }
        return try policy(localContextID: selectedContextID, profileID: profileID)
    }

    public func policy(localContextID: String, profileID: String) throws -> SignalAcquisitionPolicy? {
        try Self.requireContext(localContextID, knownIDs: Set(contexts.map(\.id)))
        try Self.validateProfileID(profileID)
        return acquisitionPolicies[localContextID]?[profileID]
    }

    private static func validateContextID(_ id: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DiagnosticWorkspaceSettingsError.invalidContextID
        }
    }

    private static func requireContext(_ id: String, knownIDs: Set<String>) throws {
        try validateContextID(id)
        guard knownIDs.contains(id) else { throw DiagnosticWorkspaceSettingsError.unknownContextID(id) }
    }

    private static func validateProfileID(_ id: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DiagnosticWorkspaceSettingsError.invalidProfileID
        }
    }

    private static func validatePolicy(_ policy: SignalAcquisitionPolicy, localContextID: String,
                                       profileID: String) throws {
        try validateProfileID(profileID)
        guard policy.localContextID == localContextID else {
            throw DiagnosticWorkspaceSettingsError.policyContextMismatch
        }
        guard policy.profileID == profileID else { throw DiagnosticWorkspaceSettingsError.policyProfileMismatch }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, contexts, selectedContextID, acquisitionPolicies
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func requireOnlyKeys(_ decoder: Decoder, allowed: Set<String>,
                                        error: DiagnosticWorkspaceSettingsError) throws {
        let keys = try decoder.container(keyedBy: AnyCodingKey.self).allKeys
        guard keys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw error }
    }

    /// Rejects invalid sidecars instead of silently substituting default/all.
    /// Keeping the existing bytes on failure belongs to the caller's I/O layer.
    public init(from decoder: Decoder) throws {
        try Self.requireOnlyKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)), error: .invalidSettings)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw DiagnosticWorkspaceSettingsError.unsupportedSchemaVersion(version) }
        try self.init(contexts: values.decode([Context].self, forKey: .contexts),
            selectedContextID: values.decodeIfPresent(String.self, forKey: .selectedContextID),
            acquisitionPolicies: values.decode([String: [String: SignalAcquisitionPolicy]].self,
                forKey: .acquisitionPolicies))
    }
}
