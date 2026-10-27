import Foundation
import XCTest
@testable import TelemetryCore

final class DiagnosticAuditSessionTests: XCTestCase {
    func testSlowTerminalAuditCannotDelayTimeoutTransportCleanup() async throws {
        let original = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        value["timeout"] = 0.1
        value["pollInterval"] = 0.1
        let query = try JSONDecoder().decode(OBDQueryDefinition.self, from: JSONSerialization.data(withJSONObject: value))
        let terminal = expectation(description: "terminal sink suspended")
        let closed = expectation(description: "transport closed while sink is suspended")
        let transport = AuditTransport(query: query, holdWrite: true, closed: closed)
        let log = AuditEventLog(terminal: terminal)
        let session = try makeSession(transport, log: log)
        try await session.start()
        let pending = Task { () -> OBDQuerySessionError? in
            do { _ = try await session.query(query); return nil }
            catch let error as OBDQuerySessionError { return error }
            catch { return .invalidState }
        }
        await fulfillment(of: [terminal], timeout: 2)
        await fulfillment(of: [closed], timeout: 1)
        await log.release()
        let result = await pending.value
        XCTAssertEqual(result, .timeout)
        await session.stop()
    }

    func testSlowWriteFailureAuditCannotReplaceTransportErrorWithTimeout() async throws {
        let original = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        value["timeout"] = 0.1
        value["pollInterval"] = 0.1
        let query = try JSONDecoder().decode(OBDQueryDefinition.self, from: JSONSerialization.data(withJSONObject: value))
        let failed = expectation(description: "write-failed sink suspended")
        let transport = AuditTransport(query: query, failWrite: true)
        let log = AuditEventLog(failed: failed)
        let session = try makeSession(transport, log: log)
        try await session.start()
        let pending = Task { () -> OBDQuerySessionError? in
            do { _ = try await session.query(query); return nil }
            catch let error as OBDQuerySessionError { return error }
            catch { return .invalidState }
        }
        await fulfillment(of: [failed], timeout: 2)
        let result = await pending.value
        XCTAssertEqual(result, .transport, "The original write failure must win before audit delivery waits")
        await log.release()
        await session.stop()
    }

    func testAuditCountsOnlyServiceWriteAndPreservesResponseIdentity() async throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let transport = AuditTransport(query: query)
        let log = AuditEventLog()
        let session = try makeSession(transport, log: log)
        try await session.start()
        let result = try await session.query(query)
        await session.stop()
        let events = await log.events
        let attempt = try DiagnosticAuditAttempt.reconstruct(events: events)
        XCTAssertEqual(events.filter { $0.stage == .terminal }.count, 1)
        XCTAssertEqual(events.filter { $0.stage == .transportWriteStarted }.count, 1)
        XCTAssertEqual(events.filter { $0.stage == .transportWriteCompleted }.count, 1)
        XCTAssertEqual(attempt.terminalEvent?.terminalOutcome, .succeeded)
        XCTAssertEqual(attempt.terminalEvent?.responseSequence, result.response.sequence)
        XCTAssertEqual(attempt.query, query)
        let writes = await transport.writes
        XCTAssertEqual(writes.filter { $0 == query.requestString }.count, 1)
        XCTAssertTrue(writes.contains("AT SH 7E4\r"))
    }

    func testResponseBeforeWriteReturnKeepsOneTerminalAndLateCompletion() async throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let entered = expectation(description: "service write suspended after response")
        let completed = expectation(description: "late write completion observed")
        let transport = AuditTransport(query: query, holdWrite: true, respondBeforeReturn: true, entered: entered)
        let log = AuditEventLog(completed: completed)
        let session = try makeSession(transport, log: log)
        try await session.start()
        _ = try await session.query(query)
        await fulfillment(of: [entered], timeout: 2)
        let prefix = await log.events
        let terminal = try XCTUnwrap(prefix.first { $0.stage == .terminal })
        XCTAssertEqual(terminal.terminalOutcome, .succeeded)
        XCTAssertEqual(terminal.writeDispositionAtTermination, .inFlight)
        await transport.release()
        await fulfillment(of: [completed], timeout: 2)
        await session.stop()
        let events = await log.events
        XCTAssertEqual(events.filter { $0.stage == .terminal }.count, 1)
        XCTAssertEqual(events.last?.stage, .transportWriteCompleted)
        XCTAssertGreaterThan(events.last!.ordinal, terminal.ordinal)
        _ = try DiagnosticAuditAttempt.reconstruct(events: events)
    }

    func testStopWhileQueuedSinkWaitsPreventsServiceWrite() async throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let queued = expectation(description: "queued sink suspended")
        let transport = AuditTransport(query: query)
        let log = AuditEventLog(queued: queued)
        let session = try makeSession(transport, log: log)
        try await session.start()
        let pending = Task { try await session.query(query) }
        await fulfillment(of: [queued], timeout: 2)
        await session.stop()
        await log.release()
        do { _ = try await pending.value; XCTFail("Stopped query must not succeed") } catch { }
        let writes = await transport.writes
        XCTAssertFalse(writes.contains(query.requestString))
        let events = await log.events
        let attempt = try DiagnosticAuditAttempt.reconstruct(events: events)
        XCTAssertEqual(events.filter { $0.stage == .terminal }.count, 1)
        XCTAssertEqual(attempt.terminalEvent?.terminalOutcome, .cancelled)
        XCTAssertEqual(attempt.terminalEvent?.writeDispositionAtTermination, .notAttempted)
    }

    func testStopDuringTransportWritePreservesIndeterminateEvidenceWithoutSecondTerminal() async throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let entered = expectation(description: "service write suspended")
        let transport = AuditTransport(query: query, holdWrite: true, entered: entered)
        let log = AuditEventLog()
        let session = try makeSession(transport, log: log)
        try await session.start()
        let pending = Task { try await session.query(query) }
        await fulfillment(of: [entered], timeout: 2)
        await session.stop()
        do { _ = try await pending.value; XCTFail("Stopped query must not succeed") } catch { }
        let events = await log.events
        let attempt = try DiagnosticAuditAttempt.reconstruct(events: events)
        XCTAssertEqual(events.filter { $0.stage == .terminal }.count, 1)
        XCTAssertEqual(attempt.terminalEvent?.terminalOutcome, .cancelled)
        XCTAssertEqual(events.filter { $0.stage == .transportWriteFailed }.count, 1)
        XCTAssertEqual(attempt.currentWriteDisposition, .indeterminate)
        let writes = await transport.writes
        XCTAssertEqual(writes.filter { $0 == query.requestString }.count, 1)
    }

    func testNoDataRecordsFailureWithoutInventingResponseOrSupport() async throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let transport = AuditTransport(query: query, response: "NO DATA\r>")
        let log = AuditEventLog()
        let session = try makeSession(transport, log: log)
        try await session.start()
        do { _ = try await session.query(query); XCTFail("NO DATA") }
        catch let error as OBDQuerySessionError { XCTAssertEqual(error, .response(.noData)) }
        await session.stop()
        let events = await log.events
        let terminal = try XCTUnwrap(events.first { $0.stage == .terminal })
        XCTAssertEqual(terminal.terminalOutcome, .failed)
        XCTAssertEqual(terminal.reasonCode, "no_data")
        XCTAssertNil(terminal.responseSequence)
        XCTAssertEqual(events.filter { $0.stage == .terminal }.count, 1)
    }

    private func makeSession(_ transport: AuditTransport, log: AuditEventLog) throws -> OBDQuerySession {
        let context = try DiagnosticAuditContext(adapterProfileID: "fixture-profile",
            adapterProfileName: "Synthetic audit fixture", transport: "fixture", connectionID: UUID())
        return OBDQuerySession(transport: transport, auditContext: context,
            onAudit: { await log.append($0) })
    }
}

