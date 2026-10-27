import CryptoKit
import Foundation
import Observation
import TelemetryCore

/// MainActor composition for explicit local scopes and read-only query settings.
/// UI selection does not start acquisition. Current observations never go to disk.
@MainActor @Observable
final class DiagnosticWorkspaceState {
    private(set) var document = DiagnosticWorkspaceDocument()
    private(set) var catalogue: ECUCapabilityCatalogue?
    private(set) var storageError: String?
    private(set) var evidenceSaveError: String?
    private(set) var observationError: String?
    private(set) var acquiring = false
    private(set) var connectionID: UUID?
    private(set) var evidenceDirty = false
    @ObservationIgnored private var storage: DiagnosticWorkspaceStorage?
    @ObservationIgnored private var connectedProfile: AdapterProfile?
    @ObservationIgnored private var receiptTimes: [String: [String: Double]] = [:]

    var settings: DiagnosticWorkspaceSettings { document.settings }
    var canEdit: Bool { !acquiring && storage != nil && storageError == nil }

    static func revision(of profile: AdapterProfile) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(profile)).map { String(format: "%02x", $0) }.joined()
    }

    func configure(at url: URL) {
        configure(storage: DiagnosticWorkspaceStorage(url: url))
    }

    func configure(storage candidate: DiagnosticWorkspaceStorage) {
        do {
            let loaded = try candidate.load()
            document = loaded
            storage = candidate
            storageError = nil
        } catch {
            // Invalid/future bytes are retained. In particular, do not reset a
            // broken explicit selection to all configured vehicle requests.
            storage = nil
            storageError = "Diagnostic settings could not be read; existing file retained."
        }
    }

    func selectedQueries(profile: AdapterProfile) throws -> [OBDQueryDefinition] {
        guard storage != nil, storageError == nil else { throw WorkspaceError.unavailable }
        guard let contextID = settings.selectedContextID else { return profile.diagnosticQueries }
        return try SignalAcquisitionPolicy.resolve(settings.activePolicy(profileID: profile.id),
            profile: profile, localContextID: contextID, profileRevision: Self.revision(of: profile))
    }

    func addContext(name: String, profile: AdapterProfile?) throws {
        guard canEdit else { throw WorkspaceError.stopAcquisition }
        let context = try DiagnosticWorkspaceSettings.Context(id: UUID().uuidString, name: name)
        let replacement = try settings.addingContext(context).selectingContext(id: context.id)
        try commit(document.replacingSettings(replacement))
        try preview(profile: profile)
    }

    func selectContext(_ id: String?, profile: AdapterProfile?) throws {
        guard canEdit else { throw WorkspaceError.stopAcquisition }
        try commit(document.replacingSettings(settings.selectingContext(id: id)))
        try preview(profile: profile)
    }

    func apply(_ change: SignalAcquisitionSelectionChange, profile: AdapterProfile) throws {
        guard canEdit else { throw WorkspaceError.stopAcquisition }
        let replacement = try document.applying(change, profile: profile, profileRevision: Self.revision(of: profile))
        try commit(replacement)
    }

    private func commit(_ proposed: DiagnosticWorkspaceDocument) throws {
        guard let storage else { throw WorkspaceError.unavailable }
        // Fold admitted evidence into the same transaction; no asynchronous
        // history writer can later replace a newer selection or local context.
        let replacement = try catalogue.map { try proposed.replacingCatalogue($0) } ?? proposed
        try storage.save(replacement)
        document = replacement
        evidenceDirty = false
        evidenceSaveError = nil
    }

    func preview(profile: AdapterProfile?) throws {
        guard !acquiring else { return }
        if evidenceDirty {
            flushEvidence()
            guard !evidenceDirty else { throw WorkspaceError.unavailable }
        }
        // Keep the previous admitted evidence until its save and the complete
        // replacement projection both succeed. A failed preview is retryable.
        let replacement: ECUCapabilityCatalogue?
        if let profile, let id = settings.selectedContextID {
            let context = try VehicleContext(localContextID: id, profileID: profile.id,
                profileRevision: Self.revision(of: profile), sessionID: "not-connected")
            replacement = try document.catalogue(in: context, queries: profile.diagnosticQueries)
        } else {
            replacement = nil
        }
        catalogue = replacement
    }

    func setAcquiring(_ value: Bool) {
        acquiring = value
        if !value {
            // Close admission first. Late A audit completions have a separate
            // receiver and cannot alter this active vehicle/context display.
            connectionID = nil
            receiptTimes = [:]
            flushEvidence()
            // Clear current availability using admitted history, even if its
            // disk write failed. Retry must retain the unsaved observations.
            if let current = catalogue {
                do {
                    let context = try VehicleContext(localContextID: current.context.localContextID,
                        profileID: current.context.profileID, profileRevision: current.context.profileRevision,
                        sessionID: "not-connected")
                    catalogue = try ECUCapabilityCatalogue.restoring(current.snapshot(), in: context,
                        queries: current.entries.map(\.query))
                } catch { evidenceSaveError = "Query evidence could not be restored for this context." }
            }
        }
    }

    func beganConnection(_ id: UUID, profile: AdapterProfile) {
        connectionID = id
        observationError = nil
        connectedProfile = profile
        receiptTimes = [:]
        do {
            if let catalogue { document = try document.replacingCatalogue(catalogue) }
            guard let localID = settings.selectedContextID else { catalogue = nil; return }
            let context = try VehicleContext(localContextID: localID, profileID: profile.id,
                profileRevision: Self.revision(of: profile), sessionID: id.uuidString)
            catalogue = try document.catalogue(in: context, queries: profile.diagnosticQueries)
        } catch {
            catalogue = nil
            evidenceSaveError = "Query evidence could not be restored for this context."
        }
    }

    func invalidateObservations(connectionID id: UUID) {
        guard connectionID == id else { return }
        connectionID = nil
        receiptTimes = [:]
        observationError = "Query observation history is incomplete. Stop and start acquisition to observe current availability again."
        if let current = catalogue {
            // Keep historical provenance and the running/edit lock. Lost
            // metadata cannot be displayed as current evidence or alter polling.
            catalogue = try? ECUCapabilityCatalogue.restoring(current.snapshot(), in: current.context,
                                                             queries: current.entries.map(\.query))
        }
    }

    func observe(_ observation: DiagnosticCapabilityObservation) {
        guard acquiring, connectionID == observation.connectionID,
              let profile = connectedProfile, var current = catalogue else { return }
        var received = receiptTimes
        do {
            for query in profile.diagnosticQueries {
                let key = ECUCapabilityQueryID(query)
                let previous = current.entries.first { ECUCapabilityQueryID($0.query) == key }?.currentState
                let isOutcomeQuery = query.id == observation.queryID
                let support = observation.supportByQueryID[query.id] ?? .unknown
                let state = try ECUCapabilityCatalogue.CurrentState(schedulerSupport: support,
                    availability: isOutcomeQuery ? observation.availability : previous?.availability ?? .unknown,
                    freshness: .unknown, origin: observation.origin, observedAtEpoch: observation.timestamp,
                    observationSequence: observation.sequence)
                try current.updateCurrentState(state, for: key, in: current.context)
                if isOutcomeQuery, case .success(let result) = observation.outcome {
                    for signal in result.signals {
                        received[query.id, default: [:]][signal.signalID] = signal.receivedAtEpoch
                    }
                    try current.recordEvidence(.init(context: current.context, support: .supported,
                        basis: .positiveResponse, origin: observation.origin,
                        observedAtEpoch: observation.timestamp, observationSequence: observation.sequence), for: key)
                }
                // Only a new, successfully decoded bitmap observation can
                // timestamp scheduler support. Failures preserve old evidence.
                if observation.freshSupportQueryIDs.contains(query.id), support != .unknown {
                    try current.recordEvidence(.init(context: current.context, support: support,
                        basis: .schedulerSupport, origin: observation.origin,
                        observedAtEpoch: observation.timestamp, observationSequence: observation.sequence), for: key)
                }
            }
            if catalogue?.snapshot() != current.snapshot() { evidenceDirty = true }
            catalogue = current
            receiptTimes = received
        } catch {
            evidenceSaveError = "Query evidence observation was rejected; earlier evidence retained."
        }
    }

    func freshness(at date: Date) -> [ECUCapabilityQueryID: ECUCapabilityCatalogue.Freshness] {
        guard acquiring, let catalogue else { return [:] }
        return Dictionary(uniqueKeysWithValues: catalogue.entries.map { entry in
            let statuses = entry.query.signals.map { signal -> ECUCapabilityCatalogue.Freshness in
                guard let received = receiptTimes[entry.query.id]?[signal.id] else { return .unknown }
                return max(0, date.timeIntervalSince1970 - received) > signal.timeout ? .stale : .fresh
            }
            let value: ECUCapabilityCatalogue.Freshness = statuses.isEmpty || statuses.contains(.unknown)
                ? .unknown : statuses.contains(.stale) ? .stale : .fresh
            return (ECUCapabilityQueryID(entry.query), value)
        })
    }

    func flushEvidence() {
        guard evidenceDirty, let storage, let catalogue else { return }
        do {
            let replacement = try document.replacingCatalogue(catalogue)
            try storage.save(replacement)
            document = replacement
            evidenceDirty = false
            evidenceSaveError = nil
        } catch {
            evidenceSaveError = "Recent query evidence is not saved. Retry when local storage is available."
        }
    }

    enum WorkspaceError: Error { case unavailable, stopAcquisition }
}

/// A single controller-owned admission order, spanning successful and failed
/// outcomes. Raw response sequence remains available in the diagnostic audit.
struct DiagnosticCapabilityObservation {
    let connectionID: UUID
    let queryID: String
    let outcome: OBDQueryOutcome
    let supportByQueryID: [String: OBDQuerySupport]
    let freshSupportQueryIDs: Set<String>
    let origin: ECUCapabilityCatalogue.Origin
    let timestamp: Double
    let sequence: UInt64

    var availability: ECUCapabilityCatalogue.Availability {
        switch outcome {
        case .success: return .responseReceived
        case .failure(_, .response(.noData)): return .noData
        case .failure(_, .timeout): return .timedOut
        case .failure(_, .disconnected): return .disconnected
        case .failure: return .failed
        }
    }
}
