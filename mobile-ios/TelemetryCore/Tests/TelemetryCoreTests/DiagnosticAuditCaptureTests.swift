import Foundation
import XCTest
@testable import TelemetryCore

final class DiagnosticAuditCaptureTests: XCTestCase {
    private func query(id: String = "capture-query") throws -> OBDQueryDefinition {
        let source = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        guard id != source.id else { return source }
        return try OBDQueryDefinition(
            id: id, name: source.name, requestCANID: source.requestCANID,
            responseCANID: source.responseCANID, isExtended: source.isExtended,
            service: source.service, command: source.command, pollInterval: source.pollInterval,
            timeout: source.timeout, flowControl: source.flowControl,
            sourceRepository: source.sourceRepository, sourcePath: source.sourcePath,
            sourceCommit: source.sourceCommit, signals: source.signals
        )
    }

    private func context(connectionID: UUID) throws -> DiagnosticAuditContext {
        try DiagnosticAuditContext(
            vehicleContextID: nil, adapterProfileID: "capture-profile",
            adapterProfileName: "Capture profile", transport: "ble", connectionID: connectionID
        )
    }

    private func timestamp(_ epoch: Double, _ monotonic: UInt64) throws -> DiagnosticAuditTimestamp {
        try DiagnosticAuditTimestamp(epochSeconds: epoch, monotonicNanoseconds: monotonic)
    }

    private func sourceEvents(
        connectionID: UUID,
        attemptID: UUID,
        queryID: String = "capture-query",
        baseMonotonic: UInt64 = 1_000,
        finish: Bool = true
    ) throws -> [DiagnosticAuditEvent] {
        let sourceQuery = try query(id: queryID)
        let sourceContext = try context(connectionID: connectionID)
        var live = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try live.queued(
            query: sourceQuery, context: sourceContext,
            at: timestamp(1_000, baseMonotonic), attemptID: attemptID
        )
        _ = try live.started(
            attemptID: attemptID, at: timestamp(900, baseMonotonic + 1_000)
        )
        _ = try live.transportWriteStarted(
            attemptID: attemptID, at: timestamp(901, baseMonotonic + 2_000)
        )
        if finish {
            _ = try live.succeeded(
                attemptID: attemptID, responseSequence: 41,
                responseReceivedAt: timestamp(902, baseMonotonic + 2_500),
                at: timestamp(903, baseMonotonic + 3_000)
            )
            _ = try live.transportWriteCompleted(
                attemptID: attemptID, at: timestamp(904, baseMonotonic + 4_000)
            )
        }
        return try XCTUnwrap(live.snapshot().first).events
    }

    private func failedSourceEvents(
        connectionID: UUID,
        attemptID: UUID,
        baseMonotonic: UInt64,
        cancelAfterWriteFailure: Bool
    ) throws -> [DiagnosticAuditEvent] {
        let sourceQuery = try query()
        let sourceContext = try context(connectionID: connectionID)
        var live = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try live.queued(
            query: sourceQuery, context: sourceContext,
            at: timestamp(1_000, baseMonotonic), attemptID: attemptID
        )
        _ = try live.started(attemptID: attemptID, at: timestamp(999, baseMonotonic + 1_000))
        if cancelAfterWriteFailure {
            _ = try live.transportWriteStarted(
                attemptID: attemptID, at: timestamp(1_001, baseMonotonic + 2_000)
            )
            _ = try live.transportWriteFailed(
                attemptID: attemptID, reasonCode: "transport_write_failed",
                reason: "Transport API returned an error",
                at: timestamp(1_002, baseMonotonic + 3_000)
            )
            _ = try live.cancelled(
                attemptID: attemptID, reasonCode: "connection_stopped",
                reason: "Connection stopped during query",
                at: timestamp(1_003, baseMonotonic + 4_000)
            )
        } else {
            _ = try live.failed(
                attemptID: attemptID, reasonCode: "negative_response",
                reason: "ECU returned a negative response",
                at: timestamp(1_001, baseMonotonic + 2_000)
            )
        }
        return try XCTUnwrap(live.snapshot().first).events
    }

    private func json(_ event: DiagnosticAuditEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(DiagnosticAuditSystemPayload(event: event))
        return String(decoding: data, as: UTF8.self)
    }

