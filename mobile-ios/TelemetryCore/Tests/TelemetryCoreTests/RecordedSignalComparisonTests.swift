import Foundation
import XCTest
@testable import TelemetryCore

final class RecordedSignalComparisonTests: XCTestCase {
    private func signal(_ sequence: Int64, id: String, value: Double, seconds: UInt64,
                        unit: String, source: TelemetrySource = .diagnostic) throws -> PersistedMeasurement {
        let epoch = 100 - Double(seconds) // A wall-clock rollback must not align the plots.
        let nanos = seconds * 1_000_000_000
        let sample = DecodedSignalSample(signalID: id, value: value, rawValue: UInt64(sequence),
            enumName: nil, unit: unit, frameSequence: UInt64(sequence), receivedAtEpoch: epoch,
            receivedAtMonotonicNanos: nanos, source: source)
        return .init(sequence: sequence, sessionID: "comparison", kind: "SIGNAL",
            sourceTimestamp: epoch, receivedAtEpoch: epoch, receivedAtMonotonicNanos: nanos,
            payloadJSON: String(decoding: try JSONEncoder().encode(sample), as: UTF8.self))
    }

    private func fixture() throws -> MeasurementExport {
        .init(session: .init(sessionID: "comparison", startedAt: 80, endedAt: 110, mode: .demo),
            measurements: [
                try signal(1, id: "rpm", value: 0, seconds: 0, unit: "rpm"),
                try signal(2, id: "soc", value: 48, seconds: 1, unit: "%"),
                try signal(3, id: "rpm", value: 1200, seconds: 5, unit: "rpm"),
                try signal(4, id: "soc", value: 49, seconds: 9, unit: "%", source: .rawCAN),
                try signal(5, id: "rpm", value: 1800, seconds: 10, unit: "rpm")])
    }

    private func comparison(_ timeline: MeasurementReplay.Timeline, at seconds: Double,
                            ids: [String] = ["rpm", "soc"]) async throws -> RecordedSignalComparison {
        let snapshot = try await timeline.snapshot(at: seconds)
        return try RecordedSignalComparison(sessionID: timeline.sessionID, signalIDs: ids,
            at: seconds, snapshot: snapshot) { try timeline.signalHistory(signalID: $0, at: seconds) }
    }

    func testSelectionIsBoundedDeterministicAndRejectsInvalidOrDuplicateIDs() {
        var selection = RecordedSignalComparison.Selection()
        selection.observe(sessionID: "a", signalIDs: ["rpm", "", "soc", "rpm", " ", "voltage"])
        XCTAssertEqual(selection.availableSignalIDs, ["rpm", "soc", "voltage"])
        selection.selectSecondary("soc", primarySignalID: "rpm")
        XCTAssertEqual(selection.signalIDs(primarySignalID: "rpm"), ["rpm", "soc"])
        selection.selectSecondary("rpm", primarySignalID: "rpm")
        XCTAssertNil(selection.secondarySignalID)
        selection.selectSecondary("missing", primarySignalID: "rpm")
        XCTAssertNil(selection.secondarySignalID)
        selection.selectSecondary("soc", primarySignalID: "rpm")
        XCTAssertTrue(selection.signalIDs(primarySignalID: "missing").isEmpty)
        XCTAssertEqual(RecordedSignalComparison.normalizedSignalIDs(["rpm", "rpm", "", " ", "soc", "voltage"]),
                       ["rpm", "soc"])
    }

    func testSelectionSurvivesBackwardSeekButResetsForAnotherSessionOrStop() {
        var selection = RecordedSignalComparison.Selection()
        selection.observe(sessionID: "a", signalIDs: ["rpm", "soc"])
        selection.selectSecondary("soc", primarySignalID: "rpm")
        selection.observe(sessionID: "a", signalIDs: ["rpm"])
        XCTAssertEqual(selection.availableSignalIDs, ["rpm", "soc"])
        XCTAssertEqual(selection.signalIDs(primarySignalID: "rpm"), ["rpm", "soc"])
        selection.observe(sessionID: "b", signalIDs: ["voltage"])
        XCTAssertEqual(selection.availableSignalIDs, ["voltage"])
        XCTAssertNil(selection.secondarySignalID)
        selection.observe(sessionID: nil, signalIDs: ["rpm"])
        XCTAssertTrue(selection.availableSignalIDs.isEmpty)
        XCTAssertNil(selection.secondarySignalID)
    }

