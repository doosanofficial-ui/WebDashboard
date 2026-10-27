import Foundation
import XCTest
@testable import TelemetryCore

final class DiagnosticWorkspaceSettingsTests: XCTestCase {
    // Catches a new install inventing an active vehicle/context or explicit none.
    func testUnconfiguredSettingsHaveNoActiveContextAndDefaultPolicy() throws {
        let settings = DiagnosticWorkspaceSettings()

        XCTAssertEqual(settings.contexts, [])
        XCTAssertNil(settings.selectedContextID)
        XCTAssertNil(settings.activeContext)
        XCTAssertNil(try settings.activePolicy(profileID: "profile-1"))
    }

    // Catches adding a context mutating an already published value or selecting it implicitly.
    func testAddingContextReturnsNewValueWithoutSelectingIt() throws {
        let original = DiagnosticWorkspaceSettings()
        let updated = try original.addingContext(context("ctx-A", "Local A"))

        XCTAssertTrue(original.contexts.isEmpty)
        XCTAssertEqual(updated.contexts.map(\.id), ["ctx-A"])
        XCTAssertNil(updated.selectedContextID)
        XCTAssertNil(try updated.policy(localContextID: "ctx-A", profileID: "profile-1"))
    }

    // Catches normalizing opaque IDs or leaving accidental surrounding name whitespace.
    func testContextPreservesOpaqueIDAndTrimsDisplayName() throws {
        let context = try context(" ctx-A ", "  로컬 차량 A \n")

        XCTAssertEqual(context.id, " ctx-A ")
        XCTAssertEqual(context.name, "로컬 차량 A")
    }

