import Foundation
import XCTest
import TelemetryCore
@testable import TelemetryLifecycleHost

/// Uses the unchanged production import/editor entry points and real atomic
/// Foundation file writes. Never scans BLE or connects to a vehicle/server.
final class AdapterProfileHostedTests: XCTestCase {
    private enum FixtureError: Error { case unsafeHost, busy, invalidSetup }

    @MainActor
    private func withProfile(
        _ body: (TelemetryModel, URL, AdapterProfile, Data) throws -> Void
    ) throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Profile fault injection is Simulator-only")
        #else
        guard Bundle.main.bundleIdentifier == "local.webdashboard.Telemetry.LifecycleHost" else {
            throw FixtureError.unsafeHost
        }
        let model = TelemetryModel.shared
        guard model.serverText.isEmpty, !model.credentialSaved, !model.collecting,
              model.connection == "Disconnected", !model.localRecordingEnabled,
              model.localRecordingStatus != "Closing local recording" else { throw FixtureError.busy }
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Telemetry/adapter-profile.json")
        // Tests run only in the disposable host. Preserve any prior fixture
        // instead of deleting unrelated saved profile bytes on cleanup.
        let originalBytes = try? Data(contentsOf: url)
        let originalProfile = model.adapterProfile
        let originalTimeouts = model.localSignalTimeouts
        let originalStatus = model.adapterProfileStatus
        defer {
            if let originalBytes {
                try? originalBytes.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            model.adapterProfile = originalProfile
            model.localSignalTimeouts = originalTimeouts
            model.adapterProfileStatus = originalStatus
        }
        let profile = try makeProfile("fixture.original", timeout: 1)
        let bytes = try JSONEncoder().encode(profile)
        model.importAdapterProfile(bytes)
        guard model.adapterProfile == profile else { throw FixtureError.invalidSetup }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        try body(model, url, profile, bytes)
        #endif
    }

    private func makeSignal(_ id: String, timeout: Double) throws -> SignalDefinition {
        try SignalDefinition(id: id, name: id, canID: 0x123, isExtended: false,
            startBit: 0, bitLength: 8, byteOrder: .intel, isSigned: false,
            factor: 1, offset: 0, minimum: nil, maximum: nil, unit: "fixture", timeout: timeout)
    }

    private func makeProfile(_ id: String, timeout: Double, diagnostic: Bool = false) throws -> AdapterProfile {
        try AdapterProfile(id: id, name: id, transport: .wifi, peripheralID: nil,
            serviceUUID: nil, writeCharacteristicUUID: nil, notifyCharacteristicUUID: nil,
            host: "127.0.0.1", port: 35000, signals: [makeSignal(id, timeout: timeout)],
            diagnosticQueries: diagnostic ? [SantaFeMX5HybridQueryCatalog.hvBatterySOC()] : [])
    }

    private func withBlockedDestination(_ url: URL, _ body: (URL) throws -> Void) throws {
        let files = FileManager.default
        let backup = url.appendingPathExtension("fixture-" + UUID().uuidString)
        try files.moveItem(at: url, to: backup)
        defer {
            try? files.removeItem(at: url)
            try? files.moveItem(at: backup, to: url)
        }
        // A directory cannot be atomically replaced by a Data file. This is a
        // real filesystem failure, independent of root/runner chmod behavior.
        try files.createDirectory(at: url, withIntermediateDirectories: false)
        try body(backup)
    }

    @MainActor
    func testMalformedImportPreservesExistingProfileTimeoutsAndBytes() throws {
        try withProfile { model, url, profile, bytes in
            let timeouts = model.localSignalTimeouts
            model.importAdapterProfile(Data("{malformed".utf8))
            XCTAssertEqual(model.adapterProfile, profile)
            XCTAssertEqual(model.localSignalTimeouts, timeouts)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertFalse(model.adapterProfileStatus.hasPrefix("Profile loaded:"))
            XCTAssertNil(model.storageStatus)
        }
    }

    @MainActor
    func testUnsupportedSchemaPreservesExistingProfileTimeoutsAndBytes() throws {
        try withProfile { model, url, profile, bytes in
            let timeouts = model.localSignalTimeouts
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            json["schema_version"] = 999
            model.importAdapterProfile(try JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(model.adapterProfile, profile)
            XCTAssertEqual(model.localSignalTimeouts, timeouts)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertFalse(model.adapterProfileStatus.hasPrefix("Profile loaded:"))
        }
    }

    @MainActor
    func testFailedAtomicSavePreservesProfileAndAllowsSuccessfulRetry() throws {
        try withProfile { model, url, profile, bytes in
            let timeouts = model.localSignalTimeouts
            let replacement = try makeProfile("fixture.replacement", timeout: 9, diagnostic: true)
            let replacementBytes = try JSONEncoder().encode(replacement)
            try withBlockedDestination(url) { backup in
                model.importAdapterProfile(replacementBytes)
                XCTAssertEqual(model.adapterProfile, profile)
                XCTAssertEqual(model.localSignalTimeouts, timeouts)
                XCTAssertEqual(try Data(contentsOf: backup), bytes)
                XCTAssertFalse(model.adapterProfileStatus.hasPrefix("Profile loaded:"))
                XCTAssertNil(model.storageStatus, "Profile I/O failure must not poison local recording")
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            model.importAdapterProfile(replacementBytes)
            XCTAssertEqual(model.adapterProfile, replacement)
            XCTAssertEqual(try Data(contentsOf: url), replacementBytes)
        }
    }

    @MainActor
    func testSuccessfulReplacementPublishesPersistedRawAndDiagnosticConfiguration() throws {
        try withProfile { model, url, _, _ in
            let replacement = try makeProfile("fixture.replacement", timeout: 9, diagnostic: true)
            let bytes = try JSONEncoder().encode(replacement)
            model.importAdapterProfile(bytes)
            let saved = try JSONDecoder().decode(AdapterProfile.self, from: Data(contentsOf: url))
            XCTAssertEqual(saved, replacement)
            XCTAssertEqual(model.adapterProfile, saved)
            var expected = ["fixture.replacement": 9.0]
            for signal in replacement.diagnosticQueries.flatMap(\.signals) { expected[signal.id] = signal.timeout }
            XCTAssertEqual(model.localSignalTimeouts, expected)
            XCTAssertEqual(Set(model.availableSignalIDs), Set(expected.keys))
            XCTAssertTrue(model.adapterProfileStatus.hasPrefix("Profile loaded:"))
        }
    }

    @MainActor
    func testSignalEditorRejectedCatalogPreservesPreviousProfile() throws {
        try withProfile { model, url, profile, bytes in
            let timeouts = model.localSignalTimeouts
            XCTAssertFalse(model.replaceAdapterProfileSignals([]))
            XCTAssertEqual(model.adapterProfile, profile)
            XCTAssertEqual(model.localSignalTimeouts, timeouts)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    @MainActor
    func testSignalEditorFailedSavePreservesPreviousProfile() throws {
        try withProfile { model, url, profile, bytes in
            let timeouts = model.localSignalTimeouts
            try withBlockedDestination(url) { backup in
                XCTAssertFalse(model.replaceAdapterProfileSignals([try makeSignal("fixture.edit", timeout: 5)]))
                XCTAssertEqual(model.adapterProfile, profile)
                XCTAssertEqual(model.localSignalTimeouts, timeouts)
                XCTAssertEqual(try Data(contentsOf: backup), bytes)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
}
