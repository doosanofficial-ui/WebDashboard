import Foundation
import XCTest
import TelemetryCore
@testable import TelemetryLifecycleHost

@MainActor
final class ReplayNavigationHostedTests: XCTestCase {
    func testRecordedTimeNavigationClearsFutureStateAndNeverWritesOrAcquires() async throws {
        let model = TelemetryModel.shared
        model.stopReplay()
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Telemetry")
        let id = "navigation-fixture-" + UUID().uuidString
        let recorder = try MeasurementRecorder(path: root.appendingPathComponent("measurements.sqlite3"),
            sessionID: id, startedAt: 300, mode: .demo)
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        func response(_ byte: String, epoch: Double, mono: UInt64, seq: UInt64) throws -> OBDResponse {
            try OBDResponseParser.parse("7EC 10 08 62 01 01 8F F3 FF\r7EC 21 EF " + byte + " 00 00 00 00 00\r>",
                for: query, receivedAtEpoch: epoch, receivedAtMonotonicNanos: mono, sequence: seq,
                sourceAdapter: "invented-fixture", sourceTransport: "fixture")
        }
        let first = try response("61",epoch:301,mono:1_000_000_000,seq:1)
        let last = try response("6A",epoch:304,mono:4_000_000_000,seq:2)
        try await recorder.append(contentsOf:[.system(name:"recording_started",timestamp:300,monotonicNanos:0),
            .diagnosticResponse(first),.diagnosticSignal(try OBDSignalDecoder.decode(query.signals[0],response:first)),
            .system(name:"MARK",timestamp:302,monotonicNanos:2_000_000_000),
            .diagnosticResponse(last),.diagnosticSignal(try OBDSignalDecoder.decode(query.signals[0],response:last)),
            .location(.init(originalTimestamp:304.4,receivedAtEpoch:304.5,receivedAtMonotonicNanos:4_500_000_000,
                latitude:0,longitude:0,altitude:-30,speed:-1,course:-1,horizontalAccuracy:5,verticalAccuracy:-1))])
        try await recorder.finish(endedAt:305,terminalEvent:.system(name:"recording_stopped",timestamp:305,monotonicNanos:5_000_000_000))
        let before = try await recorder.exportSessionJSON()
        model.selectedSavedSessionID = id
        await model.replaySelectedSession()
        XCTAssertEqual(model.frame?.sig["SANTAFEHYB_HVBAT_SOC"],53)
        XCTAssertEqual(model.lastMarkAt?.timeIntervalSince1970,302)
        XCTAssertEqual(model.replayController.duration,5)
        XCTAssertNil(model.lastLocation?.data.spd)
        XCTAssertNil(model.lastLocation?.data.hdg)
        XCTAssertNil(model.lastLocation?.data.alt, "Invalid vertical accuracy must not label raw altitude as valid")
        await model.seekReplay(to:0)
        XCTAssertNil(model.frame)
        XCTAssertNil(model.lastMarkAt)
        XCTAssertNil(model.lastLocation)
        XCTAssertTrue(model.replayController.play(at: 100))
        await model.advanceReplayPlayback(at: 102.5)
        XCTAssertEqual(model.replayController.position, 2.5)
        XCTAssertEqual(model.frame?.sig["SANTAFEHYB_HVBAT_SOC"], 48.5)
        XCTAssertEqual(model.localSignalReceivedAt["SANTAFEHYB_HVBAT_SOC"], 301)
        XCTAssertFalse(model.localRecordingEnabled)
        XCTAssertFalse(model.collecting)
        model.pauseReplayPlayback()
        await model.advanceReplayPlayback(at: 104.5)
        XCTAssertEqual(model.replayController.position, 2.5)
        await model.seekReplay(to:2.5)
        XCTAssertEqual(model.frame?.sig["SANTAFEHYB_HVBAT_SOC"],48.5)
        XCTAssertEqual(model.lastMarkAt?.timeIntervalSince1970,302)
        XCTAssertEqual(model.localSignalReceivedAt["SANTAFEHYB_HVBAT_SOC"],301)
        XCTAssertEqual(model.replaySignalFreshness["SANTAFEHYB_HVBAT_SOC"],.unknown)
        await model.seekReplay(to:100)
        XCTAssertEqual(model.replayController.position,5)
        await model.seekReplay(to:.nan)
        XCTAssertEqual(model.replayController.position,5)
        XCTAssertEqual(model.frame?.sig["SANTAFEHYB_HVBAT_SOC"],53)
        await model.seekReplay(to:-100)
        XCTAssertEqual(model.replayController.position,0)
        XCTAssertNil(model.lastMarkAt)
        model.startLocation();model.startRecording();model.mark();model.connect();await model.flush(force:true)
        XCTAssertFalse(model.collecting)
        XCTAssertFalse(model.localRecordingEnabled)
        XCTAssertEqual(model.connection,"Disconnected")
        XCTAssertNil(model.uploader)
        model.stopReplay()
        XCTAssertNil(model.frame)
        XCTAssertNil(model.lastMarkAt)
        let after = try await recorder.exportSessionJSON()
        XCTAssertEqual(before,after, "Replay cannot alter its source recording")
        model.selectedSavedSessionID = nil
    }
}
