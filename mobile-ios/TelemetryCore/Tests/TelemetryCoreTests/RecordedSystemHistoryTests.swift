import Foundation
import XCTest
@testable import TelemetryCore

final class RecordedSystemHistoryTests: XCTestCase {
    private func row(_ sequence: Int64, nanos: UInt64, payload: String = "{\"name\":\"MARK\"}") -> PersistedMeasurement {
        .init(sequence: sequence, sessionID: "audit-fixture", kind: "SYSTEM",
              sourceTimestamp: 100, receivedAtEpoch: 100,
              receivedAtMonotonicNanos: nanos, payloadJSON: payload)
    }

    private func timeline(_ rows: [PersistedMeasurement]) async throws -> MeasurementReplay.Timeline {
        try await MeasurementReplay.timeline(.init(session: .init(sessionID: "audit-fixture",
            startedAt: 100, endedAt: 200, mode: .demo), measurements: rows))
    }

    func testSelectedPrefixRetainsExactPayloadsAndSharedOriginalOrigin() async throws {
        let queued = row(1, nanos: 5_000_000_000,
            payload: "{\"name\":\"diagnostic_audit_v1\",\"diagnosticAudit\":{\"opaque\":\"original\"}}")
        let terminal = row(2, nanos: 7_000_000_000,
            payload: "{\"name\":\"future-terminal\"}")
        let t = try await timeline([queued, terminal])
        XCTAssertEqual(t.recordedMonotonicOrigin, 5_000_000_000)
        XCTAssertEqual(try t.systemHistory(at: 1).samples, [queued])
        XCTAssertEqual(try t.systemHistory(at: 2).samples, [queued, terminal])
        XCTAssertEqual(try t.systemHistory(at: 0).samples, [queued])
        XCTAssertEqual(try t.systemHistory(at: 2).samples.first?.payloadJSON, queued.payloadJSON)
    }

    func testOriginalTimeRollbackIsNotRewrittenByDisplayPrefix() async throws {
        let rows = [row(1, nanos: 10), row(2, nanos: 20), row(3, nanos: 15)]
        let t = try await timeline(rows)
        XCTAssertEqual(t.recordedMonotonicOrigin, 10)
        XCTAssertEqual(try t.systemHistory(at: t.duration).samples.map(\.receivedAtMonotonicNanos), [10, 20, 15])
    }

    func testCapCountsOriginalSystemRowsAndDisclosesTruncation() async throws {
        let rows = (0..<605).map { row(Int64($0 + 1), nanos: UInt64($0) * 1_000_000_000) }
        let t = try await timeline(rows)
        let history = try t.systemHistory(at: t.duration)
        XCTAssertEqual(history.totalRowsInPrefix, 605)
        XCTAssertEqual(history.samples.count, 600)
        XCTAssertTrue(history.truncated)
        XCTAssertEqual(history.samples.first?.sequence, 6)
        XCTAssertEqual(try t.systemHistory(at: 1, maximumSamples: 1).samples, [rows[1]])
    }

    func testRejectsInvalidQueriesAndEmptyHistoryHasNoInventedOrigin() async throws {
        let t = try await timeline([])
        XCTAssertNil(t.recordedMonotonicOrigin)
        XCTAssertTrue(try t.systemHistory(at: 0).samples.isEmpty)
        for time in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try t.systemHistory(at: time))
        }
        XCTAssertThrowsError(try t.systemHistory(at: 0, maximumSamples: 0))
        XCTAssertThrowsError(try t.systemHistory(at: 0, maximumSamples: 601))
    }
}
