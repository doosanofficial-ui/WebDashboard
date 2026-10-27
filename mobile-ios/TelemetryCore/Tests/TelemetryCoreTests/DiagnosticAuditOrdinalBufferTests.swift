import Foundation
import XCTest
@testable import TelemetryCore

final class DiagnosticAuditOrdinalBufferTests: XCTestCase {
    private func timestamp(_ epoch: Double, _ monotonic: UInt64) throws -> DiagnosticAuditTimestamp {
        try DiagnosticAuditTimestamp(epochSeconds: epoch, monotonicNanoseconds: monotonic)
    }

    private func context(connectionID: UUID, adapterProfileID: String = "ordinal-buffer-profile") throws -> DiagnosticAuditContext {
        try DiagnosticAuditContext(
            vehicleContextID: nil,
            adapterProfileID: adapterProfileID,
            adapterProfileName: "Ordinal buffer profile",
            transport: "ble",
            connectionID: connectionID
        )
    }

    private func makeBuffer(
        startedAtMonotonic: UInt64 = 0,
        maximumTrackedAttempts: Int = 256,
        maximumPendingEventsPerAttempt: Int = 8
    ) throws -> DiagnosticAuditOrdinalBuffer {
        DiagnosticAuditOrdinalBuffer(
            startedAt: try timestamp(1_000, startedAtMonotonic),
            maximumTrackedAttempts: maximumTrackedAttempts,
            maximumPendingEventsPerAttempt: maximumPendingEventsPerAttempt
        )
    }

    private func sourceEvents(
        connectionID: UUID,
        attemptID: UUID,
        baseMonotonic: UInt64,
        startedOffset: UInt64 = 0,
        adapterProfileID: String = "ordinal-buffer-profile"
    ) throws -> [DiagnosticAuditEvent] {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let sourceContext = try context(connectionID: connectionID, adapterProfileID: adapterProfileID)
        var ledger = DiagnosticAuditLedger(scope: .acquisition(connectionID: connectionID))
        _ = try ledger.queued(
            query: query, context: sourceContext, at: timestamp(1_000, baseMonotonic), attemptID: attemptID
        )
        _ = try ledger.started(
            attemptID: attemptID, at: timestamp(999, baseMonotonic + 1_000 + startedOffset)
        )
        _ = try ledger.transportWriteStarted(
            attemptID: attemptID, at: timestamp(1_001, baseMonotonic + 2_000 + startedOffset)
        )
        _ = try ledger.succeeded(
            attemptID: attemptID,
            responseSequence: 41,
            responseReceivedAt: timestamp(1_002, baseMonotonic + 2_500 + startedOffset),
            at: timestamp(1_003, baseMonotonic + 3_000 + startedOffset)
        )
        _ = try ledger.transportWriteCompleted(
            attemptID: attemptID, at: timestamp(1_004, baseMonotonic + 4_000 + startedOffset)
        )
        return try XCTUnwrap(ledger.snapshot().first).events
    }

    func testReordersLateWriteCompletionBeforeTerminalWithoutChangingSourceEvents() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000601")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID, baseMonotonic: 1_000)
        var buffer = try makeBuffer()

        var emitted: [DiagnosticAuditEvent] = []
        for index in [0, 1, 2, 4] {
            emitted += try buffer.ingest(source[index])
        }
        XCTAssertEqual(emitted, Array(source.prefix(3)))
        XCTAssertTrue(buffer.hasUnresolvedGaps)

