import Foundation
import XCTest
@testable import TelemetryCore

@MainActor
final class MeasurementWriteQueueTests: XCTestCase {
    private func database() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("write-queue-\(UUID().uuidString)/measurements.sqlite")
    }
    private func event(_ name: String) -> MeasurementEvent {
        .system(name: name, timestamp: 100, monotonicNanos: 1000)
    }
    private func names(_ recorder: MeasurementRecorder) async throws -> [String] {
        struct Payload: Decodable { let name: String }
        return try await recorder.export().map {
            try JSONDecoder().decode(Payload.self, from: Data($0.payloadJSON.utf8)).name
        }
    }

    func testCloseDrainsEveryAcceptedEventInSubmissionOrder() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        let queue = try MeasurementWriteQueue(recorder: recorder)
        for index in 0..<200 { _ = try queue.enqueue(event("event-\(index)")) }
        try await queue.finish(endedAt: 101, monotonicNanos: 2000).value
        let actual = try await names(recorder)
        XCTAssertEqual(actual, (0..<200).map { "event-\($0)" } + ["recording_stopped"])
        XCTAssertEqual(queue.pendingEventCount, 0)
        XCTAssertEqual(queue.state, .closed)
    }

    func testStopClosesAdmissionBeforeAnyAsyncWorkRuns() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        let queue = try MeasurementWriteQueue(recorder: recorder)
        _ = try queue.enqueue(event("accepted"))
        let close = queue.finish(endedAt: 101, monotonicNanos: 2000)
        XCTAssertThrowsError(try queue.enqueue(event("late")))
        try await close.value
        let actual = try await names(recorder)
        XCTAssertEqual(actual, ["accepted", "recording_stopped"])
    }

    func testRepeatedStopSharesFirstBoundary() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        let queue = try MeasurementWriteQueue(recorder: recorder)
        let first = queue.finish(endedAt: 101, monotonicNanos: 2000)
        let second = queue.finish(endedAt: 999, monotonicNanos: 9999)
        try await first.value; try await second.value
        let actual = try await names(recorder)
        let session = try await recorder.exportSession()
        XCTAssertEqual(actual, ["recording_stopped"])
        XCTAssertEqual(session.endedAt, 101)
    }

    func testWriteFailureCannotBeHiddenByLaterSuccessOrCleanStop() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        let queue = try MeasurementWriteQueue(recorder: recorder)
        _ = try queue.enqueue(event(""))
        _ = try queue.enqueue(event("must-not-follow-failure"))
        do { try await queue.finish(endedAt: 101, monotonicNanos: 2000).value; XCTFail("Failed write became clean close") }
        catch { XCTAssertEqual(error as? TelemetryError, .invalidBatch) }
        let actual = try await names(recorder)
        XCTAssertEqual(actual, ["recording_failed"])
        XCTAssertEqual(queue.state, .failed)
    }

    func testQueueOverflowIsVisibleAndDrainsAlreadyAcceptedEvents() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        let queue = try MeasurementWriteQueue(recorder: recorder, maximumPendingEvents: 2)
        _ = try queue.enqueue(event("one")); _ = try queue.enqueue(event("two"))
        XCTAssertThrowsError(try queue.enqueue(event("overflow"))) { error in
            XCTAssertEqual(error as? TelemetryError, .queueFull)
        }
        do { try await queue.finish(endedAt: 101, monotonicNanos: 2000).value; XCTFail("Overflow was hidden") }
        catch { XCTAssertEqual(error as? TelemetryError, .queueFull) }
        let actual = try await names(recorder)
        XCTAssertEqual(actual, ["one", "two", "recording_failed"])
        XCTAssertEqual(queue.pendingEventCount, 0)
    }

    func testDrainMakesExportIncludeAcceptedEventsWithoutClosingSession() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        let queue = try MeasurementWriteQueue(recorder: recorder)
        _ = try queue.enqueue(event("one"))
        try await queue.drain()
        let first = try await names(recorder)
        XCTAssertEqual(first, ["one"])
        XCTAssertEqual(queue.state, .accepting)
        _ = try queue.enqueue(event("two"))
        try await queue.finish(endedAt: 101, monotonicNanos: 2000).value
        let actual = try await names(recorder)
        XCTAssertEqual(actual, ["one", "two", "recording_stopped"])
    }

    func testCancelledAcceptedWriteFailsTheSessionInsteadOfDisappearing() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        let queue = try MeasurementWriteQueue(recorder: recorder)
        let pending = try queue.enqueue(event("cancelled"))
        pending.cancel()
        do { try await queue.finish(endedAt: 101, monotonicNanos: 2000).value; XCTFail("Cancellation was ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        let actual = try await names(recorder)
        XCTAssertEqual(actual, ["recording_failed"])
    }

    func testInvalidBatchNeverLeavesAnOrphanedSourceRow() async throws {
        let path = database(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = try MeasurementRecorder(path: path, sessionID: "s", startedAt: 90)
        let queue = try MeasurementWriteQueue(recorder: recorder)
        _ = try queue.enqueue(contentsOf: [event("source"), event("")])
        do { try await queue.finish(endedAt: 101, monotonicNanos: 2000).value; XCTFail("Bad batch accepted") }
        catch { XCTAssertEqual(error as? TelemetryError, .invalidBatch) }
        let actual = try await names(recorder)
        XCTAssertEqual(actual, ["recording_failed"])
    }
}
