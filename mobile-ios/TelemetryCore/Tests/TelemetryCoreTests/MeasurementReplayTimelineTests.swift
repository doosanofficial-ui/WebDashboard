import Foundation
import XCTest
@testable import TelemetryCore

final class MeasurementReplayTimelineTests: XCTestCase {
    private func signal(_ sequence: Int64, _ value: Double, _ epoch: Double, _ nanos: UInt64,
                        id: String = "soc", source: TelemetrySource = .diagnostic, unit: String = "%") throws -> PersistedMeasurement {
        let sample = DecodedSignalSample(signalID: id, value: value, rawValue: 1,
            enumName: nil, unit: unit, frameSequence: UInt64(sequence), receivedAtEpoch: epoch,
            receivedAtMonotonicNanos: nanos, source: source)
        return .init(sequence: sequence, sessionID: "timeline", kind: "SIGNAL", sourceTimestamp: epoch,
            receivedAtEpoch: epoch, receivedAtMonotonicNanos: nanos,
            payloadJSON: String(decoding: try JSONEncoder().encode(sample), as: UTF8.self))
    }
    private func mark(_ sequence: Int64, _ epoch: Double, _ nanos: UInt64) -> PersistedMeasurement {
        .init(sequence: sequence, sessionID: "timeline", kind: "SYSTEM", sourceTimestamp: epoch,
            receivedAtEpoch: epoch, receivedAtMonotonicNanos: nanos, payloadJSON: "{\"name\":\"MARK\"}")
    }
    private func envelope(_ rows: [PersistedMeasurement], endedAt: Double? = 110) -> MeasurementExport {
        .init(session: .init(sessionID: "timeline", startedAt: 90, endedAt: endedAt, mode: .demo), measurements: rows)
    }
    func testRecordedHistoryPreservesRowsAndExcludesFutureAcrossBackSeek() async throws {
        let rows = [mark(1, 100, 1_000), try signal(2, 0, 102, 1_000_001_000),
                    try signal(3, 53, 99, 4_000_001_000)]
        let original = envelope(rows)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(original)
        let timeline = try await MeasurementReplay.timeline(original)
        let end = try timeline.signalHistory(signalID: "soc", at: 4)
        XCTAssertEqual(end.samples.map(\.value), [0, 53])
        XCTAssertEqual(end.samples.map(\.elapsedSeconds), [1, 4])
        XCTAssertEqual(end.samples.map(\.measurement), Array(rows.dropFirst()))
        let back = try timeline.signalHistory(signalID: "soc", at: 2.5)
        XCTAssertEqual(back.samples.map(\.value), [0])
        XCTAssertTrue(try timeline.signalHistory(signalID: "soc", at: 0).samples.isEmpty)
        XCTAssertEqual(try encoder.encode(original), bytes)
    }
    func testRecordedHistoryWindowAndCapArePerSignalWithSequenceOrder() async throws {
        var rows = [try signal(1, 0, 100, 1_000)]
        for index in 1...700 {
            rows.append(try signal(Int64(index + 1), Double(index), 100 + Double(index),
                                   UInt64(index) * 1_000_000_000 + 1_000, id: "noise"))
        }
        rows.append(try signal(702, 42, 800, 700_000_001_000))
        rows.append(try signal(703, 43, 799, 700_000_001_000))
        let timeline = try await MeasurementReplay.timeline(envelope(rows))
        let soc = try timeline.signalHistory(signalID: "soc", at: 700)
        XCTAssertEqual(soc.samples.map(\.value), [42, 43])
        XCTAssertFalse(soc.truncated)
        let noise = try timeline.signalHistory(signalID: "noise", at: 700, windowSeconds: 700, maximumSamples: 600)
        XCTAssertEqual(noise.totalSamplesInWindow, 700)
        XCTAssertEqual(noise.samples.count, 600)
        XCTAssertEqual(noise.samples.first?.value, 101)
        XCTAssertTrue(noise.truncated)
        XCTAssertTrue(try timeline.signalHistory(signalID: "missing", at: 700).samples.isEmpty)
    }
    func testRecordedHistoryRejectsInvalidQueryAndDoesNotInventFreshness() async throws {
        let timeline = try await MeasurementReplay.timeline(envelope([try signal(1, 48.5, 100, 1_000)]))
        for bad in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try timeline.signalHistory(signalID: "soc", at: bad))
        }
        XCTAssertThrowsError(try timeline.signalHistory(signalID: "soc", at: 0, windowSeconds: -1))
        XCTAssertThrowsError(try timeline.signalHistory(signalID: "soc", at: 0, maximumSamples: 601))
        let state = try await timeline.snapshot(at: 0)
        XCTAssertEqual(state.signalFreshness["soc"], .unknown)
        XCTAssertEqual(try timeline.signalHistory(signalID: "soc", at: 0).samples.first?.measurement.sourceTimestamp, 100)
    }

    func testRecordedHistorySeparatesSourceReturnsAndRetainsUnitChanges() async throws {
        let timeline = try await MeasurementReplay.timeline(envelope([
            try signal(1, 1, 100, 1_000, source: .rawCAN),
            try signal(2, 2, 101, 1_000_001_000, source: .diagnostic),
            try signal(3, 3, 102, 2_000_001_000, source: .rawCAN, unit: "V")]))
        let history = try timeline.signalHistory(signalID: "soc", at: 2)
        XCTAssertEqual(history.samples.map(\.source.kind), ["rawCAN", "diagnostic", "rawCAN"])
        XCTAssertEqual(history.samples.map(\.sourceSegment), [0, 1, 2])
        XCTAssertEqual(history.samples.map(\.unit), ["%", "%", "V"])
    }
    func testCancelledRecordedHistoryQueryDoesNotPublishResults() async throws {
        let timeline = try await MeasurementReplay.timeline(envelope([try signal(1, 48.5, 100, 1_000)]))
        let query = Task {
            while !Task.isCancelled { await Task.yield() }
            return try timeline.signalHistory(signalID: "soc", at: 0)
        }
        query.cancel()
        do { _ = try await query.value; XCTFail("Cancelled history returned data") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testDiagnosticHistoryDoesNotMergeDelimiterCollidingSources() async throws {
        func diagnostic(_ sequence: Int64, adapter: String, transport: String) throws -> PersistedMeasurement {
            let epoch = 100 + Double(sequence)
            let nanos = UInt64(sequence) * 1_000_000_000
            let payload: [String: Any] = ["signalID": "soc", "name": "SOC", "rawValue": 1,
                "value": 48.5, "unit": "%", "receivedAtEpoch": epoch,
                "receivedAtMonotonicNanos": nanos, "sequence": sequence,
                "sourceAdapter": adapter, "sourceTransport": transport]
            return .init(sequence: sequence, sessionID: "timeline", kind: "DIAGNOSTIC_SIGNAL",
                sourceTimestamp: epoch, receivedAtEpoch: epoch, receivedAtMonotonicNanos: nanos,
                payloadJSON: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
        }
        let rows = [try diagnostic(1, adapter: "a/b", transport: "c"),
                    try diagnostic(2, adapter: "a", transport: "b/c"),
                    try diagnostic(3, adapter: "a/b", transport: "c")]
        let timeline = try await MeasurementReplay.timeline(envelope(rows))
        let points = try timeline.signalHistory(signalID: "soc", at: 2).samples
        XCTAssertEqual(Set(points.map(\.source)).count, 2)
        XCTAssertEqual(points.map(\.sourceSegment), [0, 1, 2])
        XCTAssertEqual(points.map(\.measurement), rows)
    }

    func testDefaultSixtySecondWindowAndSixHundredCapApplyTogether() async throws {
        let rows = try (0..<700).map { index in
            try signal(Int64(index + 1), Double(index), 100 + Double(index) / 100,
                       UInt64(index) * 10_000_000)
        }
        let t = try await MeasurementReplay.timeline(envelope(rows))
        let h = try t.signalHistory(signalID: "soc", at: t.duration)
        XCTAssertEqual(h.startSeconds, 0)
        XCTAssertEqual(h.totalSamplesInWindow, 700)
        XCTAssertEqual(h.samples.count, 600)
        XCTAssertEqual(h.samples.first?.value, 100)
        XCTAssertTrue(h.truncated)
    }

    func testBackwardSeekRebuildsStateWithoutFutureSignalOrMark() async throws {
        let rows = [try signal(1, 10, 100, 1_000), mark(2, 102, 2_000_001_000),
                    try signal(3, 20, 104, 4_000_001_000, id: "later")]
        let timeline = try await MeasurementReplay.timeline(envelope(Array(rows.reversed())))
        let end = try await timeline.snapshot(at: 4)
        XCTAssertEqual(Set(end.signals.map(\.signalID)), ["soc", "later"])
        XCTAssertEqual(end.markTimestamp, 102)
        let beginning = try await timeline.snapshot(at: 0)
        XCTAssertEqual(beginning.signals.map(\.signalID), ["soc"])
        XCTAssertEqual(beginning.signals.first?.value, 10)
        XCTAssertEqual(beginning.signals.first?.receivedAtEpoch, 100)
        XCTAssertEqual(beginning.signals.first?.receivedAtMonotonicNanos, 1_000)
        XCTAssertEqual(beginning.signals.first?.frameSequence, 1)
        XCTAssertEqual(beginning.signals.first?.source, .diagnostic)
        XCTAssertEqual(beginning.signals.first?.quality, .valid)
        XCTAssertNil(beginning.markTimestamp)
    }
    func testElapsedUsesMonotonicTimeAndSequenceAcrossWallClockRollback() async throws {
        let timeline = try await MeasurementReplay.timeline(envelope([
            try signal(1, 10, 102, 1_000), try signal(2, 20, 101, 2_000_001_000)]))
        XCTAssertEqual(timeline.duration, 2)
        let end = try await timeline.snapshot(at: 2)
        XCTAssertEqual(end.timestamp, 101)
        XCTAssertEqual(end.signals.first?.value, 20)
        let middle = try await timeline.snapshot(at: 1)
        XCTAssertEqual(middle.timestamp, 102)
        XCTAssertEqual(middle.signals.first?.value, 10)
    }
    func testBoundsAndEqualTimeRowsUseLastPersistedSequence() async throws {
        let timeline = try await MeasurementReplay.timeline(envelope([
            try signal(1, 10, 100, 1_000), try signal(2, 20, 100, 1_000),
            try signal(3, 30, 102, 2_000_001_000)]))
        let before = try await timeline.snapshot(at: -10)
        let after = try await timeline.snapshot(at: 10_000)
        XCTAssertEqual(before.signals.first?.value, 20)
        XCTAssertEqual(after.signals.first?.value, 30)
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            do { _ = try await timeline.snapshot(at: invalid); XCTFail("Nonfinite seek accepted") }
            catch { XCTAssertEqual(error as? MeasurementReplayError, .invalidExport) }
        }
    }
    func testInvalidTrailingRowCannotHideBehindEarlySeek() async throws {
        let bad = PersistedMeasurement(sequence: 2, sessionID: "timeline", kind: "LOCATION",
            sourceTimestamp: 102, receivedAtEpoch: 102, receivedAtMonotonicNanos: 2_000_001_000, payloadJSON: "{broken")
        do { _ = try await MeasurementReplay.timeline(envelope([try signal(1, 10, 100, 1_000), bad])); XCTFail("Invalid future row accepted") }
        catch { XCTAssertEqual(error as? MeasurementReplayError, .malformedRow("LOCATION")) }
    }
    func testNonfiniteRecordedTimeIsRejectedDuringWholeTimelineValidation() async throws {
        let bad = PersistedMeasurement(sequence: 2, sessionID: "timeline", kind: "SYSTEM",
            sourceTimestamp: .nan, receivedAtEpoch: 102, receivedAtMonotonicNanos: 2_000_001_000,
            payloadJSON: "{\"name\":\"MARK\"}")
        do { _ = try await MeasurementReplay.timeline(envelope([try signal(1, 10, 100, 1_000), bad])); XCTFail("Invalid recorded time accepted") }
        catch { XCTAssertEqual(error as? MeasurementReplayError, .invalidExport) }
    }

    private actor SeekGate {
        private var continuation: CheckedContinuation<Void, Never>?
        var waiting = false
        func wait() async {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testCancelledSeekCannotReturnAState() async throws {
        let timeline = try await MeasurementReplay.timeline(envelope([try signal(1, 10, 100, 1_000)]))
        let gate = SeekGate()
        let task = Task { await gate.wait(); return try await timeline.snapshot(at: 0) }
        while !(await gate.waiting) { await Task.yield() }
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled seek returned a state") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRowLimitIsEnforcedBeforeASeekCanBePrepared() async throws {
        let rows = [try signal(1, 10, 100, 1_000), try signal(2, 20, 102, 2_000_001_000)]
        do { _ = try await MeasurementReplay.timeline(envelope(rows), maximumRows: 1); XCTFail("Bound silently truncated") }
        catch { XCTAssertEqual(error as? MeasurementReplayError, .rowLimitExceeded) }
        do { _ = try await MeasurementReplay.timeline(envelope(rows), maximumRows: 200_001); XCTFail("Archive bound lifted") }
        catch { XCTAssertEqual(error as? MeasurementReplayError, .rowLimitExceeded) }
    }

    func testEmptyClosedTimelineAndOpenSessionPolicy() async throws {
        let timeline = try await MeasurementReplay.timeline(envelope([]))
        XCTAssertEqual(timeline.duration, 0)
        let empty = try await timeline.snapshot(at: 100)
        XCTAssertTrue(empty.signals.isEmpty)
        XCTAssertNil(empty.markTimestamp)
        XCTAssertEqual(empty.timestamp, 90)
        do { _ = try await MeasurementReplay.timeline(envelope([], endedAt: nil)); XCTFail("Open session accepted") }
        catch { XCTAssertEqual(error as? MeasurementReplayError, .invalidExport) }
    }
}
