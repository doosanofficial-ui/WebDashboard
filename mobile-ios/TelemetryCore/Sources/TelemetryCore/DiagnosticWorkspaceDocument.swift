import Foundation

public enum DiagnosticWorkspaceDocumentError: Error, Equatable {
    case unsupportedSchema, unknownContext, duplicateSnapshot, staleSelection, tooLarge
}

/// Separate from measurement/profile schemas. Current connection availability
/// is never restored from this historical evidence sidecar.
public struct DiagnosticWorkspaceDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let settings: DiagnosticWorkspaceSettings
    public let evidenceSnapshots: [ECUCapabilityCatalogue.Snapshot]
    fileprivate static let maximumEncodedBytes = 1_048_576

    public init() {
        schemaVersion = 1
        settings = .init()
        evidenceSnapshots = []
    }

    public init(settings: DiagnosticWorkspaceSettings,
                evidenceSnapshots: [ECUCapabilityCatalogue.Snapshot] = []) throws {
        let known = Set(settings.contexts.map(\.id))
        var slots = Set<Slot>()
        for snapshot in evidenceSnapshots {
            guard known.contains(snapshot.context.localContextID) else {
                throw DiagnosticWorkspaceDocumentError.unknownContext
            }
            guard slots.insert(Slot(snapshot.context)).inserted else {
                throw DiagnosticWorkspaceDocumentError.duplicateSnapshot
            }
            // Decode alone is not sufficient: the catalogue validates source
            // definitions, evidence domain and same-context history on restore.
            _ = try ECUCapabilityCatalogue.restoring(snapshot, in: snapshot.context,
                queries: snapshot.entries.map(\.query))
        }
        schemaVersion = 1
        self.settings = settings
        self.evidenceSnapshots = evidenceSnapshots
    }

    private struct Slot: Hashable {
        let localContextID: String
        let profileID: String
        init(_ context: VehicleContext) {
            localContextID = context.localContextID
            profileID = context.profileID
        }
    }

    public func replacingSettings(_ replacement: DiagnosticWorkspaceSettings) throws -> Self {
        try Self(settings: replacement, evidenceSnapshots: evidenceSnapshots)
    }

    public func replacingCatalogue(_ catalogue: ECUCapabilityCatalogue) throws -> Self {
        var snapshots = evidenceSnapshots
        let slot = Slot(catalogue.context)
        if let index = snapshots.firstIndex(where: { Slot($0.context) == slot }) {
            snapshots[index] = catalogue.snapshot()
        } else { snapshots.append(catalogue.snapshot()) }
        return try Self(settings: settings, evidenceSnapshots: snapshots)
    }

    public func catalogue(in context: VehicleContext,
                          queries: [OBDQueryDefinition]) throws -> ECUCapabilityCatalogue {
        guard settings.contexts.contains(where: { $0.id == context.localContextID }) else {
            throw DiagnosticWorkspaceDocumentError.unknownContext
        }
        if let snapshot = evidenceSnapshots.first(where: {
            Slot($0.context) == Slot(context) && $0.context.profileRevision == context.profileRevision
        }) {
            return try ECUCapabilityCatalogue.restoring(snapshot, in: context, queries: queries)
        }
        return try ECUCapabilityCatalogue(context: context, queries: queries)
    }

    public func applying(_ change: SignalAcquisitionSelectionChange, profile: AdapterProfile,
                         profileRevision: String) throws -> Self {
        guard settings.selectedContextID == change.localContextID,
              profile.id == change.profileID, profileRevision == change.profileRevision,
              try settings.activePolicy(profileID: profile.id) == change.previousPolicy else {
            throw DiagnosticWorkspaceDocumentError.staleSelection
        }
        let resolved = try SignalAcquisitionPolicy.resolve(change.policy, profile: profile,
            localContextID: change.localContextID, profileRevision: profileRevision)
        guard resolved.map(\.id) == change.selectedQueryIDs else {
            throw DiagnosticWorkspaceDocumentError.staleSelection
        }
        return try replacingSettings(settings.replacingPolicy(change.policy,
            localContextID: change.localContextID, profileID: profile.id))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw DiagnosticWorkspaceDocumentError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw DiagnosticWorkspaceDocumentError.tooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, settings, evidenceSnapshots }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw DiagnosticWorkspaceDocumentError.unsupportedSchema
        }
        try self.init(settings: values.decode(DiagnosticWorkspaceSettings.self, forKey: .settings),
            evidenceSnapshots: values.decode([ECUCapabilityCatalogue.Snapshot].self, forKey: .evidenceSnapshots))
    }
}

/// The app calls this synchronously on its serial state owner. Only absence
/// produces defaults; read/validation/write failures are returned unchanged.
public struct DiagnosticWorkspaceStorage {
    public let url: URL
    private let write: (Data, URL) throws -> Void

    public init(url: URL, write: @escaping (Data, URL) throws -> Void = { data, target in
        try data.write(to: target, options: .atomic)
    }) {
        self.url = url
        self.write = write
    }

    public func load() throws -> DiagnosticWorkspaceDocument {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: DiagnosticWorkspaceDocument.maximumEncodedBytes + 1) ?? Data()
            return try DiagnosticWorkspaceDocument.decode(data)
        }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .init()
        }
    }

    public func save(_ document: DiagnosticWorkspaceDocument) throws {
        try write(document.encoded(), url)
    }
}
