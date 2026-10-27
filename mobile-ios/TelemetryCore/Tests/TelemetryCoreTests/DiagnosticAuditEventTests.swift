import Foundation
import XCTest
@testable import TelemetryCore

final class DiagnosticAuditEventTests: XCTestCase {
    private func fixtureQuery(id: String? = nil) throws -> OBDQueryDefinition {
        let original = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        guard let id else { return original }
        return try OBDQueryDefinition(
            id: id,
            name: original.name,
            requestCANID: original.requestCANID,
            responseCANID: original.responseCANID,
            isExtended: original.isExtended,
            service: original.service,
            command: original.command,
            pollInterval: original.pollInterval,
            timeout: original.timeout,
            flowControl: original.flowControl,
            sourceRepository: original.sourceRepository,
            sourcePath: original.sourcePath,
            sourceCommit: original.sourceCommit,
            signals: original.signals
        )
    }

    private func fixtureContext(connectionID: UUID, vehicleContextID: String? = nil) throws -> DiagnosticAuditContext {
        try DiagnosticAuditContext(
            vehicleContextID: vehicleContextID,
            adapterProfileID: "synthetic-profile",
            adapterProfileName: "Synthetic profile",
            transport: "ble",
            connectionID: connectionID
        )
    }

    private func time(_ seconds: Double, _ nanos: UInt64) throws -> DiagnosticAuditTimestamp {
        try DiagnosticAuditTimestamp(epochSeconds: seconds, monotonicNanoseconds: nanos)
    }

    private func completedEvents(
        connectionID: UUID,
        attemptID: UUID,
        queryID: String = "replay-query",
        baseEpoch: Double = 900
    ) throws -> [DiagnosticAuditEvent] {
        let query = try fixtureQuery(id: queryID)
        let context = try fixtureContext(connectionID: connectionID)
        var ledger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try ledger.queued(query: query, context: context,
                              at: time(baseEpoch, 90_000), attemptID: attemptID)
        _ = try ledger.started(attemptID: attemptID, at: time(baseEpoch - 100, 91_000))
        _ = try ledger.transportWriteStarted(attemptID: attemptID, at: time(baseEpoch - 99, 92_000))
        _ = try ledger.transportWriteCompleted(attemptID: attemptID, at: time(baseEpoch - 98, 93_000))
        _ = try ledger.succeeded(
            attemptID: attemptID, responseSequence: 100,
            responseReceivedAt: time(baseEpoch - 97.5, 93_500),
            at: time(baseEpoch - 97, 94_000)
        )
        return try XCTUnwrap(ledger.snapshot().first).events
    }

    private func mutatedAudit(
        _ data: Data,
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var audit = try XCTUnwrap(root["diagnosticAudit"] as? [String: Any])
        try mutate(&audit)
        root["diagnosticAudit"] = audit
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func roundTrip(_ events: [DiagnosticAuditEvent]) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for event in events {
            let data = try encoder.encode(DiagnosticAuditSystemPayload(event: event))
            XCTAssertEqual(
                try decoder.decode(DiagnosticAuditSystemPayload.self, from: data).diagnosticAudit,
                event
            )
        }
    }

