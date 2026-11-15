import Foundation
import XCTest
@testable import TelemetryCore

final class OBDMeasurementPipelineTests: XCTestCase {
    func testCaptureDerivedSOCByteThroughFragmentedMockPipelineAndReplay() async throws {
        let transport = MockCANTransport()
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        // Only SOC byte 0x5B is retained from the private recorder snapshot.
        // Other fields/identifiers are masked and this single-frame envelope is
        // synthetic: it is not the original BLE/ELM wire or physical evidence.
        let chunks = ["7E", "C 08 62 01", " 01 00 00 00 00 5B\r>"]
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-derived-soc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("measurements.sqlite3")
        let recorder = try MeasurementRecorder(path: path,
            sessionID: "capture-derived-soc", startedAt: Date().timeIntervalSince1970, mode: .demo)
        let store = TelemetryStore()
        let session = OBDQuerySession(transport: transport,
            sourceAdapter: "capture-derived-fixture", sourceTransport: "mock")
        let pipeline = try OBDMeasurementPipeline(session: session, queries: [query],
            store: store, recorder: recorder)
        let responder = Task {
            var handled = 0
            while !Task.isCancelled {
                let writes = await transport.writes()
                while handled < writes.count {
                    let write = writes[handled]
                    handled += 1
                    if write == query.requestString {
                        for chunk in chunks { await transport.push(Data(chunk.utf8)) }
                    } else {
                        await transport.push(Data("OK\r>".utf8))
                    }
                }
                do { try await Task.sleep(nanoseconds: 1_000_000) }
                catch { return }
            }
        }
        var latest: LatestSignalState?
        do {
            try await pipeline.start()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(6))
            while clock.now < deadline {
                latest = await store.signalState(for: "SANTAFEHYB_HVBAT_SOC", now: Date().timeIntervalSince1970)
                if latest?.quality == .valid { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        } catch {
            await pipeline.stop()
            responder.cancel()
            await responder.value
            throw error
        }
        await pipeline.stop()
        responder.cancel()
        await responder.value
        try await recorder.finish(endedAt: Date().timeIntervalSince1970)

        // Fixed oracle: unsigned byte 91 divided by 2, independent of decoder output.
        XCTAssertEqual(latest?.rawValue, 91)
        XCTAssertEqual(latest?.value, 45.5)
        XCTAssertEqual(latest?.source, .diagnostic)
        let pipelineError = await pipeline.lastError
        XCTAssertNil(pipelineError)
        let exportData = try await recorder.exportSessionJSON()
        let exported = try JSONDecoder().decode(MeasurementExport.self, from: exportData)
        XCTAssertEqual(exported.session.mode, .demo)
        let responses = exported.measurements.filter { $0.kind == "DIAGNOSTIC_RESPONSE" }
        let decoded = exported.measurements.filter { $0.kind == "DIAGNOSTIC_SIGNAL" }
        XCTAssertFalse(responses.isEmpty)
        XCTAssertEqual(responses.count, decoded.count)
        for row in responses {
            let response = try JSONDecoder().decode(OBDResponse.self, from: Data(row.payloadJSON.utf8))
            XCTAssertEqual(response.payload, [0, 0, 0, 0, 0x5B])
            XCTAssertEqual(response.sourceTransport, "mock")
        }
        let archive = try MeasurementArchive(path: path)
        let reloaded = try await archive.load(sessionID: "capture-derived-soc")
        XCTAssertTrue(reloaded.session == exported.session && reloaded.measurements == exported.measurements,
            "An independent read-only connection must see the complete committed batch")
        let csv = try await archive.exportCSV(sessionID: "capture-derived-soc")
        XCTAssertTrue(String(decoding: csv, as: UTF8.self).contains("DIAGNOSTIC_SIGNAL"))
        let before = try await recorder.count()
        let replay = try await MeasurementReplay.snapshot(reloaded)
        XCTAssertEqual(replay.signals.first { $0.signalID == "SANTAFEHYB_HVBAT_SOC" }?.value, 45.5)
        let after = try await recorder.count()
        XCTAssertEqual(after, before, "Replay must not create another measurement")
    }

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