    private func mutateAudit(_ json: String, _ mutation: (inout [String: Any]) throws -> Void) throws -> String {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var audit = try XCTUnwrap(root["diagnosticAudit"] as? [String: Any])
        try mutation(&audit)
        root["diagnosticAudit"] = audit
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func testPreRecordingQueueAndItsUnknownLatePhasesDoNotSeedCapture() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000401")!
        let beforeStart = try sourceEvents(
            connectionID: connectionID, attemptID: attemptID,
            baseMonotonic: 10, finish: true
        )
        var capture = DiagnosticAuditCapture(
            recordingID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000401")!,
            startedAt: try timestamp(1_010, 100)
        )

        for event in beforeStart {
            XCTAssertTrue(try capture.ingest(event).isEmpty)
        }
        XCTAssertTrue(capture.snapshot().isEmpty)
        XCTAssertFalse(capture.isClosed)
    }

    func testCaptureCopiesOnlyAppendedStagesWithOriginalIdentityAndSourceTimes() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000402")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID)
        var capture = DiagnosticAuditCapture(
            recordingID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000402")!,
            startedAt: try timestamp(999, 500)
        )

        let appended = try source.flatMap { try capture.ingest($0) }
        let attempt = try XCTUnwrap(capture.snapshot().first)
        XCTAssertEqual(appended, attempt.events)
        XCTAssertEqual(attempt.scope, .recordingWindow(recordingID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000402")!))
        XCTAssertEqual(attempt.attemptID, attemptID)
        XCTAssertEqual(attempt.query, source[0].query)
        XCTAssertEqual(attempt.context, source[0].context)
        XCTAssertEqual(attempt.events.map(\.timestamp), source.map(\.timestamp))
        XCTAssertEqual(attempt.events.map(\.ordinal), [1, 2, 3, 4, 5])
        XCTAssertEqual(appended.filter { $0.stage == .terminal }.count, 1)
        XCTAssertEqual(appended.last?.stage, .transportWriteCompleted)
        XCTAssertEqual(appended.last?.scope, .recordingWindow(recordingID: capture.scope.identifier))
    }

    func testUnknownLatePhaseNeverCreatesCaptureAttempt() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000403")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID)
        var capture = DiagnosticAuditCapture(
            recordingID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000403")!,
            startedAt: try timestamp(999, 500)
        )
        XCTAssertTrue(try capture.ingest(source[2]).isEmpty)
        XCTAssertTrue(capture.snapshot().isEmpty)
    }

    func testExactRetainedDuplicatesAreIdempotentAndOrdinalGapsAreRejected() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000404")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID)
        var capture = DiagnosticAuditCapture(
            recordingID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000404")!,
            startedAt: try timestamp(999, 500)
        )
        _ = try capture.ingest(source[0])
        _ = try capture.ingest(source[1])
        let before = capture.snapshot()

        XCTAssertTrue(try capture.ingest(source[1]).isEmpty)
        XCTAssertTrue(try capture.ingest(source[0]).isEmpty)
        XCTAssertEqual(capture.snapshot(), before)

        let conflictingQueue = try sourceEvents(
            connectionID: connectionID, attemptID: attemptID,
            baseMonotonic: 2_000, finish: false
        )[0]
        XCTAssertThrowsError(try capture.ingest(conflictingQueue)) { error in
            XCTAssertEqual(error as? DiagnosticAuditError, .conflictingOrdinal(attemptID, 1))
        }
        XCTAssertEqual(capture.snapshot(), before)