        let terminalAndLateWrite = try buffer.ingest(source[3])
        emitted += terminalAndLateWrite
        XCTAssertEqual(terminalAndLateWrite, Array(source[3...4]))
        XCTAssertEqual(emitted, source)
        XCTAssertEqual(emitted.filter { $0.stage == .terminal }.count, 1)
        XCTAssertFalse(buffer.hasUnresolvedGaps)
        XCTAssertFalse(buffer.hasRejectedEvents)
    }

    func testTwoOneThreeArrivalEmitsQueuedPrefixInSourceOrdinalOrder() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000611")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID, baseMonotonic: 1_000)
        var buffer = try makeBuffer()

        XCTAssertTrue(try buffer.ingest(source[1]).isEmpty)
        XCTAssertTrue(buffer.hasUnresolvedGaps)
        XCTAssertEqual(try buffer.ingest(source[0]), Array(source[0...1]))
        XCTAssertEqual(try buffer.ingest(source[2]), [source[2]])
        XCTAssertFalse(buffer.hasUnresolvedGaps)
        XCTAssertFalse(buffer.hasRejectedEvents)
    }

    func testQueuedBeforeRecordingCutoffResolvesOrphanWithoutLossOrLaterReseed() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000612")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID, baseMonotonic: 500)
        var buffer = try makeBuffer(startedAtMonotonic: 1_000)

        XCTAssertTrue(try buffer.ingest(source[1]).isEmpty)
        XCTAssertTrue(buffer.hasUnresolvedGaps, "an orphan observed after the cutoff is conservatively incomplete")
        XCTAssertTrue(try buffer.ingest(source[0]).isEmpty, "the attempt was queued before recording began")
        XCTAssertFalse(buffer.hasUnresolvedGaps)
        XCTAssertFalse(buffer.hasRejectedEvents)
        XCTAssertEqual(buffer.droppedEventCount, 0)
        XCTAssertTrue(try buffer.ingest(source[2]).isEmpty, "later phases for an excluded attempt stay excluded")
        XCTAssertEqual(buffer.trackedAttemptCount, 0)
    }

    func testExactRetainedRowsAreIdempotentAndConflictingOrdinalIsRejected() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000602")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID, baseMonotonic: 1_000)
        let conflicting = try sourceEvents(
            connectionID: connectionID, attemptID: attemptID,
            baseMonotonic: 1_000, startedOffset: 1
        )
        var buffer = try makeBuffer()

        XCTAssertEqual(try buffer.ingest(source[0]), [source[0]])
        XCTAssertEqual(try buffer.ingest(source[1]), [source[1]])
        XCTAssertTrue(try buffer.ingest(source[0]).isEmpty)
        XCTAssertTrue(try buffer.ingest(source[1]).isEmpty)
        XCTAssertFalse(buffer.hasRejectedEvents)
        XCTAssertEqual(buffer.droppedEventCount, 0)

        XCTAssertThrowsError(try buffer.ingest(conflicting[1])) { error in
            XCTAssertEqual(error as? DiagnosticAuditError, .conflictingOrdinal(attemptID, 2))
        }
        XCTAssertTrue(buffer.hasRejectedEvents)
        XCTAssertEqual(buffer.droppedEventCount, 1)
    }

    func testPreQueueIdentityConflictDoesNotAttachRowsFromAnotherContext() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000614")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID, baseMonotonic: 1_000)
        let conflictingContext = try sourceEvents(
            connectionID: connectionID,
            attemptID: attemptID,
            baseMonotonic: 1_000,
            adapterProfileID: "another-profile"
        )
        var buffer = try makeBuffer()

        XCTAssertTrue(try buffer.ingest(source[1]).isEmpty)
        XCTAssertThrowsError(try buffer.ingest(conflictingContext[0])) { error in
            XCTAssertEqual(error as? DiagnosticAuditError, .identityMismatch(attemptID))
        }
        XCTAssertTrue(buffer.hasRejectedEvents)
        XCTAssertEqual(try buffer.ingest(source[0]), Array(source[0...1]))
    }

    func testInFlightTerminalIsNotEvictedUntilLateWriteResultArrives() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let firstID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000603")!
        let secondID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000604")!
        let first = try sourceEvents(connectionID: connectionID, attemptID: firstID, baseMonotonic: 1_000)
        let second = try sourceEvents(connectionID: connectionID, attemptID: secondID, baseMonotonic: 10_000)
        var buffer = try makeBuffer(maximumTrackedAttempts: 1)

        for event in first.prefix(4) {
            _ = try buffer.ingest(event)
        }
        XCTAssertThrowsError(try buffer.ingest(second[0]))
        XCTAssertEqual(buffer.trackedAttemptCount, 1)
        XCTAssertTrue(buffer.hasRejectedEvents)

        XCTAssertEqual(try buffer.ingest(first[4]), [first[4]])
        XCTAssertEqual(try buffer.ingest(second[0]), [second[0]])
        XCTAssertEqual(buffer.droppedAttemptCount, 1)
        XCTAssertEqual(buffer.trackedAttemptCount, 1)
    }

    func testPendingRowAndAttemptLimitsRejectWithoutEmittingPastGap() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let firstID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000605")!
        let secondID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000606")!
        let first = try sourceEvents(connectionID: connectionID, attemptID: firstID, baseMonotonic: 1_000)
        let second = try sourceEvents(connectionID: connectionID, attemptID: secondID, baseMonotonic: 10_000)
        var pendingLimited = try makeBuffer(maximumPendingEventsPerAttempt: 0)
        for event in first.prefix(3) {
            _ = try pendingLimited.ingest(event)
        }
        XCTAssertThrowsError(try pendingLimited.ingest(first[4]))
        XCTAssertTrue(pendingLimited.hasRejectedEvents)
        XCTAssertEqual(pendingLimited.droppedEventCount, 1)
        XCTAssertFalse(pendingLimited.hasUnresolvedGaps, "the over-cap row was rejected, not buffered")

        var attemptLimited = try makeBuffer(maximumTrackedAttempts: 1)
        _ = try attemptLimited.ingest(first[0])
        XCTAssertThrowsError(try attemptLimited.ingest(second[0]))
        XCTAssertEqual(attemptLimited.trackedAttemptCount, 1)
        XCTAssertTrue(attemptLimited.hasRejectedEvents)
    }

    func testSameTimestampQueuedIDBucketDoesNotAllowReseedAfterEviction() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let firstID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000607")!
        let secondID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000608")!
        let first = try sourceEvents(connectionID: connectionID, attemptID: firstID, baseMonotonic: 1_000)
        let sameTimeSecond = try sourceEvents(connectionID: connectionID, attemptID: secondID, baseMonotonic: 1_000)
        var buffer = try makeBuffer(maximumTrackedAttempts: 1)
        for event in first {
            _ = try buffer.ingest(event)
        }

        XCTAssertThrowsError(try buffer.ingest(sameTimeSecond[0]))
        XCTAssertEqual(buffer.trackedAttemptCount, 1)
        XCTAssertEqual(buffer.droppedAttemptCount, 0, "reject the full timestamp bucket before evicting retained state")
        XCTAssertTrue(buffer.hasRejectedEvents)
        XCTAssertTrue(try buffer.ingest(first[0]).isEmpty, "the retained exact queue is still idempotent")
    }

    func testUnknownOldPhaseIsIgnoredAfterSafeEvictionAndOldQueueCannotReseed() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let firstID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000609")!
        let secondID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000610")!
        let first = try sourceEvents(connectionID: connectionID, attemptID: firstID, baseMonotonic: 1_000)
        let second = try sourceEvents(connectionID: connectionID, attemptID: secondID, baseMonotonic: 10_000)
        var buffer = try makeBuffer(maximumTrackedAttempts: 1)

        for event in first {
            _ = try buffer.ingest(event)
        }
        XCTAssertEqual(try buffer.ingest(second[0]), [second[0]])
        XCTAssertEqual(buffer.droppedAttemptCount, 1)
        XCTAssertTrue(try buffer.ingest(first[1]).isEmpty)
        XCTAssertEqual(buffer.trackedAttemptCount, 1)
        XCTAssertThrowsError(try buffer.ingest(first[0]))
        XCTAssertTrue(buffer.hasRejectedEvents)
    }

    func testCompletedAttemptRetirementDoesNotMarkLossAfterAllRowsWereEmitted() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var buffer = try makeBuffer(maximumTrackedAttempts: 1)
        var emitted: [DiagnosticAuditEvent] = []

        for index in 0..<4 {
            let attemptID = UUID(uuidString: String(format: "BBBBBBBB-0000-0000-0000-%012d", 700 + index))!
            let source = try sourceEvents(
                connectionID: connectionID,
                attemptID: attemptID,
                baseMonotonic: UInt64(1_000 + index * 10_000)
            )
            for event in source {
                emitted += try buffer.ingest(event)
            }
        }

        XCTAssertEqual(emitted.count, 20)
        XCTAssertEqual(buffer.droppedAttemptCount, 3)
        XCTAssertFalse(buffer.hasRejectedEvents)
        XCTAssertEqual(buffer.droppedEventCount, 0)
        XCTAssertFalse(buffer.hasUnresolvedGaps)
    }

    func testPruningExcludedPreRecordingIdentitiesDoesNotMarkLoss() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var buffer = try makeBuffer(startedAtMonotonic: 50_000, maximumTrackedAttempts: 1)

        for index in 0..<4 {
            let attemptID = UUID(uuidString: String(format: "BBBBBBBB-0000-0000-0000-%012d", 800 + index))!
            let source = try sourceEvents(
                connectionID: connectionID,
                attemptID: attemptID,
                baseMonotonic: UInt64(1_000 + index * 10_000)
            )
            for event in source {
                XCTAssertTrue(try buffer.ingest(event).isEmpty)
            }
        }

        XCTAssertFalse(buffer.hasRejectedEvents)
        XCTAssertEqual(buffer.droppedEventCount, 0)
        XCTAssertEqual(buffer.trackedAttemptCount, 0)
        XCTAssertFalse(buffer.hasUnresolvedGaps)
    }

    func testUnknownPreRecordingPhasesDoNotConsumeCapacityOrMarkLoss() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let firstID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000901")!
        let secondID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000902")!
        let first = try sourceEvents(connectionID: connectionID, attemptID: firstID, baseMonotonic: 1_000)
        let second = try sourceEvents(connectionID: connectionID, attemptID: secondID, baseMonotonic: 10_000)
        var buffer = try makeBuffer(startedAtMonotonic: 20_000, maximumTrackedAttempts: 1)

        XCTAssertTrue(try buffer.ingest(first[1]).isEmpty)
        XCTAssertTrue(try buffer.ingest(second[1]).isEmpty)
        XCTAssertEqual(buffer.trackedAttemptCount, 0)
        XCTAssertFalse(buffer.hasUnresolvedGaps)
        XCTAssertFalse(buffer.hasRejectedEvents)

        XCTAssertTrue(try buffer.ingest(first[0]).isEmpty)
        XCTAssertTrue(try buffer.ingest(second[0]).isEmpty)
        XCTAssertEqual(buffer.trackedAttemptCount, 0)
        XCTAssertFalse(buffer.hasUnresolvedGaps)
        XCTAssertFalse(buffer.hasRejectedEvents)
    }

    func testGapDetectionUsesRecordingCutoffAndCloseRejectsLaterInput() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000613")!
        let source = try sourceEvents(connectionID: connectionID, attemptID: attemptID, baseMonotonic: 1_000)
        var buffer = try makeBuffer(startedAtMonotonic: 1_000)
        for index in [0, 1, 2, 4] {
            _ = try buffer.ingest(source[index])
        }

        XCTAssertTrue(buffer.hasUnresolvedGaps)
        buffer.close()
        XCTAssertTrue(buffer.isClosed)
        XCTAssertTrue(buffer.hasUnresolvedGaps, "close preserves unresolved-gap evidence for Stop")
        XCTAssertThrowsError(try buffer.ingest(source[3]))
    }

    func testSameAttemptIDOnDifferentConnectionsRemainsIsolated() throws {
        let firstConnection = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let secondConnection = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000609")!
        let attemptID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000610")!
        let first = try sourceEvents(connectionID: firstConnection, attemptID: attemptID, baseMonotonic: 1_000)
        let second = try sourceEvents(connectionID: secondConnection, attemptID: attemptID, baseMonotonic: 1_000)
        var buffer = try makeBuffer()

        XCTAssertEqual(try buffer.ingest(first[0]), [first[0]])
        XCTAssertEqual(try buffer.ingest(second[0]), [second[0]])
        XCTAssertEqual(buffer.trackedAttemptCount, 2)
        XCTAssertFalse(buffer.hasRejectedEvents)
    }
}