    func testWriteCompletionMayArriveAfterSuccessWithoutChangingTerminal() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let context = try fixtureContext(connectionID: connectionID)
        var ledger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))

        _ = try ledger.queued(
            query: query, context: context,
            at: DiagnosticAuditTimestamp(epochSeconds: 100, monotonicNanoseconds: 1_000),
            attemptID: attemptID
        )
        _ = try ledger.started(
            attemptID: attemptID,
            at: DiagnosticAuditTimestamp(epochSeconds: 101, monotonicNanoseconds: 2_000)
        )
        _ = try ledger.transportWriteStarted(
            attemptID: attemptID,
            at: DiagnosticAuditTimestamp(epochSeconds: 102, monotonicNanoseconds: 3_000)
        )

        let terminal = try XCTUnwrap(try ledger.succeeded(
            attemptID: attemptID,
            responseSequence: 7,
            responseReceivedAt: DiagnosticAuditTimestamp(epochSeconds: 102.5, monotonicNanoseconds: 3_500),
            at: DiagnosticAuditTimestamp(epochSeconds: 103, monotonicNanoseconds: 4_000)
        ))
        XCTAssertEqual(terminal.stage, .terminal)
        XCTAssertEqual(terminal.terminalOutcome, .succeeded)
        XCTAssertEqual(terminal.writeDispositionAtTermination, .inFlight)

        let lateWrite = try XCTUnwrap(try ledger.transportWriteCompleted(
            attemptID: attemptID,
            at: DiagnosticAuditTimestamp(epochSeconds: 104, monotonicNanoseconds: 5_000)
        ))
        XCTAssertEqual(lateWrite.stage, .transportWriteCompleted)

        let duplicate = try ledger.succeeded(
            attemptID: attemptID,
            responseSequence: 7,
            responseReceivedAt: DiagnosticAuditTimestamp(epochSeconds: 102.5, monotonicNanoseconds: 3_500),
            at: DiagnosticAuditTimestamp(epochSeconds: 105, monotonicNanoseconds: 6_000)
        )
        XCTAssertNil(duplicate, "a repeated success callback must not add another terminal event")

        do {
            _ = try ledger.failed(
                attemptID: attemptID, reasonCode: "timeout", reason: "late competing callback",
                at: DiagnosticAuditTimestamp(epochSeconds: 106, monotonicNanoseconds: 7_000)
            )
            XCTFail("a conflicting terminal outcome must be reported")
        } catch let error as DiagnosticAuditError {
            guard case .conflictingTerminal = error else { throw error }
            // The original success remains authoritative.
        }

        let attempt = try XCTUnwrap(ledger.snapshot().first)
        XCTAssertEqual(attempt.events.map(\.stage), [
            .queued, .started, .transportWriteStarted, .terminal, .transportWriteCompleted
        ])
        XCTAssertEqual(attempt.events.map(\.ordinal), [1, 2, 3, 4, 5])
        XCTAssertEqual(attempt.terminalEvent?.terminalOutcome, .succeeded)
        XCTAssertEqual(attempt.terminalEvent?.writeDispositionAtTermination, .inFlight,
                       "late transport evidence must not rewrite terminal-time certainty")
        XCTAssertNil(attempt.context.vehicleContextID,
                     "missing vehicle context remains unassigned and does not block collection")
        XCTAssertEqual(attempt.completedTransportWriteCount, 1)
        XCTAssertEqual(attempt.events.filter { $0.stage == .terminal }.count, 1)
    }

    func testCancellationBeforeTransportWriteKeepsZeroCompletedWrites() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
        let query = try fixtureQuery()
        let context = try fixtureContext(connectionID: connectionID)
        var ledger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try ledger.queued(query: query, context: context, at: time(200, 2_000), attemptID: attemptID)

        XCTAssertThrowsError(try ledger.succeeded(
            attemptID: attemptID, responseSequence: 1, responseReceivedAt: time(200.5, 2_500),
            at: time(201, 3_000)
        ), "success requires a recorded transport write start")

        let terminal = try XCTUnwrap(try ledger.cancelled(
            attemptID: attemptID, reasonCode: "cancelled_before_start", at: time(202, 4_000)
        ))
        XCTAssertEqual(terminal.terminalOutcome, .cancelled)
        XCTAssertEqual(terminal.writeDispositionAtTermination, .notAttempted)
        XCTAssertEqual(ledger.snapshot().first?.completedTransportWriteCount, 0)
        XCTAssertNil(try ledger.cancelled(
            attemptID: attemptID, reasonCode: "cancelled_before_start", at: time(203, 5_000)
        ))
        XCTAssertEqual(ledger.snapshot().first?.events.filter { $0.stage == .terminal }.count, 1)
    }

    func testThrownTransportWriteRemainsIndeterminateAndKeepsFailureReason() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let query = try fixtureQuery()
        let context = try fixtureContext(connectionID: connectionID)
        var ledger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try ledger.queued(query: query, context: context, at: time(300, 3_000), attemptID: attemptID)
        _ = try ledger.started(attemptID: attemptID, at: time(301, 4_000))
        _ = try ledger.transportWriteStarted(attemptID: attemptID, at: time(302, 5_000))
        let writeError = try XCTUnwrap(try ledger.transportWriteFailed(
            attemptID: attemptID, reasonCode: "transport", reason: "write returned an error",
            at: time(303, 6_000)
        ))
        XCTAssertEqual(writeError.stage, .transportWriteFailed)
        let terminal = try XCTUnwrap(try ledger.failed(
            attemptID: attemptID, reasonCode: "transport", reason: "write returned an error",
            at: time(304, 7_000)
        ))
        XCTAssertEqual(terminal.writeDispositionAtTermination, .indeterminate)
        XCTAssertEqual(terminal.reasonCode, "transport")
        XCTAssertEqual(terminal.reason, "write returned an error")
        XCTAssertEqual(ledger.snapshot().first?.completedTransportWriteCount, 0)
    }

    func testLedgerRejectsNonRoundTrippableInputsWithoutMutatingHistory() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let query = try fixtureQuery()
        let context = try fixtureContext(connectionID: connectionID)
        let blankFailureID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000301")!
        var blankFailureLedger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try blankFailureLedger.queued(
            query: query, context: context, at: time(100, 1_000), attemptID: blankFailureID
        )
        let beforeBlankTerminal = blankFailureLedger.snapshot()
        XCTAssertThrowsError(try blankFailureLedger.failed(
            attemptID: blankFailureID, reasonCode: "   ", at: time(101, 2_000)
        ))
        XCTAssertEqual(blankFailureLedger.snapshot(), beforeBlankTerminal)

        let blankWriteID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000302")!
        var blankWriteLedger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try blankWriteLedger.queued(
            query: query, context: context, at: time(200, 3_000), attemptID: blankWriteID
        )
        _ = try blankWriteLedger.started(attemptID: blankWriteID, at: time(201, 4_000))
        _ = try blankWriteLedger.transportWriteStarted(attemptID: blankWriteID, at: time(202, 5_000))
        let beforeBlankWrite = blankWriteLedger.snapshot()
        XCTAssertThrowsError(try blankWriteLedger.transportWriteFailed(
            attemptID: blankWriteID, reasonCode: " \n ", at: time(203, 6_000)
        ))
        XCTAssertEqual(blankWriteLedger.snapshot(), beforeBlankWrite)

        let futureResponseID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000303")!
        var futureResponseLedger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try futureResponseLedger.queued(
            query: query, context: context, at: time(300, 7_000), attemptID: futureResponseID
        )
        _ = try futureResponseLedger.started(attemptID: futureResponseID, at: time(301, 8_000))
        _ = try futureResponseLedger.transportWriteStarted(attemptID: futureResponseID, at: time(302, 9_000))
        let beforeFutureResponse = futureResponseLedger.snapshot()
        XCTAssertThrowsError(try futureResponseLedger.succeeded(
            attemptID: futureResponseID, responseSequence: 15,
            responseReceivedAt: time(304, 11_000), at: time(303, 10_000)
        ))
        XCTAssertEqual(futureResponseLedger.snapshot(), beforeFutureResponse)

        let validEvents = try completedEvents(
            connectionID: connectionID,
            attemptID: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000304")!
        )
        try roundTrip(validEvents)
    }

    func testRecordingWindowClosureDoesNotCloseLiveAcquisitionLedger() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!
        let recordingID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000003")!
        let query = try fixtureQuery()
        let context = try fixtureContext(connectionID: connectionID)
        var live = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        var recording = DiagnosticAuditLedger(scope: .recordingWindow(recordingID: recordingID))
        _ = try live.queued(query: query, context: context, at: time(400, 4_000), attemptID: attemptID)
        _ = try recording.queued(query: query, context: context, at: time(400, 4_000), attemptID: attemptID)
        _ = try live.started(attemptID: attemptID, at: time(401, 5_000))
        _ = try recording.started(attemptID: attemptID, at: time(401, 5_000))
        _ = try live.transportWriteStarted(attemptID: attemptID, at: time(402, 6_000))
        _ = try recording.transportWriteStarted(attemptID: attemptID, at: time(402, 6_000))

        let captureEnded = try XCTUnwrap(recording.closeRecordingWindow(at: time(403, 7_000)).first)
        XCTAssertEqual(captureEnded.terminalOutcome, .recordingWindowClosed)
        XCTAssertEqual(captureEnded.writeDispositionAtTermination, .inFlight)
        XCTAssertTrue(recording.isClosed)

        let lateCaptureWrite = try XCTUnwrap(try recording.transportWriteCompleted(
            attemptID: attemptID, at: time(404, 8_000)
        ))
        XCTAssertEqual(lateCaptureWrite.scope, .recordingWindow(recordingID: recordingID))
        XCTAssertEqual(recording.snapshot().first?.terminalEvent?.writeDispositionAtTermination, .inFlight)

        let liveSuccess = try XCTUnwrap(try live.succeeded(
            attemptID: attemptID, responseSequence: 9, responseReceivedAt: time(404.5, 8_500),
            at: time(405, 9_000)
        ))
        XCTAssertEqual(liveSuccess.scope, .acquisition(connectionID: connectionID))
        XCTAssertEqual(live.snapshot().first?.terminalEvent?.terminalOutcome, .succeeded)
        XCTAssertNil(live.snapshot().first?.terminalEvent?.reasonCode)
        XCTAssertThrowsError(try recording.queued(
            query: query, context: context, at: time(406, 10_000),
            attemptID: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000004")!
        ))
    }

    func testConnectionLossClosesOnlyItsGenerationAndRejectsLateTerminal() throws {
        let oldConnectionID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000004")!
        let newConnectionID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000005")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000005")!
        let query = try fixtureQuery()
        let oldContext = try fixtureContext(connectionID: oldConnectionID)
        var oldLedger = DiagnosticAuditLedger(scope: .acquisition(connectionID: oldConnectionID))
        _ = try oldLedger.queued(query: query, context: oldContext, at: time(500, 5_000), attemptID: attemptID)
        _ = try oldLedger.started(attemptID: attemptID, at: time(501, 6_000))
        _ = try oldLedger.transportWriteStarted(attemptID: attemptID, at: time(502, 7_000))
        let disconnected = try XCTUnwrap(oldLedger.connectionLost(oldConnectionID, at: time(503, 8_000)).first)
        XCTAssertEqual(disconnected.terminalOutcome, .failed)
        XCTAssertEqual(disconnected.reasonCode, "connection_lost")
        XCTAssertTrue(oldLedger.isClosed)
        XCTAssertThrowsError(try oldLedger.succeeded(
            attemptID: attemptID, responseSequence: 10, responseReceivedAt: time(504, 9_000),
            at: time(505, 10_000)
        ))

        let newContext = try fixtureContext(connectionID: newConnectionID)
        var newLedger = DiagnosticAuditLedger(scope: .acquisition(connectionID: newConnectionID))
        let newAttempt = try newLedger.queued(
            query: query, context: newContext, at: time(506, 11_000), attemptID: attemptID
        )
        XCTAssertEqual(newAttempt.scope, .acquisition(connectionID: newConnectionID))
        XCTAssertNotEqual(oldLedger.snapshot().first?.id, newLedger.snapshot().first?.id)
        XCTAssertEqual(oldLedger.snapshot().first?.terminalEvent?.reasonCode, "connection_lost")
    }

    func testTimeoutAndNoDataCodesSurviveOldSystemNameReaderRoundTrip() throws {
        struct LegacySystemPayload: Decodable { let name: String }

        let connectionID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000006")!
        let queryID = "query,:\"quoted\"\n診断🚗:05"
        let query = try fixtureQuery(id: queryID)
        let context = try fixtureContext(connectionID: connectionID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for (suffix, code) in [("1", "timeout"), ("2", "no_data")] {
            let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000\(suffix)")!
            var ledger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
            _ = try ledger.queued(query: query, context: context, at: time(600, 6_000), attemptID: attemptID)
            let terminal = try XCTUnwrap(try ledger.failed(
                attemptID: attemptID, reasonCode: code, reason: "ECU returned \(code)",
                at: time(601, 7_000)
            ))
            let bytes = try encoder.encode(DiagnosticAuditSystemPayload(event: terminal))
            let legacy = try JSONDecoder().decode(LegacySystemPayload.self, from: bytes)
            XCTAssertEqual(legacy.name, DiagnosticAuditSystemPayload.name)
            let decoded = try JSONDecoder().decode(DiagnosticAuditSystemPayload.self, from: bytes)
            XCTAssertEqual(decoded.diagnosticAudit, terminal)
            XCTAssertEqual(decoded.diagnosticAudit.query, query)
            XCTAssertEqual(decoded.diagnosticAudit.query.requestCANID, query.requestCANID)
            XCTAssertEqual(decoded.diagnosticAudit.query.responseCANID, query.responseCANID)
            XCTAssertEqual(decoded.diagnosticAudit.reasonCode, code)
            XCTAssertEqual(decoded.diagnosticAudit.reason, "ECU returned \(code)")
            XCTAssertNil(decoded.diagnosticAudit.context.vehicleContextID)
        }
    }

    func testLedgerOrdersByMonotonicClockEvenWhenWallClockMovesBackwards() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000099")!
        let query = try fixtureQuery()
        let context = try fixtureContext(connectionID: connectionID)
        var ledger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try ledger.queued(
            query: query, context: context,
            at: DiagnosticAuditTimestamp(epochSeconds: 900, monotonicNanoseconds: 90_000),
            attemptID: attemptID
        )
        _ = try ledger.started(
            attemptID: attemptID,
            at: DiagnosticAuditTimestamp(epochSeconds: 800, monotonicNanoseconds: 91_000)
        )
        XCTAssertThrowsError(try ledger.transportWriteStarted(
            attemptID: attemptID,
            at: DiagnosticAuditTimestamp(epochSeconds: 950, monotonicNanoseconds: 89_000)
        ))
        XCTAssertEqual(ledger.snapshot().first?.events.map(\.stage), [.queued, .started])
    }

    func testDecoderRejectsUnsupportedVersionInvalidOrdinalAndInconsistentPayloads() throws {
        XCTAssertThrowsError(try DiagnosticAuditTimestamp(epochSeconds: .infinity, monotonicNanoseconds: 0))

        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let query = try fixtureQuery()
        let context = try fixtureContext(connectionID: connectionID)
        var ledger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try ledger.queued(query: query, context: context, at: time(700, 7_000), attemptID: attemptID)
        _ = try ledger.started(attemptID: attemptID, at: time(701, 8_000))
        _ = try ledger.transportWriteStarted(attemptID: attemptID, at: time(702, 9_000))
        let terminal = try XCTUnwrap(try ledger.succeeded(
            attemptID: attemptID, responseSequence: 11, responseReceivedAt: time(702.5, 9_500),
            at: time(703, 10_000)
        ))
        let bytes = try JSONEncoder().encode(DiagnosticAuditSystemPayload(event: terminal))

        let queuedBytes = try JSONEncoder().encode(DiagnosticAuditSystemPayload(
            event: try XCTUnwrap(ledger.snapshot().first?.events.first)
        ))

        let invalidVariants = try [
            mutatedAudit(bytes) { $0["version"] = 2 },
            mutatedAudit(bytes) { $0["ordinal"] = 0 },
            mutatedAudit(bytes) { $0["ordinal"] = 33 },
            mutatedAudit(bytes) { $0["stage"] = DiagnosticAuditStage.queued.rawValue },
            mutatedAudit(bytes) { $0["terminalOutcome"] = DiagnosticAuditOutcome.recordingWindowClosed.rawValue },
            mutatedAudit(bytes) { $0.removeValue(forKey: "writeDispositionAtTermination") },
            mutatedAudit(bytes) { $0["writeDispositionAtTermination"] = DiagnosticAuditWriteDisposition.notAttempted.rawValue },
            mutatedAudit(bytes) { $0.removeValue(forKey: "responseSequence") },
            mutatedAudit(bytes) {
                var context = try XCTUnwrap($0["context"] as? [String: Any])
                context["adapterProfileID"] = ""
                $0["context"] = context
            }
        ]
        for invalid in invalidVariants {
            XCTAssertThrowsError(try JSONDecoder().decode(DiagnosticAuditSystemPayload.self, from: invalid))
        }
        let invalidQueued = try mutatedAudit(queuedBytes) { $0["ordinal"] = 2 }
        XCTAssertThrowsError(try JSONDecoder().decode(DiagnosticAuditSystemPayload.self, from: invalidQueued))

        let mismatchedScope = try mutatedAudit(bytes) { audit in
            var scope = try XCTUnwrap(audit["scope"] as? [String: Any])
            var acquisition = try XCTUnwrap(scope["acquisition"] as? [String: Any])
            acquisition["connectionID"] = UUID(uuidString: "FFFFFFFF-EEEE-DDDD-CCCC-BBBBBBBBBBBB")!.uuidString
            scope["acquisition"] = acquisition
            audit["scope"] = scope
        }
        XCTAssertThrowsError(try JSONDecoder().decode(DiagnosticAuditSystemPayload.self, from: mismatchedScope))

        var failedLedger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        let failedAttemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000100")!
        _ = try failedLedger.queued(
            query: query, context: context, at: time(710, 11_000), attemptID: failedAttemptID
        )
        let failed = try XCTUnwrap(try failedLedger.failed(
            attemptID: failedAttemptID,
            reasonCode: "timeout", reason: "No response", at: time(711, 12_000)
        ))
        let failedBytes = try JSONEncoder().encode(DiagnosticAuditSystemPayload(event: failed))
        let missingFailureCode = try mutatedAudit(failedBytes) { $0["reasonCode"] = "   " }
        XCTAssertThrowsError(try JSONDecoder().decode(DiagnosticAuditSystemPayload.self, from: missingFailureCode))

        let recordingID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000011")!
        let recordingAttemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000101")!
        var recordingLedger = DiagnosticAuditLedger(scope: .recordingWindow(recordingID: recordingID))
        _ = try recordingLedger.queued(
            query: query, context: context, at: time(720, 13_000), attemptID: recordingAttemptID
        )
        let recordingClosed = try XCTUnwrap(recordingLedger.closeRecordingWindow(at: time(721, 14_000)).first)
        let recordingBytes = try JSONEncoder().encode(DiagnosticAuditSystemPayload(event: recordingClosed))
        let captureTerminalInAcquisitionScope = try mutatedAudit(recordingBytes) { audit in
            audit["scope"] = ["acquisition": ["connectionID": connectionID.uuidString]]
        }
        XCTAssertThrowsError(try JSONDecoder().decode(DiagnosticAuditSystemPayload.self, from: captureTerminalInAcquisitionScope))
    }

    func testCompletedWriteHistoryIsPrunedWhilePendingAttemptAndDroppedCountRemainVisible() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let query = try fixtureQuery()
        let context = try fixtureContext(connectionID: connectionID)
        var ledger = DiagnosticAuditLedger(
            scope: .acquisition(connectionID: connectionID),
            completedAttemptHistoryLimit: 2
        )
        let pendingID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
        _ = try ledger.queued(query: query, context: context, at: time(800, 8_000), attemptID: pendingID)
        _ = try ledger.started(attemptID: pendingID, at: time(801, 9_000))
        _ = try ledger.transportWriteStarted(attemptID: pendingID, at: time(802, 10_000))
        _ = try ledger.succeeded(
            attemptID: pendingID, responseSequence: 12, responseReceivedAt: time(802.5, 10_500),
            at: time(803, 11_000)
        )

        let completedIDs = (2...4).map { UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000\($0)")! }
        for (offset, attemptID) in completedIDs.enumerated() {
            let base = Double(810 + offset * 10)
            _ = try ledger.queued(query: query, context: context, at: time(base, UInt64(base * 10)), attemptID: attemptID)
            _ = try ledger.started(attemptID: attemptID, at: time(base + 1, UInt64((base + 1) * 10)))
            _ = try ledger.transportWriteStarted(attemptID: attemptID, at: time(base + 2, UInt64((base + 2) * 10)))
            _ = try ledger.transportWriteCompleted(attemptID: attemptID, at: time(base + 3, UInt64((base + 3) * 10)))
            _ = try ledger.succeeded(
                attemptID: attemptID, responseSequence: UInt64(20 + offset),
                responseReceivedAt: time(base + 3.5, UInt64((base + 3) * 10 + 5)),
                at: time(base + 4, UInt64((base + 4) * 10))
            )
        }

        let retained = ledger.snapshot()
        XCTAssertEqual(ledger.droppedAttemptCount, 1)
        XCTAssertEqual(retained.map(\.attemptID), [pendingID, completedIDs[1], completedIDs[2]])
        XCTAssertEqual(retained.first?.terminalEvent?.writeDispositionAtTermination, .inFlight)
        XCTAssertTrue(retained.first?.isTerminal == true)
        XCTAssertEqual(retained.filter { $0.completedTransportWriteCount > 0 }.count, 2)
    }

    func testReplayReconstructsSQLiteOrderWithoutSortingWallClockAndAllowsActivePrefix() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000201")!
        let query = try fixtureQuery()
        let context = try fixtureContext(connectionID: connectionID)
        var ledger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try ledger.queued(query: query, context: context, at: time(100, 1_000), attemptID: attemptID)
        _ = try ledger.started(attemptID: attemptID, at: time(90, 2_000))
        _ = try ledger.transportWriteStarted(attemptID: attemptID, at: time(91, 3_000))
        _ = try ledger.succeeded(
            attemptID: attemptID, responseSequence: 101, responseReceivedAt: time(92, 3_500),
            at: time(93, 4_000)
        )
        _ = try ledger.transportWriteCompleted(attemptID: attemptID, at: time(94, 5_000))

        let expectedEvents = try XCTUnwrap(ledger.snapshot().first).events
        let rebuilt = try DiagnosticAuditAttempt.reconstruct(events: expectedEvents)
        XCTAssertEqual(rebuilt.events, expectedEvents)
        XCTAssertEqual(rebuilt.events.map(\.ordinal), [1, 2, 3, 4, 5])
        XCTAssertEqual(rebuilt.events.map(\.timestamp.epochSeconds), [100, 90, 91, 93, 94])
        XCTAssertEqual(rebuilt.terminalEvent?.writeDispositionAtTermination, .inFlight)
        XCTAssertEqual(rebuilt.currentWriteDisposition, .completed)
        let repeatedRows = try DiagnosticAuditAttempt.reconstruct(
            events: expectedEvents + [expectedEvents[3], expectedEvents[4]]
        )
        XCTAssertEqual(repeatedRows.events, expectedEvents,
                       "an exactly equal persisted duplicate must not create extra terminal/write stages")

        let activePrefix = Array(expectedEvents.prefix(2))
        let inProgress = try DiagnosticAuditAttempt.reconstruct(events: activePrefix)
        XCTAssertFalse(inProgress.isTerminal)
    }

    func testReplayRejectsMissingLeadingRowsOrdinalGapsDuplicateTerminalAndMetadataChange() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000202")!
        let events = try completedEvents(connectionID: connectionID, attemptID: attemptID)
        XCTAssertThrowsError(try DiagnosticAuditAttempt.reconstruct(events: Array(events.dropFirst()))) { error in
            XCTAssertEqual(error as? DiagnosticAuditError, .incompleteHistory(attemptID))
        }
        XCTAssertThrowsError(try DiagnosticAuditAttempt.reconstruct(events: [events[0], events[2]]))

        let otherQueryEvents = try completedEvents(
            connectionID: connectionID, attemptID: attemptID, queryID: "different-query"
        )
        XCTAssertThrowsError(try DiagnosticAuditAttempt.reconstruct(events: [events[0], otherQueryEvents[1]]))
        XCTAssertThrowsError(try DiagnosticAuditAttempt.reconstruct(events: [events[0], events[2], events[1]]))
        let otherAttemptEvents = try completedEvents(
            connectionID: connectionID,
            attemptID: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000299")!
        )
        XCTAssertThrowsError(try DiagnosticAuditAttempt.reconstruct(events: [events[0], otherAttemptEvents[1]]))

        let changedContext = try DiagnosticAuditContext(
            adapterProfileID: "other-profile", adapterProfileName: "Other profile",
            transport: "ble", connectionID: connectionID
        )
        var changedContextLedger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try changedContextLedger.queued(
            query: fixtureQuery(), context: changedContext, at: time(900, 90_000), attemptID: attemptID
        )
        let changedContextEvent = try XCTUnwrap(try changedContextLedger.started(
            attemptID: attemptID, at: time(800, 91_000)
        ))
        XCTAssertThrowsError(try DiagnosticAuditAttempt.reconstruct(events: [events[0], changedContextEvent]))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let changedTerminalData = try encoder.encode(DiagnosticAuditSystemPayload(event: events.last!))
        let changedTerminalOrdinal = try mutatedAudit(changedTerminalData) { $0["ordinal"] = 6 }
        let extraTerminal = try decoder.decode(DiagnosticAuditSystemPayload.self, from: changedTerminalOrdinal).diagnosticAudit
        XCTAssertThrowsError(try DiagnosticAuditAttempt.reconstruct(events: events + [extraTerminal]))

        let repeatedStageData = try encoder.encode(DiagnosticAuditSystemPayload(event: events[1]))
        let repeatedStageOrdinal = try mutatedAudit(repeatedStageData) { payload in
            payload["ordinal"] = 6
            var timestamp = try XCTUnwrap(payload["timestamp"] as? [String: Any])
            timestamp["epochSeconds"] = 700.0
            timestamp["monotonicNanoseconds"] = 95_000
            payload["timestamp"] = timestamp
        }
        let repeatedStage = try decoder.decode(DiagnosticAuditSystemPayload.self, from: repeatedStageOrdinal).diagnosticAudit
        XCTAssertThrowsError(try DiagnosticAuditAttempt.reconstruct(events: events + [repeatedStage]))

        let changedResult = try mutatedAudit(changedTerminalData) { $0["responseSequence"] = 999 }
        let sameOrdinalConflict = try decoder.decode(DiagnosticAuditSystemPayload.self, from: changedResult).diagnosticAudit
        XCTAssertThrowsError(try DiagnosticAuditAttempt.reconstruct(events: events + [sameOrdinalConflict]))
    }

    func testReplayKeepsSameAttemptIDSeparateAcrossRecordingAndAcquisitionScopes() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let recordingID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000203")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000203")!
        let query = try fixtureQuery()
        let context = try fixtureContext(connectionID: connectionID)
        var live = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        var recording = DiagnosticAuditLedger(scope: .recordingWindow(recordingID: recordingID))
        _ = try live.queued(query: query, context: context, at: time(100, 1_000), attemptID: attemptID)
        _ = try live.started(attemptID: attemptID, at: time(101, 2_000))
        _ = try recording.queued(query: query, context: context, at: time(100, 1_000), attemptID: attemptID)
        _ = try recording.started(attemptID: attemptID, at: time(101, 2_000))
        _ = try recording.closeRecordingWindow(at: time(102, 3_000))

        let liveEvents = try XCTUnwrap(live.snapshot().first).events
        let recordingEvents = try XCTUnwrap(recording.snapshot().first).events
        let liveAttempt = try DiagnosticAuditAttempt.reconstruct(events: liveEvents)
        let recordingAttempt = try DiagnosticAuditAttempt.reconstruct(events: recordingEvents)
        XCTAssertEqual(liveAttempt.attemptID, attemptID)
        XCTAssertEqual(recordingAttempt.attemptID, attemptID)
        XCTAssertNotEqual(liveAttempt.scope, recordingAttempt.scope)
        XCTAssertNotEqual(liveAttempt.id, recordingAttempt.id)
        XCTAssertTrue(recordingAttempt.isTerminal)
        XCTAssertThrowsError(try DiagnosticAuditAttempt.reconstruct(events: liveEvents + recordingEvents))
    }
}
