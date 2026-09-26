import Foundation
import XCTest
@testable import TelemetryCore

final class ELM327SessionTests: XCTestCase {
    private func waitForWrites(_ count: Int, on transport: MockCANTransport) async throws {
        for _ in 0..<100 {
            if await transport.writes().count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected (count) transport writes, got \(await transport.writes().count)")
    }

    private func startMonitoring(_ session: ELM327Session, transport: MockCANTransport) async throws {
        let task = Task { try await session.start() }
        try await waitForWrites(1, on: transport)
        await transport.push(Data("OK\r>".utf8))
        try await waitForWrites(2, on: transport)
        await transport.push(Data("OK\r>".utf8))
        try await waitForWrites(3, on: transport)
        await transport.push(Data("OK\r>".utf8))
        try await task.value
    }

    func testInitializationOrdersAllowlistedCommandsAndEntersMonitoring() async throws {
        let transport = MockCANTransport()
        let session = ELM327Session(transport: transport)

        try await startMonitoring(session, transport: transport)

        let writes = await transport.writes()
        XCTAssertEqual(writes, [
            "AT H1\r", "AT CAF0\r", "AT CSM1\r", "AT MA\r"
        ])
        let state = await session.state
        XCTAssertEqual(state, .monitoring)
    }

    func testMonitoringDoesNotSendPeriodicCommandsAndParsesAFrame() async throws {
        let transport = MockCANTransport()
        let session = ELM327Session(transport: transport)
        try await startMonitoring(session, transport: transport)
        let stream = await session.frames()
        let received = Task<CANFrame?, Never> {
            for await frame in stream { return frame }
            return nil
        }

        await transport.push(Data("7E8 11 22 33\r".utf8))
        let frame = await received.value
        XCTAssertEqual(frame?.canID, 0x7E8)
        XCTAssertFalse(frame?.isExtended ?? true)
        XCTAssertEqual(frame?.payload, [0x11, 0x22, 0x33])
        try await Task.sleep(nanoseconds: 100_000_000)
        let writeCount = await transport.writes().count
        XCTAssertEqual(writeCount, 4)
    }

    func testMonitoringAcceptsDLCPrefixedClassicalCANFrame() async throws {
        let transport = MockCANTransport()
        let session = ELM327Session(transport: transport)
        try await startMonitoring(session, transport: transport)
        let stream = await session.frames()
        let received = Task<CANFrame?, Never> {
            for await frame in stream { return frame }
            return nil
        }

        await transport.push(Data("7E8 03 11 22 33\r".utf8))
        let frame = await received.value
        XCTAssertEqual(frame?.canID, 0x7E8)
        XCTAssertEqual(frame?.dlc, 3)
        XCTAssertEqual(frame?.payload, [0x11, 0x22, 0x33])
    }

    func testFragmentedPromptRepliesAreReassembledBeforeNextCommand() async throws {
        let transport = MockCANTransport()
        let session = ELM327Session(transport: transport)
        let task = Task { try await session.start() }

        try await waitForWrites(1, on: transport)
        await transport.push(Data("O".utf8))
        await transport.push(Data("K\r".utf8))
        await transport.push(Data(">".utf8))
        try await waitForWrites(2, on: transport)
        await transport.push(Data("OK\r>".utf8))
        try await waitForWrites(3, on: transport)
        await transport.push(Data("OK\r>".utf8))
        try await task.value
        let writes = await transport.writes()
        XCTAssertEqual(Array(writes.prefix(3)), ["AT H1\r", "AT CAF0\r", "AT CSM1\r"])
    }

    func testUnsupportedCommandFailsClosedBeforeMonitoring() async throws {
        let transport = MockCANTransport()
        let session = ELM327Session(transport: transport)
        let task = Task { try await session.start() }
        try await waitForWrites(1, on: transport)
        await transport.push(Data("?\r>".utf8))

        do {
            try await task.value
            XCTFail("Expected unsupported command failure")
        } catch let error as ELM327SessionError {
            XCTAssertEqual(error, .unsupportedCommand)
        }
        let state = await session.state
        XCTAssertEqual(state, .recovering)
        let writeCount = await transport.writes().count
        XCTAssertEqual(writeCount, 1)
    }

    func testBufferFullAndDisconnectBecomeRecoveringErrors() async throws {
        let transport = MockCANTransport()
        let session = ELM327Session(transport: transport)
        try await startMonitoring(session, transport: transport)

        await transport.push(Data("BUFFER FULL\r".utf8))
        try await Task.sleep(nanoseconds: 20_000_000)
        var state = await session.state
        XCTAssertEqual(state, .recovering)
        let firstError = await session.lastError
        XCTAssertEqual(firstError, .bufferFull)

        let secondTransport = MockCANTransport()
        let secondSession = ELM327Session(transport: secondTransport)
        try await startMonitoring(secondSession, transport: secondTransport)
        await secondTransport.finish()
        try await Task.sleep(nanoseconds: 20_000_000)
        state = await secondSession.state
        XCTAssertEqual(state, .recovering)
        let secondError = await secondSession.lastError
        XCTAssertEqual(secondError, .disconnected)
    }

    func testStopDuringInitializationReleasesPendingResponse() async throws {
        let transport = MockCANTransport()
        let session = ELM327Session(transport: transport)
        let startTask = Task { try await session.start() }
        try await waitForWrites(1, on: transport)

        await session.stop()

        do {
            try await startTask.value
            XCTFail("Expected initialization to be cancelled")
        } catch let error as ELM327SessionError {
            XCTAssertEqual(error, .disconnected)
        }
        let state = await session.state
        XCTAssertEqual(state, .disconnected)
    }
}
