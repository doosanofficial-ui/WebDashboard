import Foundation
import XCTest
@testable import TelemetryCore

final class CANMeasurementPipelineTests: XCTestCase {
    private func waitForWrites(_ count: Int, on transport: MockCANTransport) async throws {
        for _ in 0..<100 {
            if await transport.writes().count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected \(count) transport writes, got \(await transport.writes().count)")
    }

    private func definition() throws -> SignalDefinition {
        try SignalDefinition(
            id: "vehicle.speed",
            name: "Vehicle speed",
            canID: 0x123,
            isExtended: false,
            startBit: 0,
            bitLength: 8,
            byteOrder: .intel,
            isSigned: false,
            factor: 0.5,
            offset: 0,
            minimum: 0,
            maximum: 127.5,
            unit: "km/h",
            timeout: 0.5
        )
    }

    func testMockTransportRunsFrameThroughDecoderStoreAndRecorder() async throws {
        let transport = MockCANTransport()
        let session = ELM327Session(transport: transport, sourceAdapter: "recorded", sourceTransport: "mock")
        let store = TelemetryStore(signalTimeouts: ["vehicle.speed": 0.5])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("can-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try MeasurementRecorder(
            path: directory.appendingPathComponent("session.sqlite"),
            sessionID: "pipeline-session",
            startedAt: 90
        )
        let pipeline = try CANMeasurementPipeline(
            session: session,
            definitions: [definition()],
            store: store,
            recorder: recorder
        )

        let startTask = Task { try await pipeline.start() }
        try await waitForWrites(1, on: transport)
        await transport.push(Data("OK\r>".utf8))
        try await waitForWrites(2, on: transport)
        await transport.push(Data("OK\r>".utf8))
        try await waitForWrites(3, on: transport)
        await transport.push(Data("OK\r>".utf8))
        try await startTask.value

        await transport.push(Data("123 50\r".utf8))
        for _ in 0..<100 {
            if try await recorder.count() >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let state = await store.signalState(for: "vehicle.speed", now: Date().timeIntervalSince1970)
        XCTAssertEqual(state?.quality, .valid)
        XCTAssertEqual(state?.value, 40)
        let kinds = try await recorder.export().map(\.kind)
        XCTAssertEqual(kinds, ["CAN", "SIGNAL"])
        await pipeline.stop()
    }
}
