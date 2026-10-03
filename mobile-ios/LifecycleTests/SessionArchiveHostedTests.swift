import Foundation
import XCTest
import TelemetryCore
@testable import TelemetryLifecycleHost

final class SessionArchiveHostedTests: XCTestCase {
    @MainActor
    func testReplayMarksBelongToSelectedSessionAndStopClearsThem() async throws {
        let model = TelemetryModel.shared
        model.stopReplay()
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Telemetry")
        let path = root.appendingPathComponent("measurements.sqlite3")
        model.lastMarkAt = Date(timeIntervalSince1970: 999)
        for mark in [101.0, 202.0, nil] as [Double?] {
            let id = "mark-fixture-" + UUID().uuidString
            let recorder = try MeasurementRecorder(path: path, sessionID: id, startedAt: 100, mode: .demo)
            if let mark { try await recorder.append(.system(name: "MARK", timestamp: mark, monotonicNanos: 10)) }
            try await recorder.finish(endedAt: 300)
            model.selectedSavedSessionID = id
            await model.replaySelectedSession()
            XCTAssertEqual(model.lastMarkAt?.timeIntervalSince1970, mark)
        }
        model.stopReplay()
        XCTAssertNil(model.lastMarkAt)
        model.selectedSavedSessionID = nil
    }

