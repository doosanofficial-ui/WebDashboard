import Foundation
import XCTest
@testable import TelemetryCore

final class SignalAcquisitionPolicyTests: XCTestCase {
    // Catches changing the legacy default into an empty or reordered selection.
    func testUnconfiguredPolicyPreservesExistingQueryOrderAndTiming() throws {
        let profile = try profile()
        let resolved = try resolve(nil, profile: profile)

        XCTAssertEqual(resolved.map(\.id), ["rpm", "soc"])
        XCTAssertEqual(resolved.map(\.pollInterval), [0.2, 1.0])
        XCTAssertEqual(resolved.map(\.timeout), [1.5, 2.0])
        XCTAssertEqual(resolved, profile.diagnosticQueries)
    }

    // Catches treating explicit none as the unconfigured legacy default.
    func testExplicitEmptySelectionResolvesToNoQueries() throws {
        let profile = try profile()
        let policy = try selection([], profile: profile)

        XCTAssertEqual(try resolve(policy, profile: profile), [])
        XCTAssertEqual(policy.selectedQueryIDs, [])
    }

    // Catches a caller's ID order or duplicates duplicating/reordering polling.
    func testDuplicateIDsResolveOnceInConfiguredOrder() throws {
        let profile = try profile()
        let policy = try selection(["soc", "rpm", "soc", "rpm"], profile: profile)

        XCTAssertEqual(policy.selectedQueryIDs, ["rpm", "soc"])
        XCTAssertEqual(try resolve(policy, profile: profile), profile.diagnosticQueries)
    }

