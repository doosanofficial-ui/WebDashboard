import Foundation
import XCTest
import TelemetryCore
@testable import TelemetryLifecycleHost

final class DashboardPersistenceHostedTests: XCTestCase {
    private enum FixtureError: Error { case unsafeHost, busy, closeTimeout }

    @MainActor
    private func settle(_ model: TelemetryModel) async throws {
        model.stopRecording()
        for _ in 0..<200 {
            if !model.localRecordingEnabled && model.localRecordingStatus != "Closing local recording" { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw FixtureError.closeTimeout
    }

    @MainActor
    private func withDashboard(_ body: (TelemetryModel, URL, DashboardProfile, Data) async throws -> Void) async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dashboard storage fault injection is Simulator-only")
        #else
        guard Bundle.main.bundleIdentifier == "local.webdashboard.Telemetry.LifecycleHost" else {
            throw FixtureError.unsafeHost
        }
        let model = TelemetryModel.shared
        guard model.serverText.isEmpty, !model.credentialSaved, !model.collecting,
              model.connection == "Disconnected", !model.localRecordingEnabled,
              model.localRecordingStatus != "Closing local recording" else { throw FixtureError.busy }
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Telemetry/dashboard.json")
        let bytes = try Data(contentsOf: url)
        let original = try XCTUnwrap(model.dashboardProfile)
        let originalError = model.dashboardSaveError
        let originalStorageStatus = model.storageStatus
        defer {
            try? bytes.write(to: url, options: .atomic)
            model.dashboardProfile = original
            model.dashboardSaveError = originalError
            model.storageStatus = originalStorageStatus
        }
        XCTAssertNil(model.storageStatus)
        do {
            try await body(model, url, original, bytes)
            try await settle(model)
        } catch {
            try? await settle(model)
            throw error
        }
        #endif
    }

    private func withBlockedDestination(_ url: URL, _ body: (URL) throws -> Void) throws {
        let backup = url.appendingPathExtension("fixture-" + UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: backup)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(at: backup, to: url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try body(backup)
    }

    @MainActor
    func testStartupPreservesSavedCustomOverlapsAndOriginalFileBytes() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Saved-layout fixture is Simulator-only")
        #else
        guard Bundle.main.bundleIdentifier == "local.webdashboard.Telemetry.LifecycleHost" else { throw FixtureError.unsafeHost }
        let model = TelemetryModel.shared
        guard !model.collecting, !model.localRecordingEnabled, model.replayController.sessionID == nil else { throw FixtureError.busy }
        let originalURL = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Telemetry/dashboard.json")
        let originalProfile = model.dashboardProfile
        let originalError = model.dashboardSaveError
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("saved-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            model.restoreDashboardProfile(at: originalURL)
            model.dashboardProfile = originalProfile; model.dashboardSaveError = originalError
            try? FileManager.default.removeItem(at: directory)
        }
        for (name, identifiers, overlap) in [
            ("custom-overlap", ["custom-a", "custom-b"], true),
            ("built-in-overlap", ["ws-fl", "ws-fr"], true),
            ("existing-spaced-layout", ["ws-fl", "ws-fr"], false)
        ] {
            let widgets = identifiers.enumerated().map { index, id in
                DashboardWidgetDefinition(id: id, type: .numericGauge, signalID: "fixture",
                    rect: .init(x: overlap ? 0 : index * 2, y: 0, width: 2, height: 1), zIndex: 10 + index,
                    configuration: .init(label: "User custom label", unit: "%", decimals: 1,
                        minimum: 0, maximum: 100, warningThreshold: nil, criticalThreshold: nil))
            }
            let profile = try DashboardProfile(id: name, name: "Saved user layout", pages: [
                .init(id: "main", name: "Custom", orientation: .landscape, widgets: widgets)])
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
            json["fixture-preserved-extra-field"] = "Original formatting and extra metadata"
            let bytes = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            let url = directory.appendingPathComponent(name + ".json")
            try bytes.write(to: url)
            for _ in 0..<2 {
                model.restoreDashboardProfile(at: url)
                XCTAssertEqual(model.dashboardProfile, profile, "Startup cannot infer user intent from built-in IDs and overlapping rectangles")
                XCTAssertEqual(try Data(contentsOf: url), bytes, "Startup must not rewrite a saved profile")
            }
        }
        let unreadable = directory.appendingPathComponent("invalid-saved.json")
        let originalBytes = Data("{unreadable saved user fixture".utf8)
        try originalBytes.write(to: unreadable)
        model.restoreDashboardProfile(at: unreadable)
        XCTAssertEqual(try Data(contentsOf: unreadable), originalBytes, "Invalid saved data must remain available for recovery")
        XCTAssertNil(model.dashboardProfile)
        XCTAssertNotNil(model.dashboardSaveError)
        #endif
    }

    @MainActor
    func testDashboardSaveFailureDoesNotPoisonRecordingOrDiscardEdits() async throws {
        try await withDashboard { model, url, original, bytes in
            model.startRecording()
            XCTAssertTrue(model.localRecordingEnabled)
            model.mark()
            try withBlockedDestination(url) { backup in
                model.addDashboardPage()
                XCTAssertNil(model.storageStatus, "Layout save failure must not disable acquisition/MARK controls")
                XCTAssertNotNil(model.dashboardSaveError)
                XCTAssertEqual(model.dashboardProfile?.pages.count, original.pages.count + 1,
                               "Keep in-memory edits available for an explicit retry")
                XCTAssertEqual(try Data(contentsOf: backup), bytes)
            }
            model.mark()
            model.stopRecording()
            let exported = await model.exportMeasurementJSON()
            let data = try XCTUnwrap(exported)
            let session = try JSONDecoder().decode(MeasurementExport.self, from: data)
            let marks = session.measurements.filter { $0.payloadJSON == "{\"name\":\"MARK\"}" }
            XCTAssertEqual(marks.count, 2)
            XCTAssertNotNil(session.session.endedAt)
            XCTAssertEqual(try Data(contentsOf: url), bytes, "Failed save cannot silently persist the draft")
        }
    }

    @MainActor
    func testRetryPersistsDraftAndClearsOnlyDashboardError() async throws {
        try await withDashboard { model, url, _, bytes in
            try withBlockedDestination(url) { _ in
                model.addDashboardPage()
                XCTAssertNotNil(model.dashboardSaveError)
            }
            let draft = try XCTUnwrap(model.dashboardProfile)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            model.retryDashboardSave()
            let saved = try JSONDecoder().decode(DashboardProfile.self, from: Data(contentsOf: url))
            XCTAssertEqual(saved, draft)
            XCTAssertNil(model.dashboardSaveError)
            XCTAssertNil(model.storageStatus)
        }
    }

    @MainActor
    func testSuccessfulLayoutSaveCannotClearARealMeasurementStorageFailure() async throws {
        try await withDashboard { model, url, _, _ in
            model.storageStatus = "fixture: measurement storage unavailable"
            model.addDashboardPage()
            XCTAssertEqual(model.storageStatus, "fixture: measurement storage unavailable")
            XCTAssertNil(model.dashboardSaveError)
            let saved = try JSONDecoder().decode(DashboardProfile.self, from: Data(contentsOf: url))
            XCTAssertEqual(saved, model.dashboardProfile)
        }
    }
}
