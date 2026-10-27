import XCTest
@testable import TelemetryCore

final class ECUCapabilityCatalogueTests: XCTestCase {
    // A manufacturer-query response can be historical support evidence even
    // when the scheduler has no Mode 01 support-page admission result.
    func testVehicleResponseEvidenceDoesNotChangeCurrentSchedulerSupport() throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let context = try makeContext()
        var catalogue = try ECUCapabilityCatalogue(context: context, queries: [query])
        let evidence = try ECUCapabilityCatalogue.SupportEvidence(
            context: context,
            support: .supported,
            basis: .positiveResponse,
            origin: .vehicleSession,
            observedAtEpoch: 100, observationSequence: 1
        )

        try catalogue.recordEvidence(evidence, for: ECUCapabilityQueryID(query))

        let entry = try XCTUnwrap(catalogue.entries.first)
        XCTAssertEqual(entry.historicalEvidence, [evidence])
        XCTAssertEqual(entry.vehicleQueryEvidenceStatus, .supported)
        XCTAssertEqual(entry.currentSchedulerSupport, .unknown)
        XCTAssertNil(entry.currentState)
    }

    func testPublicDefinitionAndSyntheticResponseRemainVehicleQueryCandidates() throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let context = try makeContext()
        var catalogue = try ECUCapabilityCatalogue(context: context, queries: [query])
        XCTAssertEqual(catalogue.entries[0].vehicleQueryEvidenceStatus, .candidate)

        try catalogue.recordEvidence(.init(context: context, support: .supported,
            basis: .positiveResponse, origin: .syntheticFixture, observedAtEpoch: 200, observationSequence: 1),
            for: ECUCapabilityQueryID(query))

        XCTAssertEqual(catalogue.entries[0].vehicleQueryEvidenceStatus, .candidate)
        XCTAssertNil(catalogue.entries[0].latestVehicleEvidence)
        XCTAssertEqual(catalogue.entries[0].historicalEvidence[0].origin, .syntheticFixture)
        XCTAssertEqual(catalogue.entries[0].query.sourceCommit,
                       "c14ff9dd8a87482604200a859d7d734234d98892")
    }

    func testEvidenceCannotLeakAcrossLocalProfileOrSessionContexts() throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let context = try makeContext()
        var catalogue = try ECUCapabilityCatalogue(context: context, queries: [query])
        let foreignContexts = try [
            makeContext(localContextID: "local-B"),
            makeContext(profileID: "other-profile"),
            makeContext(profileRevision: "revision-2"),
            makeContext(sessionID: "old-session")
        ]
        for other in foreignContexts {
            let evidence = try ECUCapabilityCatalogue.SupportEvidence(context: other,
                support: .supported, basis: .positiveResponse,
                origin: .vehicleSession, observedAtEpoch: 100, observationSequence: 1)
            XCTAssertThrowsError(try catalogue.recordEvidence(evidence, for: ECUCapabilityQueryID(query)))
        }
        XCTAssertTrue(catalogue.entries[0].historicalEvidence.isEmpty)
        XCTAssertEqual(catalogue.entries[0].vehicleQueryEvidenceStatus, .candidate)
    }

    func testQueryIdentityIncludesFullTargetCommandAndSourceRevision() throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let context = try makeContext()
        var catalogue = try ECUCapabilityCatalogue(context: context, queries: [query])
        let evidence = try ECUCapabilityCatalogue.SupportEvidence(context: context,
            support: .supported, basis: .positiveResponse,
            origin: .vehicleSession, observedAtEpoch: 100, observationSequence: 1)
        let changedDefinitions = try [
            revised(query, requestCANID: 0x7E5),
            revised(query, responseCANID: 0x7ED),
            revised(query, isExtended: true),
            revised(query, service: .service21),
            revised(query, command: "0102"),
            revised(query, sourceRepository: "other-source"),
            revised(query, sourcePath: "other.json"),
            revised(query, sourceCommit: "revision-2")
        ]
        for changed in changedDefinitions {
            XCTAssertThrowsError(try catalogue.recordEvidence(evidence, for: ECUCapabilityQueryID(changed)))
        }
        XCTAssertTrue(catalogue.entries[0].historicalEvidence.isEmpty)
    }

    func testTimeoutAndNoDataPreserveEvidenceWhileCurrentAxesChangeIndependently() throws {
        let query = try SantaFeMX5HybridQueryCatalog.baselineQueries()[1]
        let context = try makeContext()
        let key = ECUCapabilityQueryID(query)
        var catalogue = try ECUCapabilityCatalogue(context: context, queries: [query])
        let evidence = try ECUCapabilityCatalogue.SupportEvidence(context: context,
            support: .supported, basis: .positiveResponse, origin: .vehicleSession,
            observedAtEpoch: 100, observationSequence: 1)
        try catalogue.recordEvidence(evidence, for: key)

        let received = try state(.responseReceived, .fresh, sequence: 1, at: 100, support: .supported)
        try catalogue.updateCurrentState(received, for: key, in: context)
        XCTAssertEqual(catalogue.entries[0].currentSchedulerSupport, .supported)

        // The wall clock rolled back, but admission order still advances.
        let noData = try state(.noData, .fresh, sequence: 2, at: 90)
        try catalogue.updateCurrentState(noData, for: key, in: context)
        XCTAssertEqual(catalogue.entries[0].currentState, noData)
        XCTAssertEqual(catalogue.entries[0].currentSchedulerSupport, .unknown)
        XCTAssertEqual(catalogue.entries[0].historicalEvidence, [evidence])

        let timeout = try state(.timedOut, .stale, sequence: 3, at: 91)
        try catalogue.updateCurrentState(timeout, for: key, in: context)
        XCTAssertEqual(catalogue.entries[0].currentState, timeout)
        XCTAssertEqual(catalogue.entries[0].vehicleQueryEvidenceStatus, .supported)
        XCTAssertEqual(catalogue.entries[0].historicalEvidence, [evidence])
    }

    func testCurrentStateRejectsForeignContextAndOlderSequenceWithoutMutation() throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let context = try makeContext()
        let key = ECUCapabilityQueryID(query)
        var catalogue = try ECUCapabilityCatalogue(context: context, queries: [query])
        let newest = try state(.noData, .stale, sequence: 3, at: 100)
        try catalogue.updateCurrentState(newest, for: key, in: context)

        XCTAssertThrowsError(try catalogue.updateCurrentState(
            state(.responseReceived, .fresh, sequence: 4, at: 101), for: key,
            in: makeContext(localContextID: "local-B")))
        XCTAssertThrowsError(try catalogue.updateCurrentState(
            state(.responseReceived, .fresh, sequence: 2, at: 300), for: key, in: context))
        XCTAssertThrowsError(try catalogue.updateCurrentState(newest,
            for: ECUCapabilityQueryID(revised(query, responseCANID: 0x7ED)), in: context))
        XCTAssertEqual(catalogue.entries[0].currentState, newest)
        XCTAssertTrue(catalogue.entries[0].historicalEvidence.isEmpty)
    }

    func testEvidenceIsBoundedAndOrderedByExplicitSequenceRatherThanWallClock() throws {
        let query = try SantaFeMX5HybridQueryCatalog.baselineQueries()[1]
        let context = try makeContext()
        let key = ECUCapabilityQueryID(query)
        var catalogue = try ECUCapabilityCatalogue(context: context, queries: [query])
        for sequence in 1...100 {
            try catalogue.recordEvidence(.init(context: context, support: .supported,
                basis: .positiveResponse, origin: .vehicleSession,
                observedAtEpoch: 1_000 - Double(sequence), observationSequence: UInt64(sequence)), for: key)
        }
        XCTAssertEqual(catalogue.entries[0].historicalEvidence.count, 1)
        XCTAssertEqual(catalogue.entries[0].latestVehicleEvidence?.observedAtEpoch, 900)
        XCTAssertThrowsError(try catalogue.recordEvidence(.init(context: context, support: .supported,
            basis: .positiveResponse, origin: .vehicleSession,
            observedAtEpoch: 5_000, observationSequence: 99), for: key))

        let unsupported = try ECUCapabilityCatalogue.SupportEvidence(context: context, support: .unsupported,
            basis: .schedulerSupport, origin: .vehicleSession,
            observedAtEpoch: 899, observationSequence: 101)
        try catalogue.recordEvidence(unsupported, for: key)
        try catalogue.recordEvidence(unsupported, for: key)
        try catalogue.recordEvidence(.init(context: context, support: .supported,
            basis: .positiveResponse, origin: .syntheticFixture,
            observedAtEpoch: 6_000, observationSequence: 1), for: key)

        XCTAssertEqual(catalogue.entries[0].historicalEvidence.count, 3)
        XCTAssertEqual(catalogue.entries[0].latestVehicleEvidence, unsupported)
        XCTAssertEqual(catalogue.entries[0].vehicleQueryEvidenceStatus, .unsupported)
        XCTAssertEqual(catalogue.entries[0].currentSchedulerSupport, .unknown)
    }

    func testInvalidContextTimesAndInferredSupportEvidenceAreRejected() throws {
        for invalidContext in [
            { try self.makeContext(localContextID: " ") },
            { try self.makeContext(profileID: "") },
            { try self.makeContext(profileRevision: "\n") },
            { try self.makeContext(sessionID: "") }
        ] {
            XCTAssertThrowsError(try invalidContext())
        }
        let context = try makeContext()
        let invalidPositiveSupport: [OBDQuerySupport] = [.unknown, .unsupported]
        for support in invalidPositiveSupport {
            XCTAssertThrowsError(try ECUCapabilityCatalogue.SupportEvidence(context: context,
                support: support, basis: .positiveResponse, origin: .vehicleSession,
                observedAtEpoch: 100, observationSequence: 1))
        }
        for invalidTime in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try ECUCapabilityCatalogue.SupportEvidence(context: context,
                support: .supported, basis: .schedulerSupport, origin: .syntheticFixture,
                observedAtEpoch: invalidTime, observationSequence: 1))
            XCTAssertThrowsError(try state(.noData, .unknown, sequence: 1, at: invalidTime))
        }
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        XCTAssertThrowsError(try ECUCapabilityCatalogue(context: context, queries: [query, query]))
    }

    func testExplicitCodableRestoreRetainsHistoryButStartsCurrentStateUnknown() throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let context = try makeContext()
        let key = ECUCapabilityQueryID(query)
        var catalogue = try ECUCapabilityCatalogue(context: context, queries: [query])
        let evidence = try ECUCapabilityCatalogue.SupportEvidence(context: context, support: .supported,
            basis: .positiveResponse, origin: .vehicleSession,
            observedAtEpoch: 100, observationSequence: 99)
        try catalogue.recordEvidence(evidence, for: key)
        try catalogue.updateCurrentState(state(.responseReceived, .fresh, sequence: 99, at: 100),
                                         for: key, in: context)
        let data = try JSONEncoder().encode(catalogue.snapshot())
        let snapshot = try JSONDecoder().decode(ECUCapabilityCatalogue.Snapshot.self, from: data)
        XCTAssertEqual(snapshot, catalogue.snapshot())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("currentState"))

        let newSession = try makeContext(sessionID: "session-B")
        let newQuery = try SantaFeMX5HybridQueryCatalog.baselineQueries()[1]
        var restored = try ECUCapabilityCatalogue.restoring(snapshot, in: newSession, queries: [query, newQuery])
        XCTAssertEqual(restored.context, newSession)
        XCTAssertEqual(restored.entries[0].historicalEvidence, [evidence])
        XCTAssertEqual(restored.entries[0].query, query)
        XCTAssertNil(restored.entries[0].currentState)
        XCTAssertEqual(restored.entries[0].currentSchedulerSupport, .unknown)
        XCTAssertTrue(restored.entries[1].historicalEvidence.isEmpty)
        XCTAssertEqual(restored.entries[1].vehicleQueryEvidenceStatus, .candidate)

        // A new session's sequence restarts explicitly; historical session 99
        // cannot block its first current state or replace its observation time.
        let newState = try state(.noData, .unknown, sequence: 1, at: 80)
        try restored.updateCurrentState(newState, for: key, in: newSession)
        XCTAssertEqual(restored.entries[0].currentState, newState)
        let restoredEvidence = try XCTUnwrap(restored.entries[0].historicalEvidence.first)
        XCTAssertEqual(restoredEvidence.context.sessionID, "session-A")
        XCTAssertEqual(restoredEvidence.observedAtEpoch, 100)
    }

    func testRestoreRejectsForeignScopeAndChangedKnownQueryDefinitions() throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let context = try makeContext()
        let snapshot = try ECUCapabilityCatalogue(context: context, queries: [query]).snapshot()
        let foreign = try [makeContext(localContextID: "local-B"), makeContext(profileID: "other"),
                           makeContext(profileRevision: "revision-2")]
        for other in foreign {
            XCTAssertThrowsError(try ECUCapabilityCatalogue.restoring(snapshot, in: other, queries: [query]))
        }
        for changed in try [revised(query, sourceCommit: "revision-2"), revised(query, responseCANID: 0x7ED)] {
            XCTAssertThrowsError(try ECUCapabilityCatalogue.restoring(snapshot, in: context, queries: [changed]))
        }
    }

    func testDecodedSnapshotsCannotSmuggleInvalidContextOrCrossContextEvidence() throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let context = try makeContext()
        var catalogue = try ECUCapabilityCatalogue(context: context, queries: [query])
        try catalogue.recordEvidence(.init(context: context, support: .supported, basis: .positiveResponse,
            origin: .vehicleSession, observedAtEpoch: 100, observationSequence: 1), for: ECUCapabilityQueryID(query))
        let data = try JSONEncoder().encode(catalogue.snapshot())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        var invalidContext = object
        var contextObject = try XCTUnwrap(object["context"] as? [String: Any])
        contextObject["localContextID"] = " "
        invalidContext["context"] = contextObject
        XCTAssertThrowsError(try JSONDecoder().decode(ECUCapabilityCatalogue.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: invalidContext)))

        var invalidSchema = object
        invalidSchema["schemaVersion"] = 2
        let badSchema = try JSONDecoder().decode(ECUCapabilityCatalogue.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: invalidSchema))
        XCTAssertThrowsError(try ECUCapabilityCatalogue.restoring(badSchema, in: context, queries: [query]))

        var crossContext = object
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        var evidence = try XCTUnwrap(entries[0]["historicalEvidence"] as? [[String: Any]])
        var evidenceContext = try XCTUnwrap(evidence[0]["context"] as? [String: Any])
        evidenceContext["localContextID"] = "local-B"
        evidence[0]["context"] = evidenceContext
        entries[0]["historicalEvidence"] = evidence
        crossContext["entries"] = entries
        let badScope = try JSONDecoder().decode(ECUCapabilityCatalogue.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: crossContext))
        XCTAssertThrowsError(try ECUCapabilityCatalogue.restoring(badScope, in: context, queries: [query]))
    }

    func testManufacturerAndPIDZeroQueriesCannotGainSchedulerSupportEvidenceOrAdmission() throws {
        let context = try makeContext()
        let queries = try [SantaFeMX5HybridQueryCatalog.hvBatterySOC(),
                           SantaFeMX5HybridQueryCatalog.baselineQueries()[0]]
        for query in queries {
            let key = ECUCapabilityQueryID(query)
            var catalogue = try ECUCapabilityCatalogue(context: context, queries: [query])
            let knownSupport: [OBDQuerySupport] = [.supported, .unsupported]
            for support in knownSupport {
                let evidence = try ECUCapabilityCatalogue.SupportEvidence(context: context,
                    support: support, basis: .schedulerSupport, origin: .vehicleSession,
                    observedAtEpoch: 100, observationSequence: 1)
                XCTAssertThrowsError(try catalogue.recordEvidence(evidence, for: key))
                XCTAssertThrowsError(try catalogue.updateCurrentState(
                    state(.responseReceived, .fresh, sequence: 1, at: 100, support: support),
                    for: key, in: context))
            }
            XCTAssertTrue(catalogue.entries[0].historicalEvidence.isEmpty)
            XCTAssertNil(catalogue.entries[0].currentState)
            XCTAssertEqual(catalogue.entries[0].vehicleQueryEvidenceStatus, .candidate)
        }
    }

    func testRestoreRejectsSchedulerSupportEvidenceAppliedToManufacturerDefinition() throws {
        let context = try makeContext()
        let mode01 = try SantaFeMX5HybridQueryCatalog.baselineQueries()[1]
        let manufacturer = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        var catalogue = try ECUCapabilityCatalogue(context: context, queries: [mode01])
        try catalogue.recordEvidence(.init(context: context, support: .unsupported,
            basis: .schedulerSupport, origin: .vehicleSession,
            observedAtEpoch: 100, observationSequence: 1), for: ECUCapabilityQueryID(mode01))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(catalogue.snapshot())) as? [String: Any])
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries[0]["query"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manufacturer))
        object["entries"] = entries
        let snapshot = try JSONDecoder().decode(ECUCapabilityCatalogue.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: object))

        XCTAssertThrowsError(try ECUCapabilityCatalogue.restoring(snapshot,
            in: context, queries: [manufacturer]))
    }

    private func makeContext(
        localContextID: String = "local-A", profileID: String = "profile-1",
        profileRevision: String = "revision-1",
        sessionID: String = "session-A"
    ) throws -> VehicleContext {
        try VehicleContext(
            localContextID: localContextID, profileID: profileID,
            profileRevision: profileRevision, sessionID: sessionID
        )
    }

    private func revised(
        _ query: OBDQueryDefinition, id: String? = nil,
        requestCANID: UInt32? = nil, responseCANID: UInt32? = nil,
        isExtended: Bool? = nil, service: OBDService? = nil, command: String? = nil,
        sourceRepository: String? = nil, sourcePath: String? = nil, sourceCommit: String? = nil
    ) throws -> OBDQueryDefinition {
        try OBDQueryDefinition(id: id ?? query.id, name: query.name,
            requestCANID: requestCANID ?? query.requestCANID,
            responseCANID: responseCANID ?? query.responseCANID,
            isExtended: isExtended ?? query.isExtended, service: service ?? query.service,
            command: command ?? query.command, pollInterval: query.pollInterval,
            timeout: query.timeout, flowControl: query.flowControl,
            sourceRepository: sourceRepository ?? query.sourceRepository,
            sourcePath: sourcePath ?? query.sourcePath,
            sourceCommit: sourceCommit ?? query.sourceCommit, signals: query.signals)
    }

    private func state(
        _ availability: ECUCapabilityCatalogue.Availability,
        _ freshness: ECUCapabilityCatalogue.Freshness,
        sequence: UInt64, at time: Double, support: OBDQuerySupport = .unknown
    ) throws -> ECUCapabilityCatalogue.CurrentState {
        try .init(schedulerSupport: support, availability: availability, freshness: freshness,
                  origin: .vehicleSession, observedAtEpoch: time, observationSequence: sequence)
    }
}
