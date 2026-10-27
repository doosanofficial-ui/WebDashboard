import Foundation
import XCTest
@testable import TelemetryCore

final class DiagnosticWorkspaceDocumentTests: XCTestCase {
    private func settings() throws -> DiagnosticWorkspaceSettings {
        try .init(contexts: [.init(id: "local-a", name: "A"), .init(id: "local-b", name: "B")],
                  selectedContextID: "local-a")
    }

    private func catalogue(contextID: String = "local-a", session: String = "connection-a") throws -> ECUCapabilityCatalogue {
        let context = try VehicleContext(localContextID: contextID, profileID: "profile",
            profileRevision: "revision", sessionID: session)
        let query = try SantaFeMX5HybridQueryCatalog.initialQueries()[2]
        var value = try ECUCapabilityCatalogue(context: context, queries: [query])
        try value.recordEvidence(.init(context: context, support: .supported, basis: .positiveResponse,
            origin: .syntheticFixture, observedAtEpoch: 100, observationSequence: 1), for: .init(query))
        try value.updateCurrentState(.init(schedulerSupport: .unknown, availability: .responseReceived,
            freshness: .fresh, origin: .syntheticFixture, observedAtEpoch: 100, observationSequence: 1),
            for: .init(query), in: context)
        return value
    }

    func testMissingFileUsesLegacyEmptyWithoutCreatingAnything() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = folder.appendingPathComponent("diagnostic-workspace.json")
        let store = DiagnosticWorkspaceStorage(url: url)
        let document = try store.load()
        XCTAssertNil(document.settings.selectedContextID)
        XCTAssertTrue(document.evidenceSnapshots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testHistoricalEvidenceRoundTripResetsCurrentAvailabilityAndIsolatesContexts() throws {
        let first = try catalogue()
        let doc = try DiagnosticWorkspaceDocument(settings: settings()).replacingCatalogue(first)
        let decoded = try DiagnosticWorkspaceDocument.decode(doc.encoded())
        let next = try VehicleContext(localContextID: "local-a", profileID: "profile", profileRevision: "revision", sessionID: "new")
        let restored = try decoded.catalogue(in: next, queries: first.entries.map(\.query))
        XCTAssertEqual(restored.entries[0].historicalEvidence, first.entries[0].historicalEvidence)
        XCTAssertNil(restored.entries[0].currentState)
        let other = try VehicleContext(localContextID: "local-b", profileID: "profile", profileRevision: "revision", sessionID: "other")
        XCTAssertTrue(try decoded.catalogue(in: other, queries: first.entries.map(\.query)).entries[0].historicalEvidence.isEmpty)
        let newerProfile = try VehicleContext(localContextID: "local-a", profileID: "profile", profileRevision: "revision-2", sessionID: "new")
        XCTAssertTrue(try decoded.catalogue(in: newerProfile, queries: first.entries.map(\.query)).entries[0].historicalEvidence.isEmpty)
    }

    func testUnknownContextAndDuplicateEvidenceSlotsAreRejected() throws {
        XCTAssertThrowsError(try DiagnosticWorkspaceDocument(settings: settings()).replacingCatalogue(catalogue(contextID: "foreign")))
        let snapshot = try catalogue().snapshot()
        XCTAssertThrowsError(try DiagnosticWorkspaceDocument(settings: settings(), evidenceSnapshots: [snapshot, snapshot]))
    }

    func testEvidenceCacheKeepsOnlyLatestRevisionForEachExplicitContextAndProfile() throws {
        let original = try catalogue()
        var doc = try DiagnosticWorkspaceDocument(settings: settings()).replacingCatalogue(original)
        for revision in 0..<25 {
            let context = try VehicleContext(localContextID: "local-a", profileID: "profile",
                profileRevision: "revision-\(revision)", sessionID: "new")
            doc = try doc.replacingCatalogue(ECUCapabilityCatalogue(context: context,
                queries: original.entries.map(\.query)))
        }
        XCTAssertEqual(doc.evidenceSnapshots.count, 1)
        XCTAssertEqual(doc.evidenceSnapshots.first?.context.profileRevision, "revision-24")
        XCTAssertTrue(try doc.catalogue(in: original.context,
            queries: original.entries.map(\.query)).entries[0].historicalEvidence.isEmpty)
    }

    func testFutureSchemaAndMalformedFileAreRetainedWithoutFallback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("diagnostic-workspace.json")
        let store = DiagnosticWorkspaceStorage(url: url)
        let valid = try DiagnosticWorkspaceDocument(settings: settings()).encoded()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["schemaVersion"] = 999
        let future = try JSONSerialization.data(withJSONObject: object)
        try future.write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), future)
        let broken = Data("invalid user bytes".utf8)
        try broken.write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }

    func testFailedWriteDoesNotReplaceExistingSidecarOrCallerValue() throws {
        enum Failure: Error { case injected }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("diagnostic-workspace.json")
        let original = try DiagnosticWorkspaceDocument(settings: settings())
        let working = DiagnosticWorkspaceStorage(url: url)
        try working.save(original)
        let originalBytes = try Data(contentsOf: url)
        let next = try original.replacingSettings(original.settings.selectingContext(id: "local-b"))
        let failing = DiagnosticWorkspaceStorage(url: url, write: { _, _ in throw Failure.injected })
        XCTAssertThrowsError(try failing.save(next))
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        XCTAssertEqual(try working.load(), original)
        try working.save(next)
        XCTAssertEqual(try working.load().settings.selectedContextID, "local-b")
    }

    func testPolicyApplyRejectsStalePreviousValueAndPreservesExplicitNone() throws {
        let queries = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let profile = try AdapterProfile(id: "profile", name: "Fixture", transport: .wifi,
            peripheralID: nil, serviceUUID: nil, writeCharacteristicUUID: nil, notifyCharacteristicUUID: nil,
            host: "127.0.0.1", port: 35000, signals: [], diagnosticQueries: queries)
        let initial = try DiagnosticWorkspaceDocument(settings: settings())
        let none = try SignalAcquisitionSelectionChange(previousPolicy: nil, selectedQueryIDs: [],
            profile: profile, localContextID: "local-a", profileRevision: "revision")
        let selectedNone = try initial.applying(none, profile: profile, profileRevision: "revision")
        XCTAssertEqual(try selectedNone.settings.activePolicy(profileID: "profile")?.selectedQueryIDs, [])
        let stale = try SignalAcquisitionSelectionChange(previousPolicy: nil, selectedQueryIDs: [queries[0].id],
            profile: profile, localContextID: "local-a", profileRevision: "revision")
        XCTAssertThrowsError(try selectedNone.applying(stale, profile: profile, profileRevision: "revision"))
        XCTAssertThrowsError(try initial.applying(none, profile: profile, profileRevision: "changed"))
        let switched = try initial.replacingSettings(initial.settings.selectingContext(id: "local-b"))
        XCTAssertThrowsError(try switched.applying(none, profile: profile, profileRevision: "revision"))
    }
}