    // Catches unknown context selection falling back to default acquisition silently.
    func testSelectingUnknownContextRejectsWithoutChangingOriginal() throws {
        let original = try workspace(selected: "ctx-A")

        XCTAssertThrowsError(try original.selectingContext(id: "missing")) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .unknownContextID("missing"))
        }
        XCTAssertEqual(original.selectedContextID, "ctx-A")
    }

    // Catches selected-context lookup leaking A's policy into B.
    func testSelectingContextsReturnsOnlyTheirOwnPolicy() throws {
        let a = try policy(contextID: "ctx-A", ids: [])
        let b = try policy(contextID: "ctx-B", ids: ["query"])
        let original = try workspace(selected: "ctx-A", policies: [
            "ctx-A": ["profile-1": a], "ctx-B": ["profile-1": b]
        ])
        let selectedB = try original.selectingContext(id: "ctx-B")

        XCTAssertEqual(try original.activePolicy(profileID: "profile-1")?.selectedQueryIDs, [])
        XCTAssertEqual(try selectedB.activePolicy(profileID: "profile-1")?.selectedQueryIDs, ["query"])
        XCTAssertEqual(selectedB.activeContext?.name, "Local B")
        XCTAssertEqual(original.selectedContextID, "ctx-A")
    }

    // Catches clearing the active context deleting the saved per-context selection.
    func testClearingActiveContextRestoresDefaultWithoutDeletingStoredPolicy() throws {
        let a = try policy(contextID: "ctx-A", ids: [])
        let original = try workspace(selected: "ctx-A", policies: ["ctx-A": ["profile-1": a]])
        let inactive = try original.selectingContext(id: nil)

        XCTAssertNil(inactive.activeContext)
        XCTAssertNil(try inactive.activePolicy(profileID: "profile-1"))
        XCTAssertEqual(try inactive.policy(localContextID: "ctx-A", profileID: "profile-1"), a)
    }

    // Catches duplicate context IDs overwriting a different context's policy namespace.
    func testDuplicateContextIDsAreRejected() throws {
        XCTAssertThrowsError(try DiagnosticWorkspaceSettings(contexts: [
            context("ctx-A", "First"), context("ctx-A", "Second")
        ], selectedContextID: nil)) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .duplicateContextID("ctx-A"))
        }
    }

    // Catches names that differ only by case/whitespace creating ambiguous context choices.
    func testDuplicateContextNamesAreRejectedAfterTrimmingAndCaseFolding() throws {
        XCTAssertThrowsError(try DiagnosticWorkspaceSettings(contexts: [
            context("ctx-A", "Local A"), context("ctx-B", " local a ")
        ], selectedContextID: nil)) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .duplicateContextName("local a"))
        }
    }

    // Catches blank context identifiers or unusable display names being persisted.
    func testBlankContextIDAndNameAreRejected() throws {
        XCTAssertThrowsError(try context(" \n", "Name")) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .invalidContextID)
        }
        XCTAssertThrowsError(try context("ctx-A", " \n")) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .invalidContextName)
        }
    }

    // Catches constructor/decode accepting a dangling selected-context reference.
    func testUnknownSelectedContextIsRejectedByConstructor() throws {
        XCTAssertThrowsError(try DiagnosticWorkspaceSettings(contexts: [context("ctx-A", "Local A")],
            selectedContextID: "missing")) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .unknownContextID("missing"))
        }
    }

    // Catches a failed add changing source state before validation completes.
    func testFailedAddLeavesOriginalValueUnchanged() throws {
        let original = try workspace(selected: "ctx-A")
        let before = try JSONEncoder().encode(original)

        XCTAssertThrowsError(try original.addingContext(context("ctx-C", "LOCAL A")))
        XCTAssertEqual(original.contexts.map(\.id), ["ctx-A", "ctx-B"])
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticWorkspaceSettings.self, from: before), original)
    }

    // Catches replacement discarding another profile or context's saved policy.
    func testReplacingPolicyChangesOnlyRequestedContextAndProfile() throws {
        let a = try policy(contextID: "ctx-A", ids: ["query"])
        let aOther = try policy(contextID: "ctx-A", profileID: "profile-2", ids: [])
        let b = try policy(contextID: "ctx-B", ids: ["query"])
        let original = try workspace(selected: "ctx-A", policies: [
            "ctx-A": ["profile-1": a, "profile-2": aOther], "ctx-B": ["profile-1": b]
        ])
        let replacement = try policy(contextID: "ctx-A", ids: [])
        let updated = try original.replacingPolicy(replacement, localContextID: "ctx-A", profileID: "profile-1")

        XCTAssertEqual(try updated.activePolicy(profileID: "profile-1")?.selectedQueryIDs, [])
        XCTAssertEqual(try updated.policy(localContextID: "ctx-A", profileID: "profile-2"), aOther)
        XCTAssertEqual(try updated.policy(localContextID: "ctx-B", profileID: "profile-1"), b)
        XCTAssertEqual(try original.activePolicy(profileID: "profile-1")?.selectedQueryIDs, ["query"])
    }

    // Catches nil/default being encoded as explicit none or removing unrelated policies.
    func testReplacingPolicyWithNilRestoresOnlyThatBindingToDefault() throws {
        let a = try policy(contextID: "ctx-A", ids: [])
        let b = try policy(contextID: "ctx-B", ids: [])
        let original = try workspace(selected: "ctx-A", policies: [
            "ctx-A": ["profile-1": a], "ctx-B": ["profile-1": b]
        ])
        let updated = try original.replacingPolicy(nil, localContextID: "ctx-A", profileID: "profile-1")

        XCTAssertNil(try updated.activePolicy(profileID: "profile-1"))
        XCTAssertNil(updated.acquisitionPolicies["ctx-A"]?["profile-1"])
        XCTAssertEqual(try updated.policy(localContextID: "ctx-B", profileID: "profile-1"), b)
        XCTAssertEqual(updated.contexts, original.contexts)
        XCTAssertEqual(updated.selectedContextID, "ctx-A")
    }

    // Catches authorizing A's query snapshot under B's storage key.
    func testPolicyContextMismatchRejectsReplacement() throws {
        let original = try workspace()
        let a = try policy(contextID: "ctx-A", ids: [])

        XCTAssertThrowsError(try original.replacingPolicy(a, localContextID: "ctx-B", profileID: "profile-1")) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .policyContextMismatch)
        }
        XCTAssertTrue(original.acquisitionPolicies.isEmpty)
    }

    // Catches reusing a valid policy for a different profile key.
    func testPolicyProfileMismatchRejectsReplacement() throws {
        let original = try workspace()
        let a = try policy(contextID: "ctx-A", ids: [])

        XCTAssertThrowsError(try original.replacingPolicy(a, localContextID: "ctx-A", profileID: "profile-2")) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .policyProfileMismatch)
        }
    }

    // Catches an unknown-context policy map surviving constructor validation.
    func testUnknownPolicyContextIsRejectedEvenWithoutActiveContext() throws {
        let policy = try policy(contextID: "missing", ids: [])

        XCTAssertThrowsError(try workspace(policies: ["missing": ["profile-1": policy]])) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .unknownContextID("missing"))
        }
    }

    // Catches checking only policies while allowing an unknown empty namespace.
    func testUnknownEmptyPolicyContextMapIsRejected() throws {
        XCTAssertThrowsError(try workspace(policies: ["missing": [:]])) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .unknownContextID("missing"))
        }
    }

    // Catches nil replacement silently accepting an invalid context/reference.
    func testUnknownContextAndBlankProfileAreRejectedForPolicyOperations() throws {
        let settings = try workspace()
        XCTAssertThrowsError(try settings.replacingPolicy(nil, localContextID: "missing", profileID: "profile-1")) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .unknownContextID("missing"))
        }
        XCTAssertThrowsError(try settings.policy(localContextID: "missing", profileID: "profile-1")) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .unknownContextID("missing"))
        }
        XCTAssertThrowsError(try settings.replacingPolicy(nil, localContextID: "ctx-A", profileID: " \n")) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .invalidProfileID)
        }
        XCTAssertThrowsError(try settings.activePolicy(profileID: "")) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .invalidProfileID)
        }
    }

    // Catches Codable restoration turning explicit none into the default all.
    func testRoundTripPreservesExplicitNoneAndPerContextIsolation() throws {
        let a = try policy(contextID: "ctx-A", ids: [])
        let b = try policy(contextID: "ctx-B", ids: ["query"])
        let original = try workspace(selected: "ctx-A", policies: [
            "ctx-A": ["profile-1": a], "ctx-B": ["profile-1": b]
        ])
        let restored = try JSONDecoder().decode(DiagnosticWorkspaceSettings.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(restored, original)
        XCTAssertEqual(try restored.activePolicy(profileID: "profile-1")?.selectedQueryIDs, [])
        XCTAssertEqual(try restored.policy(localContextID: "ctx-B", profileID: "profile-1")?.selectedQueryIDs, ["query"])
        XCTAssertNil(try restored.policy(localContextID: "ctx-A", profileID: "not-configured"))
    }

    // Catches a nil active context becoming selected merely because it has saved policies.
    func testRoundTripPreservesNoActiveContextWithStoredPolicies() throws {
        let original = try workspace(policies: ["ctx-A": ["profile-1": policy(contextID: "ctx-A", ids: [])]])
        let restored = try JSONDecoder().decode(DiagnosticWorkspaceSettings.self, from: JSONEncoder().encode(original))

        XCTAssertNil(restored.selectedContextID)
        XCTAssertNil(try restored.activePolicy(profileID: "profile-1"))
        XCTAssertEqual(try restored.policy(localContextID: "ctx-A", profileID: "profile-1")?.selectedQueryIDs, [])
    }

    // Catches accepting unknown schema semantics or silently ignoring unknown settings fields.
    func testUnknownVersionAndTopLevelFieldAreRejected() throws {
        let settings = try workspace()
        var object = try encodedObject(settings)
        object["schemaVersion"] = 2
        XCTAssertThrowsError(try decode(object)) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .unsupportedSchemaVersion(2))
        }
        object = try encodedObject(settings)
        object["autoEnableQueries"] = true
        XCTAssertThrowsError(try decode(object)) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .invalidSettings)
        }
    }

    // Catches accepting malformed/unknown context fields or missing required schema fields.
    func testMalformedContextAndMissingRequiredFieldsAreRejected() throws {
        var object = try encodedObject(workspace())
        var contexts = try XCTUnwrap(object["contexts"] as? [[String: Any]])
        contexts[0]["vehicleVerified"] = true
        object["contexts"] = contexts
        XCTAssertThrowsError(try decode(object))

        object = try encodedObject(workspace())
        object.removeValue(forKey: "acquisitionPolicies")
        XCTAssertThrowsError(try decode(object))
        object = try encodedObject(workspace())
        object["selectedContextID"] = 123
        XCTAssertThrowsError(try decode(object))
    }

    // Catches decoding bypassing the constructor's cross-field policy binding checks.
    func testDecodedPolicyUnderDifferentContextKeyIsRejected() throws {
        let original = try workspace(policies: ["ctx-A": ["profile-1": policy(contextID: "ctx-A", ids: [])]])
        var object = try encodedObject(original)
        let maps = try XCTUnwrap(object["acquisitionPolicies"] as? [String: Any])
        object["acquisitionPolicies"] = ["ctx-B": try XCTUnwrap(maps["ctx-A"])]

        XCTAssertThrowsError(try decode(object)) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .policyContextMismatch)
        }
    }

    // Catches Codable bypassing whole-workspace uniqueness validation.
    func testDecodedDuplicateContextsAreRejected() throws {
        var object = try encodedObject(workspace())
        let contexts = try XCTUnwrap(object["contexts"] as? [[String: Any]])
        object["contexts"] = contexts + [try XCTUnwrap(contexts.first)]

        XCTAssertThrowsError(try decode(object)) { error in
            XCTAssertEqual(error as? DiagnosticWorkspaceSettingsError, .duplicateContextID("ctx-A"))
        }
    }

    private func context(_ id: String, _ name: String) throws -> DiagnosticWorkspaceSettings.Context {
        try DiagnosticWorkspaceSettings.Context(id: id, name: name)
    }

    private func workspace(selected: String? = nil,
                           policies: [String: [String: SignalAcquisitionPolicy]] = [:]) throws -> DiagnosticWorkspaceSettings {
        try DiagnosticWorkspaceSettings(contexts: [context("ctx-A", "Local A"), context("ctx-B", "Local B")],
            selectedContextID: selected, acquisitionPolicies: policies)
    }

    private func encodedObject(_ settings: DiagnosticWorkspaceSettings) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> DiagnosticWorkspaceSettings {
        try JSONDecoder().decode(DiagnosticWorkspaceSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func policy(contextID: String, profileID: String = "profile-1", ids: [String]) throws -> SignalAcquisitionPolicy {
        let signal = try OBDSignalDefinition(id: "signal", name: "Synthetic signal", startBit: 0, bitLength: 8,
            byteOrder: .intel, isSigned: false, factor: 1, offset: 0, minimum: nil, maximum: nil,
            unit: "synthetic", timeout: 2)
        let query = try OBDQueryDefinition(id: "query", name: "Synthetic query", requestCANID: 0x700,
            responseCANID: 0x708, isExtended: false, service: .mode01, command: "0C", pollInterval: 0.5,
            timeout: 2, flowControl: true, sourceRepository: "synthetic workspace settings tests",
            sourcePath: "fixtures/settings", sourceCommit: "fixture-1", signals: [signal])
        let profile = try AdapterProfile(id: profileID, name: "Synthetic profile", transport: .wifi,
            peripheralID: nil, serviceUUID: nil, writeCharacteristicUUID: nil, notifyCharacteristicUUID: nil,
            host: "127.0.0.1", port: 1, signals: [], diagnosticQueries: [query])
        return try SignalAcquisitionPolicy(queryIDs: ids, profile: profile,
            localContextID: contextID, profileRevision: "revision-1")
    }
}
