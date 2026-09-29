import Foundation
import XCTest
@testable import TelemetryCore

final class MeasurementReplayTests: XCTestCase {
    func testExportedSessionReplaysIntoStoreWithoutTransportOrNewRows() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("measurement-replay-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "replay-session", startedAt: 90)
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let response = try OBDResponseParser.parse(
            "7EC 08 62 01 01 00 00 00 00 64\r",
            for: query,
            receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 1_000,
            sequence: 4,
            sourceAdapter: "NANICAR BT4N",
            sourceTransport: "ble"
        )
        let signal = try OBDSignalDecoder.decode(query.signals[0], response: response)
        let frame = try CANFrame(
            receivedAtEpoch: 101,
            receivedAtMonotonicNanos: 1_100,
            canID: 0x123,
            isExtended: false,
            dlc: 1,
            payload: [0x01],
            sourceAdapter: "fixture",
            sourceTransport: "replay",
            sequence: 8
        )
        try await recorder.append(.diagnosticResponse(response))
        try await recorder.append(.diagnosticSignal(signal))
        try await recorder.append(.can(frame: frame))
        let export = try await recorder.exportSessionJSON()

        let store = TelemetryStore()
        try await MeasurementReplay.replay(export, into: store)

        let latestDiagnostic = await store.signalState(for: signal.signalID, now: 100.1)
        XCTAssertEqual(latestDiagnostic?.value, 50)
        XCTAssertEqual(latestDiagnostic?.source, .diagnostic)
        let latestFrame = await store.latestFrame()
        XCTAssertEqual(latestFrame, frame)
    }
}