private actor AuditEventLog {
    private(set) var events: [DiagnosticAuditEvent] = []
    let queued: XCTestExpectation?
    let completed: XCTestExpectation?
    let failed: XCTestExpectation?
    let terminal: XCTestExpectation?
    var gate: CheckedContinuation<Void, Never>?
    init(queued: XCTestExpectation? = nil, completed: XCTestExpectation? = nil, failed: XCTestExpectation? = nil,
         terminal: XCTestExpectation? = nil) {
        self.queued = queued; self.completed = completed; self.failed = failed
        self.terminal = terminal
    }
    func append(_ event: DiagnosticAuditEvent) async {
        events.append(event)
        if event.stage == .transportWriteCompleted { completed?.fulfill() }
        if event.stage == .queued, let queued {
            await withCheckedContinuation { gate = $0; queued.fulfill() }
        }
        if event.stage == .transportWriteFailed, let failed {
            await withCheckedContinuation { gate = $0; failed.fulfill() }
        }
        if event.stage == .terminal, let terminal {
            await withCheckedContinuation { gate = $0; terminal.fulfill() }
        }
    }
    func release() { gate?.resume(); gate = nil }
}

private actor AuditTransport: CANTransport {
    let query: OBDQueryDefinition
    let holdWrite: Bool
    let respondBeforeReturn: Bool
    let entered: XCTestExpectation?
    let response: String
    let failWrite: Bool
    let closed: XCTestExpectation?
    private var notifiedClose = false
    private(set) var writes: [String] = []
    var gate: CheckedContinuation<Void, Error>?
    var incomingContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    init(query: OBDQueryDefinition, holdWrite: Bool = false, respondBeforeReturn: Bool = false,
         entered: XCTestExpectation? = nil, response: String = "7EC 08 62 01 01 00 00 00 00 64\r>", failWrite: Bool = false,
         closed: XCTestExpectation? = nil) {
        self.query = query; self.holdWrite = holdWrite; self.respondBeforeReturn = respondBeforeReturn
        self.entered = entered; self.response = response
        self.failWrite = failWrite
        self.closed = closed
    }
    func connect() async throws { }
    func incoming() async -> AsyncThrowingStream<Data, Error> {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(); incomingContinuation = pair.continuation
        return pair.stream
    }
    func write(_ data: Data) async throws {
        let command = String(decoding: data, as: UTF8.self); writes.append(command)
        guard command == query.requestString else { incomingContinuation?.yield(Data("OK\r>".utf8)); return }
        if failWrite { throw CANTransportError.writeFailed }
        if !holdWrite || respondBeforeReturn { incomingContinuation?.yield(Data(response.utf8)) }
        if holdWrite { try await withCheckedThrowingContinuation { gate = $0; entered?.fulfill() } }
    }
    func release() { gate?.resume(); gate = nil }
    func close() async {
        gate?.resume(throwing: CancellationError()); gate = nil
        incomingContinuation?.finish(); incomingContinuation = nil
        if !notifiedClose {
            notifiedClose = true
            closed?.fulfill()
        }
    }
}
