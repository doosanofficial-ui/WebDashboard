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