    func testImplicitPrimarySurvivesBackwardSeekBeforeItsFirstSample() async throws {
        let original = MeasurementExport(session: .init(sessionID: "comparison", startedAt: 80,
            endedAt: 110, mode: .demo), measurements: [
                try signal(1, id: "z_early", value: 48, seconds: 0, unit: "%"),
                try signal(2, id: "a_later", value: 1200, seconds: 5, unit: "rpm")])
        let timeline = try await MeasurementReplay.timeline(original)
        let end = try await timeline.snapshot(at: 5)
        var selection = RecordedSignalComparison.Selection()
        selection.observe(sessionID: "comparison", signalIDs: end.signals.map(\.signalID).sorted())
        selection.selectSecondary("z_early", primarySignalID: "a_later")
        let back = try await timeline.snapshot(at: 0)
        selection.observe(sessionID: "comparison", signalIDs: back.signals.map(\.signalID).sorted())
        // No explicit primary picker selection preceded the comparison.
        let ids = selection.signalIDs(primarySignalID: nil)
        XCTAssertEqual(ids, ["a_later", "z_early"])
        let selected = try await comparison(timeline, at: 0, ids: ids)
        let primary = try XCTUnwrap(selected.series.first)
        XCTAssertEqual(primary.signalID, "a_later")
        XCTAssertTrue(primary.history?.samples.isEmpty == true)
        XCTAssertNil(primary.cursorState)
        XCTAssertEqual(selected.series.last?.history?.samples.map(\.value), [48])
    }

    func testHistoriesShareAcceptedCursorAndKeepUnequalSampleTimesAndMissingGaps() async throws {
        let timeline = try await MeasurementReplay.timeline(fixture())
        let selected = try await comparison(timeline, at: 7)
        XCTAssertEqual(selected.position, 7)
        XCTAssertEqual(selected.series.map(\.signalID), ["rpm", "soc"])
        XCTAssertEqual(selected.series.compactMap { $0.history?.startSeconds }, [0, 0])
        XCTAssertEqual(selected.series.compactMap { $0.history?.endSeconds }, [7, 7])
        XCTAssertEqual(selected.series[0].history?.samples.map(\.elapsedSeconds), [0, 5])
        XCTAssertEqual(selected.series[1].history?.samples.map(\.elapsedSeconds), [1])
        XCTAssertEqual(selected.series[0].history?.samples.map(\.value), [0, 1200])
        XCTAssertEqual(selected.series[1].units, ["%"])
        XCTAssertEqual(selected.series[0].units, ["rpm"])
        XCTAssertEqual(selected.series[0].cursorState?.value, 1200)
        let back = try await comparison(timeline, at: 0)
        XCTAssertTrue(back.series[1].history?.samples.isEmpty == true)
        XCTAssertNil(back.series[1].cursorState, "An absent sample must not become zero or a future value")
        XCTAssertNil(back.series[1].cursorFreshness)
        XCTAssertEqual(back.series[0].history?.samples.map(\.value), [0], "A recorded zero is still a sample")
    }

    func testCursorQualityAndFreshnessAreSeparateFromUnchangedHistoricalRows() async throws {
        let original = try fixture()
        let timeline = try await MeasurementReplay.timeline(original, signalTimeouts: ["rpm": 1, "soc": 20])
        let selected = try await comparison(timeline, at: 7)
        XCTAssertEqual(selected.series[0].cursorState?.quality, .valid)
        XCTAssertEqual(selected.series[0].cursorFreshness, .stale)
        XCTAssertEqual(selected.series[1].cursorFreshness, .fresh)
        XCTAssertEqual(selected.series[0].history?.samples.map(\.measurement),
                       [original.measurements[0], original.measurements[2]])
        let unknownTimeline = try await MeasurementReplay.timeline(original)
        let unknown = try await comparison(unknownTimeline, at: 7)
        XCTAssertEqual(unknown.series[0].cursorFreshness, .unknown)
        XCTAssertEqual(unknown.series[1].cursorFreshness, .unknown)
    }