    // Catches accepting an ID that could introduce an unconfigured request.
    func testUnknownQueryIDIsRejected() throws {
        XCTAssertThrowsError(try selection(["rpm", "not-configured"], profile: profile())) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .unknownQueryID("not-configured"))
        }
    }

    // Catches a selection API accidentally becoming a polling-rate editor.
    func testTimingOverrideIsRejected() throws {
        XCTAssertThrowsError(try SignalAcquisitionPolicy(
            queryIDs: ["rpm"], profile: profile(), localContextID: "local-A",
            profileRevision: "revision-1", timingOverrides: ["rpm": 0.01]
        )) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .timingOverridesNotAllowed)
        }
    }

    // Catches a saved selection leaking to another explicitly chosen context.
    func testContextMismatchRejectsRestore() throws {
        let profile = try profile()
        let policy = try selection(["rpm"], profile: profile)

        XCTAssertThrowsError(try SignalAcquisitionPolicy.resolve(
            policy, profile: profile, localContextID: "local-B", profileRevision: "revision-1"
        )) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .contextMismatch)
        }
    }

    // Catches reusing a policy merely because the new profile has the same IDs.
    func testProfileMismatchRejectsRestore() throws {
        let policy = try selection(["rpm"], profile: profile())

        XCTAssertThrowsError(try resolve(policy, profile: profile(id: "other-profile"))) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .profileMismatch)
        }
    }

    // Catches a root-supplied profile revision being ignored during restoration.
    func testProfileRevisionMismatchRejectsRestore() throws {
        let profile = try profile()
        let policy = try selection(["rpm"], profile: profile)

        XCTAssertThrowsError(try SignalAcquisitionPolicy.resolve(
            policy, profile: profile, localContextID: "local-A", profileRevision: "revision-2"
        )) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .profileRevisionMismatch)
        }
    }

    // Catches a reused query ID silently authorizing a changed request/cadence.
    func testSelectedDefinitionDriftRejectsRestore() throws {
        let original = try profile()
        let policy = try selection(["rpm"], profile: original)
        let changed = try profile(queries: [query(id: "rpm", command: "0D", pollInterval: 0.2, timeout: 1.5),
                                            original.diagnosticQueries[1]])

        XCTAssertThrowsError(try resolve(policy, profile: changed)) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .queryDefinitionChanged("rpm"))
        }
    }

    // Catches saved explicit "all" becoming a wildcard after a catalogue import.
    func testExplicitAllDoesNotIncludeNewlyImportedQuery() throws {
        let original = try profile()
        let policy = try selection(["rpm", "soc"], profile: original)
        let expanded = try profile(queries: original.diagnosticQueries + [query(id: "added", command: "05")])

        XCTAssertEqual(try resolve(policy, profile: expanded).map(\.id), ["rpm", "soc"])
        XCTAssertEqual(try resolve(nil, profile: expanded).map(\.id), ["rpm", "soc", "added"])
    }

    // Catches silently dropping an explicitly selected query on profile drift.
    func testRemovedSelectedQueryIsRejected() throws {
        let original = try profile()
        let policy = try selection(["rpm"], profile: original)
        let reduced = try profile(queries: [original.diagnosticQueries[1]])

        XCTAssertThrowsError(try resolve(policy, profile: reduced)) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .unknownQueryID("rpm"))
        }
    }

    // Catches unrelated, unselected catalogue edits altering a valid selection.
    func testUnselectedDefinitionChangeDoesNotEnableOrReplaceQueries() throws {
        let original = try profile()
        let policy = try selection(["rpm"], profile: original)
        let changed = try profile(queries: [original.diagnosticQueries[0],
                                            query(id: "soc", command: "5678", service: .service22)])

        XCTAssertEqual(try resolve(policy, profile: changed), [original.diagnosticQueries[0]])
    }

    // Catches policy auto-inserting a configured bitmap the user did not select.
    func testSelectingPIDDoesNotAutomaticallySelectConfiguredBitmap() throws {
        let profile = try profile(queries: [query(id: "bitmap", command: "00"), query(id: "rpm", command: "0C")])
        let policy = try selection(["rpm"], profile: profile)

        XCTAssertEqual(try resolve(policy, profile: profile).map(\.id), ["rpm"])
    }

    // Catches presentation state leaking into selection or duplicating requests.
    // The same policy is resolved while real dashboard widgets/pages are edited.
    func testDashboardDuplicationAndRemovalDoNotChangeAcquisition() throws {
        let profile = try profile()
        let policy = try selection(["rpm", "rpm"], profile: profile)
        let widget = DashboardWidgetDefinition(
            id: "first", type: .numericGauge, signalID: "rpm.value",
            rect: DashboardRect(x: 0, y: 0, width: 20, height: 20), zIndex: 0,
            configuration: DashboardWidgetConfiguration(label: "RPM", unit: "rpm", decimals: 0,
                minimum: nil, maximum: nil, warningThreshold: nil, criticalThreshold: nil)
        )
        var page = DashboardPage(id: "first-page", name: "First", orientation: .portrait, widgets: [widget])
        try page.duplicateWidget(id: "first", newID: "second")
        XCTAssertEqual(page.widgets.map(\.signalID), ["rpm.value", "rpm.value"])
        XCTAssertEqual(try resolve(policy, profile: profile).map(\.id), ["rpm"])

        page = DashboardPage(id: "hidden-page", name: "Hidden", orientation: .landscape, widgets: [])
        XCTAssertTrue(page.widgets.isEmpty)
        XCTAssertEqual(try resolve(policy, profile: profile).map(\.id), ["rpm"])
    }

    // Catches sidecar restoration changing explicit none into all.
    func testEmptySelectionRoundTripPreservesNone() throws {
        let profile = try profile()
        let policy = try selection([], profile: profile)
        let restored = try JSONDecoder().decode(SignalAcquisitionPolicy.self, from: JSONEncoder().encode(policy))

        XCTAssertEqual(restored, policy)
        XCTAssertEqual(try resolve(restored, profile: profile), [])
    }

    // Catches restoration losing target/provenance/timing snapshots.
    func testSelectedPolicyRoundTripResolvesOriginalDefinitions() throws {
        let profile = try profile()
        let policy = try selection(["soc"], profile: profile)
        let restored = try JSONDecoder().decode(SignalAcquisitionPolicy.self, from: JSONEncoder().encode(policy))

        XCTAssertEqual(restored, policy)
        XCTAssertEqual(try resolve(restored, profile: profile), [profile.diagnosticQueries[1]])
    }

    // Catches JSONDecoder silently ignoring an imported timing override field.
    func testSerializedTimingOverrideIsRejected() throws {
        let policy = try selection(["rpm"], profile: profile())
        var object = try encodedObject(policy)
        object["timingOverrides"] = ["rpm": 0.01]

        XCTAssertThrowsError(try JSONDecoder().decode(SignalAcquisitionPolicy.self,
            from: JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .timingOverridesNotAllowed)
        }
    }

    // Catches changed snapshot timing being used as the executable definition.
    func testDecodedSnapshotCannotOverrideCurrentQueryTiming() throws {
        let profile = try profile()
        var object = try encodedObject(selection(["rpm"], profile: profile))
        var queries = try XCTUnwrap(object["selectedQueries"] as? [[String: Any]])
        queries[0]["pollInterval"] = 0.01
        object["selectedQueries"] = queries
        let restored = try JSONDecoder().decode(SignalAcquisitionPolicy.self,
            from: JSONSerialization.data(withJSONObject: object))

        XCTAssertThrowsError(try resolve(restored, profile: profile)) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .queryDefinitionChanged("rpm"))
        }
    }

    // Catches duplicate persisted definitions surviving validation.
    func testDecodedDuplicateDefinitionsAreRejected() throws {
        var object = try encodedObject(selection(["rpm"], profile: profile()))
        let queries = try XCTUnwrap(object["selectedQueries"] as? [[String: Any]])
        object["selectedQueries"] = queries + queries

        XCTAssertThrowsError(try JSONDecoder().decode(SignalAcquisitionPolicy.self,
            from: JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .invalidPolicy)
        }
    }

    // Catches accepting unknown schema/fields with ambiguous selection semantics.
    func testUnknownSchemaOrFieldIsRejected() throws {
        let policy = try selection(["rpm"], profile: profile())
        var object = try encodedObject(policy)
        object["schemaVersion"] = 99
        XCTAssertThrowsError(try JSONDecoder().decode(SignalAcquisitionPolicy.self,
            from: JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .unsupportedSchemaVersion(99))
        }
        object = try encodedObject(policy)
        object["enableNewQueries"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(SignalAcquisitionPolicy.self,
            from: JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .invalidPolicy)
        }
    }

    // Catches absent stable context/revision bindings being treated as defaults.
    func testBlankContextOrRevisionIsRejectedEvenForUnconfiguredPolicy() throws {
        let profile = try profile()
        XCTAssertThrowsError(try SignalAcquisitionPolicy.resolve(nil, profile: profile,
            localContextID: " \n", profileRevision: "revision-1")) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .invalidContextID)
        }
        XCTAssertThrowsError(try SignalAcquisitionPolicy.resolve(nil, profile: profile,
            localContextID: "local-A", profileRevision: "")) { error in
            XCTAssertEqual(error as? SignalAcquisitionPolicyError, .invalidProfileRevision)
        }
    }

    // Catches an explicit user action losing the before/after audit payload.
    func testExplicitSelectionProducesTypedChangeWithoutTransportWork() throws {
        let profile = try profile()
        let change = try SignalAcquisitionSelectionChange(previousPolicy: nil, selectedQueryIDs: [],
            profile: profile, localContextID: "local-A", profileRevision: "revision-1")

        XCTAssertEqual(change.action, .setSelection)
        XCTAssertEqual(change.previousQueryIDs, ["rpm", "soc"])
        XCTAssertEqual(change.selectedQueryIDs, [])
        XCTAssertNotNil(change.policy)
        XCTAssertEqual(change.localContextID, "local-A")
        XCTAssertEqual(change.profileID, "synthetic-profile")
    }

    // Catches resetting to defaults being persisted as a frozen explicit all.
    func testExplicitResetProducesDefaultPolicyAndRestoresConfiguredQueries() throws {
        let profile = try profile()
        let empty = try selection([], profile: profile)
        let change = try SignalAcquisitionSelectionChange(previousPolicy: empty, selectedQueryIDs: nil,
            profile: profile, localContextID: "local-A", profileRevision: "revision-1")

        XCTAssertEqual(change.action, .restoreProfileDefaults)
        XCTAssertEqual(change.previousQueryIDs, [])
        XCTAssertEqual(change.selectedQueryIDs, ["rpm", "soc"])
        XCTAssertNil(change.policy)
        XCTAssertEqual(try resolve(change.policy, profile: profile), profile.diagnosticQueries)
    }

    private func selection(_ ids: [String], profile: AdapterProfile) throws -> SignalAcquisitionPolicy {
        try SignalAcquisitionPolicy(queryIDs: ids, profile: profile,
            localContextID: "local-A", profileRevision: "revision-1")
    }

    private func resolve(_ policy: SignalAcquisitionPolicy?, profile: AdapterProfile) throws -> [OBDQueryDefinition] {
        try SignalAcquisitionPolicy.resolve(policy, profile: profile,
            localContextID: "local-A", profileRevision: "revision-1")
    }

    private func encodedObject(_ policy: SignalAcquisitionPolicy) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
    }

    private func profile(id: String = "synthetic-profile", queries: [OBDQueryDefinition]? = nil) throws -> AdapterProfile {
        try AdapterProfile(id: id, name: "Synthetic acquisition fixture", transport: .wifi,
            peripheralID: nil, serviceUUID: nil, writeCharacteristicUUID: nil, notifyCharacteristicUUID: nil,
            host: "127.0.0.1", port: 1, signals: [], diagnosticQueries: queries ?? [
                query(id: "rpm", command: "0C", pollInterval: 0.2, timeout: 1.5),
                query(id: "soc", command: "1234", service: .service22, pollInterval: 1.0, timeout: 2.0)
            ])
    }

    private func query(id: String, command: String, service: OBDService = .mode01,
                       pollInterval: Double = 0.5, timeout: Double = 2.0) throws -> OBDQueryDefinition {
        let signal = try OBDSignalDefinition(id: id + ".value", name: id, startBit: 0, bitLength: 8,
            byteOrder: .intel, isSigned: false, factor: 1, offset: 0, minimum: nil, maximum: nil,
            unit: "synthetic", timeout: 3)
        return try OBDQueryDefinition(id: id, name: id, requestCANID: 0x700, responseCANID: 0x708,
            isExtended: false, service: service, command: command, pollInterval: pollInterval,
            timeout: timeout, flowControl: true, sourceRepository: "synthetic acquisition tests",
            sourcePath: "fixtures/selection", sourceCommit: "fixture-v1", signals: [signal])
    }
}