    @MainActor
    func testRemoteEntryPointsAreDisabledWithoutChangingLocalState() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Offline host tests are Simulator-only")
        #else
        let model = TelemetryModel.shared
        XCTAssertEqual(Bundle.main.bundleIdentifier, "local.webdashboard.Telemetry.LifecycleHost")
        model.stopReplay()
        XCTAssertTrue(model.serverText.isEmpty)
        model.connect()
        XCTAssertEqual(model.connection, "Disconnected", "Local product must not enter the legacy server flow")
        model.restoreBackgroundSession()
        await model.flush(force: true)
        XCTAssertNil(model.uploader, "Local product must not initialize a background delivery session")
        XCTAssertFalse(model.credentialSaved)
        XCTAssertFalse(model.collecting)
        #endif
    }

    @MainActor
    func testEmptyServerLocalRecordingExportReplayAndMissingSessionRecovery() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Offline host tests are Simulator-only")
        #else
        XCTAssertEqual(Bundle.main.bundleIdentifier, "local.webdashboard.Telemetry.LifecycleHost")
        let model = TelemetryModel.shared
        model.stopReplay()
        XCTAssertTrue(model.serverText.isEmpty)
        XCTAssertFalse(model.credentialSaved)
        XCTAssertEqual(model.connection, "Disconnected")
        model.startRecording()
        XCTAssertTrue(model.localRecordingEnabled)
        model.mark()
        model.stopRecording()
        let recordingData = await model.exportMeasurementJSON()
        let recorded = try JSONDecoder().decode(MeasurementExport.self, from: XCTUnwrap(recordingData))
        XCTAssertNotNil(recorded.session.endedAt)
        XCTAssertTrue(recorded.measurements.contains { $0.kind == "SYSTEM" && $0.payloadJSON == "{\"name\":\"MARK\"}" })
        await model.refreshSavedSessions()
        model.selectedSavedSessionID = "missing-offline-session-" + UUID().uuidString
        let missing = await model.exportMeasurementJSON()
        XCTAssertNil(missing)
        await model.replaySelectedSession()
        XCTAssertEqual(model.runMode, .live)
        model.selectedSavedSessionID = recorded.session.sessionID
        let first = await model.exportMeasurementJSON()
        let second = await model.exportMeasurementJSON()
        XCTAssertEqual(try JSONDecoder().decode(MeasurementExport.self, from: XCTUnwrap(first)), recorded)
        XCTAssertEqual(try JSONDecoder().decode(MeasurementExport.self, from: XCTUnwrap(second)), recorded)
        await model.replaySelectedSession()
        XCTAssertEqual(model.runMode, .replay)
        model.stopReplay()
        XCTAssertEqual(model.runMode, .live)
        let after = await model.exportMeasurementJSON()
        XCTAssertEqual(try JSONDecoder().decode(MeasurementExport.self, from: XCTUnwrap(after)), recorded)
        XCTAssertFalse(model.collecting)
        XCTAssertEqual(model.connection, "Disconnected")
        XCTAssertTrue(model.bleDevices.isEmpty)
        model.selectedSavedSessionID = nil
        #endif
    }

    @MainActor
    func testSavedSessionExportAndReplayAreReadOnlyAndNeverAcquire() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Offline host tests are Simulator-only")
        #else
        let model = TelemetryModel.shared
        XCTAssertEqual(Bundle.main.bundleIdentifier, "local.webdashboard.Telemetry.LifecycleHost")
        model.stopReplay()
        XCTAssertFalse(model.localRecordingEnabled)
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Telemetry")
        let path = root.appendingPathComponent("measurements.sqlite3")
        let id = "archive-fixture-" + UUID().uuidString
        let recorder = try MeasurementRecorder(path: path, sessionID: id, startedAt: 100)
        let q = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let response = try OBDResponseParser.parse(
            "7EC 10 08 62 01 01 8F F3 FF\r7EC 21 EF 61 00 00 00 00 00\r>", for: q,
            receivedAtEpoch: 101, receivedAtMonotonicNanos: 10, sequence: 1,
            sourceAdapter: "recorded-fixture", sourceTransport: "fixture")
        let signal = try OBDSignalDecoder.decode(q.signals[0], response: response)
        try await recorder.append(contentsOf: [.diagnosticResponse(response), .diagnosticSignal(signal)])
        try await recorder.finish(endedAt: 102)
        await model.refreshSavedSessions()
        XCTAssertTrue(model.savedSessions.contains { $0.sessionID == id })
        model.selectedSavedSessionID = id
        let csv = await model.exportMeasurementCSV()
        XCTAssertTrue(String(decoding: try XCTUnwrap(csv), as: UTF8.self).contains("DIAGNOSTIC_SIGNAL"))
        let json = await model.exportMeasurementJSON()
        let envelope = try JSONDecoder().decode(MeasurementExport.self, from: XCTUnwrap(json))
        XCTAssertEqual(envelope.session.sessionID, id)
        XCTAssertEqual(envelope.measurements.count, 2)
        await model.replaySelectedSession()
        XCTAssertEqual(model.runMode, .replay)
        XCTAssertEqual(model.frame?.sig["SANTAFEHYB_HVBAT_SOC"], 48.5)
        XCTAssertEqual(model.localSignalReceivedAt["SANTAFEHYB_HVBAT_SOC"], 101)
        XCTAssertEqual(model.replayTimestamp, 101)
        XCTAssertEqual(model.canSource, "Replay")
        XCTAssertTrue(model.showingDiagnosticResponse)
        let depth = model.queueDepth
        model.startRecording()
        model.startLocation()
        model.startLiveAdapter()
        model.connect()
        model.mark()
        await model.flush(force: true)
        XCTAssertFalse(model.localRecordingEnabled)
        XCTAssertFalse(model.collecting)
        XCTAssertEqual(model.connection, "Disconnected")
        XCTAssertTrue(model.bleDevices.isEmpty)
        XCTAssertEqual(model.queueDepth, depth)
        let count = try await recorder.count()
        XCTAssertEqual(count, 2)
        model.stopReplay()
        XCTAssertNil(model.frame)
        XCTAssertNil(model.replayTimestamp)
        XCTAssertFalse(model.collecting)
        model.selectedSavedSessionID = id
        model.startRecording()
        XCTAssertNil(model.selectedSavedSessionID, "New recording must not export an older selected session")
        model.stopRecording()
        for _ in 0..<100 where model.localRecordingStatus == "Closing local recording" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.selectedSavedSessionID = nil
        #endif
    }

    @MainActor
    func testReplayModeCannotStartRecording() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Offline host tests are Simulator-only")
        #else
        let model = TelemetryModel.shared
        XCTAssertEqual(Bundle.main.bundleIdentifier, "local.webdashboard.Telemetry.LifecycleHost")
        XCTAssertFalse(model.localRecordingEnabled)
        model.runMode = .replay
        model.startRecording()
        XCTAssertFalse(model.localRecordingEnabled, "Viewing a recording must never open a new measurement session")
        if model.localRecordingEnabled {
            model.stopRecording()
            for _ in 0..<100 where model.localRecordingStatus == "Closing local recording" {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        model.runMode = .live
        #endif
    }
}