    func testInvalidCursorQualityIsRetainedWithoutInventingAPlottableZero() throws {
        let invalid = LatestSignalState(signalID: "rpm", value: nil, rawValue: nil, enumName: nil,
            unit: "rpm", quality: .invalid, frameSequence: 1, receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 0, source: .diagnostic)
        let snapshot = MeasurementReplay.Snapshot(timestamp: 100, signals: [invalid], frame: nil,
            diagnostic: nil, location: nil, markTimestamp: nil, signalAges: [:],
            signalFreshness: ["rpm": .unknown])
        let selected = try RecordedSignalComparison(sessionID: "comparison", signalIDs: ["rpm", "soc"],
            at: 0, snapshot: snapshot) { _ in nil }
        XCTAssertEqual(selected.series[0].cursorState?.quality, .invalid)
        XCTAssertNil(selected.series[0].cursorState?.value)
        XCTAssertNil(selected.series[0].history)
        XCTAssertNil(selected.series[1].cursorState)
    }

    func testComparisonDoesNotModifyAnyRawRowOrExportBytesAndRetainsSourceChanges() async throws {
        let original = try fixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(original)
        let timeline = try await MeasurementReplay.timeline(original)
        let selected = try await comparison(timeline, at: timeline.duration)
        XCTAssertEqual(selected.series.flatMap { $0.history?.samples ?? [] }.map(\.measurement)
            .sorted { $0.sequence < $1.sequence }, original.measurements)
        XCTAssertEqual(selected.series[1].history?.samples.map(\.sourceSegment), [0, 1])
        XCTAssertEqual(try encoder.encode(original), bytes)
        XCTAssertEqual(timeline.measurementCount, original.measurements.count)
    }

    func testComparisonRetainsUnitChangesWithoutCombiningScales() async throws {
        var original = try fixture()
        let rows = original.measurements + [try signal(6, id: "soc", value: 0.5, seconds: 11, unit: "ratio")]
        original = .init(session: original.session, measurements: rows)
        let timeline = try await MeasurementReplay.timeline(original)
        let selected = try await comparison(timeline, at: 11)
        XCTAssertEqual(selected.series[1].units, ["%", "ratio"])
        XCTAssertEqual(selected.series[1].history?.samples.map(\.unit), ["%", "%", "ratio"])
        XCTAssertEqual(selected.series[1].history?.samples.map(\.measurement), [rows[1], rows[3], rows[5]])
    }

    func testHistoryCapsRemainPerSignalAndPreserveOriginalCounts() async throws {
        let rows: [PersistedMeasurement] = try (0..<1400).map { index in
            try signal(Int64(index + 1), id: index.isMultiple(of: 2) ? "rpm" : "soc",
                       value: Double(index), seconds: UInt64(index / 200), unit: index.isMultiple(of: 2) ? "rpm" : "%")
        }
        let timeline = try await MeasurementReplay.timeline(.init(
            session: .init(sessionID: "comparison", startedAt: 0, endedAt: 100, mode: .demo), measurements: rows))
        let selected = try await comparison(timeline, at: timeline.duration)
        XCTAssertEqual(selected.series.compactMap { $0.history?.samples.count }, [600, 600])
        XCTAssertEqual(selected.series.compactMap { $0.history?.totalSamplesInWindow }, [700, 700])
        XCTAssertTrue(selected.series.allSatisfy { $0.history?.truncated == true })
        XCTAssertEqual(timeline.measurementCount, 1400)
    }

    func testMismatchedCursorWindowSessionAndNonfinitePositionAreRejected() async throws {
        let timeline = try await MeasurementReplay.timeline(fixture())
        let snapshot = try await timeline.snapshot(at: 7)
        XCTAssertThrowsError(try RecordedSignalComparison(sessionID: "comparison", signalIDs: ["rpm", "soc"],
            at: 7, snapshot: snapshot) { try timeline.signalHistory(signalID: $0, at: 8) })
        XCTAssertThrowsError(try RecordedSignalComparison(sessionID: "comparison", signalIDs: ["rpm", "soc"],
            at: 7, snapshot: snapshot) { try timeline.signalHistory(signalID: $0, at: 7, windowSeconds: $0 == "rpm" ? 1 : 2) })
        XCTAssertThrowsError(try RecordedSignalComparison(sessionID: "other", signalIDs: ["rpm"],
            at: 7, snapshot: snapshot) { try timeline.signalHistory(signalID: $0, at: 7) })
        for position in [Double.nan, Double.infinity, -1] {
            XCTAssertThrowsError(try RecordedSignalComparison(sessionID: "comparison", signalIDs: ["rpm"],
                at: position, snapshot: snapshot) { _ in nil })
        }
    }
}
