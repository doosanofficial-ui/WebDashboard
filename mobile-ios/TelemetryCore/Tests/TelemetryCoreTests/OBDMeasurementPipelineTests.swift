import Foundation
import XCTest
@testable import TelemetryCore

final class OBDMeasurementPipelineTests: XCTestCase {
    func testImmediateStopRepeatedlyCompletesAcceptedResponseSignalBatch() async throws {
        for _ in 0..<10 {
            try await testSchedulerPipelineFeedsStoreAndDurableRecorder()
        }
    }

    func testSchedulerPipelineFeedsStoreAndDurableRecorder() async throws {
        let transport = MockCANTransport()
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let responder = Task {
            var handledWrites = 0
            while !Task.isCancelled {
                let writes = await transport.writes()
                while handledWrites < writes.count {
                    let write = writes[handledWrites]
                    handledWrites += 1
                    let reply = write == query.requestString
                        ? "7EC 08 62 01 01 00 00 00 00 64\r>"
                        : "OK\r>"
                    await transport.push(Data(reply.utf8))
                }
                await Task.yield()
            }
        }
        defer { responder.cancel() }

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("measurement-pipeline-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "pipeline-session", startedAt: 90)
        let store = TelemetryStore()
        let session = OBDQuerySession(transport: transport, sourceAdapter: "NANICAR BT4N", sourceTransport: "ble")
        let pipeline = try OBDMeasurementPipeline(
            session: session,
            queries: [query],
            store: store,
            recorder: recorder
        )

        try await pipeline.start()
        var latest: LatestSignalState?
        for _ in 0..<200 {
            latest = await store.signalState(for: "SANTAFEHYB_HVBAT_SOC", now: 100)
            if latest?.quality == .valid { break }
            do {
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch {
                break
            }
        }
        async let firstStop: Void = pipeline.stop()
        async let secondStop: Void = pipeline.stop()
        _ = await (firstStop, secondStop)

        let pipelineError = await pipeline.lastError
        XCTAssertEqual(latest?.value, 50)
        XCTAssertEqual(latest?.source, .diagnostic)
        XCTAssertNil(pipelineError)
        let rows = try await recorder.export()
        XCTAssertEqual(rows.map(\.kind), ["DIAGNOSTIC_RESPONSE", "DIAGNOSTIC_SIGNAL"])
        if let signalRow = rows.dropFirst().first {
            XCTAssertTrue(signalRow.payloadJSON.contains("SANTAFEHYB_HVBAT_SOC"))
        }
    }
}
