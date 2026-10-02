import Foundation
import XCTest
@testable import TelemetryCore

final class OBDQuerySessionTests: XCTestCase {
    func testDiagnosticSessionEnablesTransmitFormattingBeforeReadOnlyQuery() async throws {
        let transport = MockCANTransport()
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let responder = Task {
            var handledWrites = 0
            var automaticFormatting = true
            while !Task.isCancelled {
                let writes = await transport.writes()
                while handledWrites < writes.count {
                    let write = writes[handledWrites]
                    handledWrites += 1
                    if write == "AT CAF0\r" {
                        automaticFormatting = false
                        await transport.push(Data("OK\r>".utf8))
                    } else if write == "AT CAF1\r" {
                        automaticFormatting = true
                        await transport.push(Data("OK\r>".utf8))
                    } else if write == query.requestString {
                        // ELM327DS p14: CAF0 does not add the ISO-TP PCI byte.
                        // This request contains only service/DID; H1 keeps raw response headers.
                        let reply = automaticFormatting
                            ? "7EC 08 62 01 01 00 00 00 00 64\r>"
                            : "NO DATA\r>"
                        await transport.push(Data(reply.utf8))
                    } else {
                        await transport.push(Data("OK\r>".utf8))
                    }
                }
                await Task.yield()
            }
        }
        defer { responder.cancel() }

        let session = OBDQuerySession(
            transport: transport,
            sourceAdapter: "NANICAR BT4N",
            sourceTransport: "ble"
        )
        try await session.start()
        let result = try await session.query(query)
        await session.stop()

        XCTAssertEqual(result.response.payload, [0, 0, 0, 0, 0x64])
        XCTAssertEqual(result.signals[0].value, 50)
        let stoppedState = await session.state
        XCTAssertEqual(stoppedState, .disconnected)

        let writes = await transport.writes()
        XCTAssertTrue(writes.contains("AT H1\r"))
        XCTAssertTrue(writes.contains("AT CAF1\r"))
        XCTAssertFalse(writes.contains("AT CAF0\r"))
        XCTAssertTrue(writes.contains("AT SH 7E4\r"))
        XCTAssertTrue(writes.contains("AT CRA 7EC\r"))
        XCTAssertTrue(writes.contains(query.requestString))
        XCTAssertFalse(writes.contains(where: { $0.contains("MA") }))
    }

    func testQuerySessionPropagatesNoDataWithoutInventingZero() async throws {
        let transport = MockCANTransport()
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let responder = Task {
            var handledWrites = 0
            while !Task.isCancelled {
                let writes = await transport.writes()
                while handledWrites < writes.count {
                    let write = writes[handledWrites]
                    handledWrites += 1
                    let reply = write == query.requestString ? "NO DATA\r>" : "OK\r>"
                    await transport.push(Data(reply.utf8))
                }
                await Task.yield()
            }
        }
        defer { responder.cancel() }

        let session = OBDQuerySession(transport: transport)
        try await session.start()
        do {
            _ = try await session.query(query)
            XCTFail("NO DATA must not produce a numeric value")
        } catch let error as OBDQuerySessionError {
            XCTAssertEqual(error, .response(.noData))
        }
        let readyState = await session.state
        XCTAssertEqual(readyState, .ready)
        await session.stop()
    }

    func testDiagnosticSessionTimeoutTransitionsToRecovering() async throws {
        let transport = MockCANTransport()
        let query = try shortQuery()
        let responder = Task {
            var handledWrites = 0
            while !Task.isCancelled {
                let writes = await transport.writes()
                while handledWrites < writes.count {
                    let write = writes[handledWrites]
                    handledWrites += 1
                    if write != query.requestString {
                        await transport.push(Data("OK\r>".utf8))
                    }
                }
                await Task.yield()
            }
        }
        defer { responder.cancel() }

        let session = OBDQuerySession(transport: transport)
        try await session.start()
        do {
            _ = try await session.query(query)
            XCTFail("A missing prompt must time out")
        } catch let error as OBDQuerySessionError {
            XCTAssertEqual(error, .timeout)
        }
        let recoveryState = await session.state
        XCTAssertEqual(recoveryState, .recovering)
        await session.stop()
    }

    func testDiagnosticSessionTreatsBufferFullAsRecoveryError() async throws {
        let transport = MockCANTransport()
        let query = try shortQuery()
        let responder = Task {
            var handledWrites = 0
            while !Task.isCancelled {
                let writes = await transport.writes()
                while handledWrites < writes.count {
                    let write = writes[handledWrites]
                    handledWrites += 1
                    await transport.push(Data((write == query.requestString ? "BUFFER FULL\r>" : "OK\r>").utf8))
                }
                await Task.yield()
            }
        }
        defer { responder.cancel() }

        let session = OBDQuerySession(transport: transport)
        try await session.start()
        do {
            _ = try await session.query(query)
            XCTFail("BUFFER FULL must fail closed")
        } catch let error as OBDQuerySessionError {
            XCTAssertEqual(error, .bufferFull)
        }
        let recoveryState = await session.state
        XCTAssertEqual(recoveryState, .recovering)
        await session.stop()
    }

    func testStopCancelsPendingDiagnosticRequestWithoutWritingAgain() async throws {
        let transport = MockCANTransport()
        let query = try shortQuery()
        let responder = Task {
            var handledWrites = 0
            while !Task.isCancelled {
                let writes = await transport.writes()
                while handledWrites < writes.count {
                    let write = writes[handledWrites]
                    handledWrites += 1
                    if write != query.requestString {
                        await transport.push(Data("OK\r>".utf8))
                    }
                }
                await Task.yield()
            }
        }
        defer { responder.cancel() }

        let session = OBDQuerySession(transport: transport)
        try await session.start()
        let pending = Task { () -> OBDQuerySessionError in
            do {
                _ = try await session.query(query)
                return .invalidState
            } catch let error as OBDQuerySessionError {
                return error
            } catch {
                return .transport
            }
        }
        for _ in 0..<100 {
            if await transport.writes().contains(query.requestString) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await session.stop()

        let pendingError = await pending.value
        let stoppedState = await session.state
        XCTAssertEqual(pendingError, .disconnected)
        XCTAssertEqual(stoppedState, .disconnected)
    }

    private func shortQuery() throws -> OBDQueryDefinition {
        let signal = try OBDSignalDefinition(
            id: "short.signal",
            name: "Short signal",
            startBit: 0,
            bitLength: 8,
            byteOrder: .intel,
            isSigned: false,
            factor: 1,
            offset: 0,
            minimum: 0,
            maximum: 255,
            unit: "scalar",
            timeout: 0.1
        )
        return try OBDQueryDefinition(
            id: "short-query",
            name: "Short query",
            requestCANID: 0x7E4,
            responseCANID: 0x7EC,
            isExtended: false,
            service: .service22,
            command: "0101",
            pollInterval: 0.1,
            timeout: 0.1,
            flowControl: true,
            sourceRepository: "fixture",
            sourcePath: "fixture",
            sourceCommit: "fixture",
            signals: [signal]
        )
    }
}