        var gappedCapture = DiagnosticAuditCapture(
            recordingID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000405")!,
            startedAt: try timestamp(999, 500)
        )
        _ = try gappedCapture.ingest(source[0])
        XCTAssertThrowsError(try gappedCapture.ingest(source[2]))
        XCTAssertEqual(gappedCapture.snapshot().first?.events.map(\.ordinal), [1])
    }

    func testExactRetainedTerminalAndLateWriteRowsAreIdempotent() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000423")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID)
        var capture = DiagnosticAuditCapture(
            recordingID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000423")!,
            startedAt: try timestamp(900, 100)
        )

        let appended = try source.flatMap { try capture.ingest($0) }
        for event in source {
            XCTAssertTrue(try capture.ingest(event).isEmpty)
        }
        XCTAssertEqual(appended.count, 5)
        XCTAssertEqual(capture.snapshot().first?.events.count, 5)
        XCTAssertFalse(capture.hasRejectedSourceEvents)
    }

    func testStaleEligibleQueueIsRejectedAndMarksCaptureHistoryTruncated() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let first = try sourceEvents(
            connectionID: connectionID,
            attemptID: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000420")!,
            baseMonotonic: 1_000, finish: false
        )
        let later = try sourceEvents(
            connectionID: connectionID,
            attemptID: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000421")!,
            baseMonotonic: 2_000, finish: false
        )
        let stale = try sourceEvents(
            connectionID: connectionID,
            attemptID: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000422")!,
            baseMonotonic: 1_500, finish: false
        )
        var capture = DiagnosticAuditCapture(
            recordingID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000420")!,
            startedAt: try timestamp(900, 100)
        )

        _ = try capture.ingest(first[0])
        _ = try capture.ingest(later[0])
        let beforeStaleQueue = capture.snapshot()
        XCTAssertThrowsError(try capture.ingest(stale[0]))
        XCTAssertEqual(capture.snapshot(), beforeStaleQueue)
        XCTAssertTrue(capture.historyWasTruncated)
    }

    func testFailedAndCancelledAttemptsCopyWriteAndReasonEvidence() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let failedID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000430")!
        let cancelledID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000431")!
        let failed = try failedSourceEvents(
            connectionID: connectionID, attemptID: failedID,
            baseMonotonic: 1_000, cancelAfterWriteFailure: false
        )
        let cancelled = try failedSourceEvents(
            connectionID: connectionID, attemptID: cancelledID,
            baseMonotonic: 10_000, cancelAfterWriteFailure: true
        )
        var capture = DiagnosticAuditCapture(
            recordingID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000430")!,
            startedAt: try timestamp(900, 100)
        )

        let appended = try (failed + cancelled).flatMap { try capture.ingest($0) }
        let attempts = capture.snapshot()
        XCTAssertEqual(attempts.map(\.attemptID), [failedID, cancelledID])
        XCTAssertEqual(appended.map(\.stage), (failed + cancelled).map(\.stage))

        let failedAttempt = try XCTUnwrap(attempts.first { $0.attemptID == failedID })
        XCTAssertEqual(failedAttempt.terminalEvent?.terminalOutcome, .failed)
        XCTAssertEqual(failedAttempt.terminalEvent?.reasonCode, "negative_response")
        XCTAssertEqual(failedAttempt.terminalEvent?.reason, "ECU returned a negative response")
        XCTAssertEqual(failedAttempt.terminalEvent?.writeDispositionAtTermination, .notAttempted)

        let cancelledAttempt = try XCTUnwrap(attempts.first { $0.attemptID == cancelledID })
        XCTAssertEqual(cancelledAttempt.events.map(\.stage), [.queued, .started, .transportWriteStarted, .transportWriteFailed, .terminal])
        XCTAssertEqual(cancelledAttempt.events[3].reasonCode, "transport_write_failed")
        XCTAssertEqual(cancelledAttempt.terminalEvent?.terminalOutcome, .cancelled)
        XCTAssertEqual(cancelledAttempt.terminalEvent?.reasonCode, "connection_stopped")
        XCTAssertEqual(cancelledAttempt.terminalEvent?.writeDispositionAtTermination, .indeterminate)
    }

    func testReusedAttemptIDFromAnotherConnectionIsRejected() throws {
        let firstConnection = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let otherConnection = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000499")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000405")!
        let first = try sourceEvents(
            connectionID: firstConnection, attemptID: attemptID, finish: false
        )
        let collision = try sourceEvents(
            connectionID: otherConnection, attemptID: attemptID, baseMonotonic: 10_000, finish: false
        )
        var capture = DiagnosticAuditCapture(
            recordingID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000406")!,
            startedAt: try timestamp(999, 500)
        )
        _ = try capture.ingest(first[0])
        let before = capture.snapshot()
        XCTAssertThrowsError(try capture.ingest(collision[0]))
        XCTAssertEqual(capture.snapshot(), before)
    }

    func testCloseReturnsEachOpenTerminalOnceAndGatesLaterEvents() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000406")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID, finish: false)
        var capture = DiagnosticAuditCapture(
            recordingID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000407")!,
            startedAt: try timestamp(999, 500)
        )
        _ = try source.flatMap { try capture.ingest($0) }
        let closed = try capture.close(at: timestamp(1_010, 10_000))

        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.stage, .terminal)
        XCTAssertEqual(closed.first?.terminalOutcome, .recordingWindowClosed)
        XCTAssertEqual(capture.snapshot().first?.events.filter { $0.stage == .terminal }.count, 1)
        XCTAssertTrue(capture.isClosed)
        XCTAssertTrue(try capture.close(at: timestamp(1_011, 11_000)).isEmpty)
        XCTAssertTrue(try capture.ingest(source[2]).isEmpty)
        XCTAssertEqual(capture.snapshot().first?.events.filter { $0.stage == .terminal }.count, 1)
        XCTAssertNil(source.last?.terminalOutcome, "capture Stop must not terminalize acquisition events")
    }

    func testBoundedHistoryRejectsOldQueueReseedAndReportsSameTimestampBucketOverflow() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let recordingID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000408")!
        let firstID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000408")!
        let secondID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000409")!
        let thirdID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000410")!
        let first = try sourceEvents(connectionID: connectionID, attemptID: firstID, baseMonotonic: 1_000)
        let second = try sourceEvents(connectionID: connectionID, attemptID: secondID, baseMonotonic: 10_000)
        let third = try sourceEvents(connectionID: connectionID, attemptID: thirdID, baseMonotonic: 1_000)
        var capture = DiagnosticAuditCapture(
            recordingID: recordingID, startedAt: try timestamp(900, 500),
            completedAttemptHistoryLimit: 1
        )

        _ = try first.flatMap { try capture.ingest($0) }
        _ = try second.flatMap { try capture.ingest($0) }
        XCTAssertEqual(capture.snapshot().map(\.attemptID), [secondID])
        XCTAssertEqual(capture.droppedAttemptCount, 1)
        XCTAssertTrue(capture.historyWasTruncated)
        XCTAssertFalse(capture.hasRejectedSourceEvents,
                       "bounded in-memory retention is not persistent archive loss")
        XCTAssertThrowsError(try capture.ingest(first[0]), "the evicted queued row must never reseed the capture")
        XCTAssertEqual(capture.snapshot().map(\.attemptID), [secondID])
        XCTAssertFalse(capture.hasRejectedSourceEvents,
                       "rejecting a duplicate row already archived is not source loss")

        var bucketCapture = DiagnosticAuditCapture(
            recordingID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000411")!,
            startedAt: try timestamp(900, 500), completedAttemptHistoryLimit: 2,
            sameTimestampAttemptLimit: 2
        )
        let sameTimestampSecond = try sourceEvents(
            connectionID: connectionID, attemptID: secondID, baseMonotonic: 1_000
        )
        _ = try bucketCapture.ingest(first[0])
        _ = try bucketCapture.ingest(sameTimestampSecond[0])
        XCTAssertThrowsError(try bucketCapture.ingest(third[0]), "equal source times must accept unique IDs only up to the bucket cap")
        XCTAssertTrue(bucketCapture.historyWasTruncated)
        XCTAssertTrue(bucketCapture.hasRejectedSourceEvents)
        XCTAssertEqual(bucketCapture.snapshot().map(\.attemptID), [firstID, secondID])
    }

    func testReplayProjectionPreservesSystemOrderAndSkipsOrdinarySystemRows() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let firstID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000501")!
        let secondID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000502")!
        let first = try sourceEvents(connectionID: connectionID, attemptID: firstID)
        let second = try sourceEvents(connectionID: connectionID, attemptID: secondID, baseMonotonic: 10_000)
        let payloads = try ["{\"name\":\"MARK\"}", json(first[0]), json(second[0]), json(first[1]), json(second[1])] +
            first.dropFirst(2).map(json) + second.dropFirst(2).map(json)

        let projected = DiagnosticAuditReplayProjection.project(systemPayloadJSON: payloads)
        XCTAssertEqual(projected.status, .available)
        XCTAssertEqual(projected.attempts.map(\.attemptID), [firstID, secondID])
        XCTAssertEqual(projected.attempts[0].events.map(\.ordinal), [1, 2, 3, 4, 5])
        XCTAssertEqual(projected.attempts[1].events.map(\.ordinal), [1, 2, 3, 4, 5])
        XCTAssertEqual(payloads[0], "{\"name\":\"MARK\"}")
    }

    func testReplayProjectionDistinguishesCappedLeadingGapFromUnavailableRows() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000503")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID)
        let missingLeading = try source.dropFirst().map(json)
        let truncated = DiagnosticAuditReplayProjection.project(
            systemPayloadJSON: missingLeading, historyWasCapped: true
        )
        XCTAssertEqual(truncated.status, .truncated)
        XCTAssertEqual(truncated.truncatedAttemptCount, 1)
        XCTAssertTrue(truncated.attempts.isEmpty)

        let unavailablePrefix = DiagnosticAuditReplayProjection.project(systemPayloadJSON: missingLeading)
        XCTAssertEqual(unavailablePrefix.status, .unavailable)
        XCTAssertEqual(unavailablePrefix.unavailableAttemptCount, 1)

        let internalGap = try [json(source[0]), json(source[2])]
        let unavailableGap = DiagnosticAuditReplayProjection.project(
            systemPayloadJSON: internalGap, historyWasCapped: true
        )
        XCTAssertEqual(unavailableGap.status, .unavailable,
                       "a cap can explain a missing prefix, not a gap after queued")
    }

    func testReplayProjectionRejectsMalformedAndFutureAuditEnvelopeButMarksCappedSource() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000504")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID)
        let valid = try json(source[0])
        let malformedV1 = try mutateAudit(valid) { $0["version"] = 2 }
        let futureVersion = "{\"name\":\"diagnostic_audit_v2\"}"

        for payload in [malformedV1, futureVersion, "{broken"] {
            let result = DiagnosticAuditReplayProjection.project(systemPayloadJSON: [payload])
            XCTAssertEqual(result.status, .unavailable)
            XCTAssertEqual(result.unavailableAttemptCount, 1)
            XCTAssertTrue(result.attempts.isEmpty)
        }
        let capped = DiagnosticAuditReplayProjection.project(
            systemPayloadJSON: ["{\"name\":\"MARK\"}"], historyWasCapped: true
        )
        XCTAssertEqual(capped.status, .truncated)
        XCTAssertTrue(capped.attempts.isEmpty)
    }

    func testReplayProjectionTreatsExplicitCaptureLossMarkerAsUnavailableAndKeepsValidAttempts() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000505")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID)
        let payloads = try source.map(json) + ["{\"name\":\"diagnostic_audit_incomplete\"}"]

        let projected = DiagnosticAuditReplayProjection.project(systemPayloadJSON: payloads)
        XCTAssertEqual(projected.status, .unavailable)
        XCTAssertTrue(projected.captureWasIncomplete)
        XCTAssertEqual(projected.attempts.map(\.attemptID), [attemptID])
        XCTAssertEqual(projected.attempts[0].events.map(\.ordinal), [1, 2, 3, 4, 5])
    }

    func testReplayProjectionMarksRecordingFailureAfterKeepingKnownAuditPrefix() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000506")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID, finish: false)
        let acceptedPrefix = try Array(source.prefix(2)).map(json)
        let beforeFailureMarker = DiagnosticAuditReplayProjection.project(
            systemPayloadJSON: acceptedPrefix
        )
        let persistedFailureMarker = "{\"name\":\"recording_failed\"}"
        let failedPrefix = acceptedPrefix + [persistedFailureMarker]
        let afterFailureMarker = DiagnosticAuditReplayProjection.project(
            systemPayloadJSON: failedPrefix
        )

        XCTAssertEqual(beforeFailureMarker.status, .available)
        XCTAssertEqual(beforeFailureMarker.attempts.map(\.attemptID), [attemptID])
        XCTAssertEqual(beforeFailureMarker.attempts.first?.events.map(\.ordinal), [1, 2])
        XCTAssertEqual(afterFailureMarker.status, .unavailable)
        XCTAssertEqual(afterFailureMarker.attempts, beforeFailureMarker.attempts,
                       "the known queued/started prefix remains available for inspection")
        XCTAssertEqual(afterFailureMarker.unavailableAttemptCount, 0,
                       "a recorder-failure marker is not a malformed audit attempt")
        XCTAssertEqual(Array(failedPrefix.dropLast()), acceptedPrefix,
                       "projection must leave original archive payloads untouched")
    }
}
