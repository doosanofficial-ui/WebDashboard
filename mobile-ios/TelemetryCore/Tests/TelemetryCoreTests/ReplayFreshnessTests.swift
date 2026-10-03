import Foundation
import XCTest
@testable import TelemetryCore

final class ReplayFreshnessTests: XCTestCase {
    private func signal(_ seq: Int64, id: String, epoch: Double, mono: UInt64) throws -> PersistedMeasurement {
        let s = DecodedSignalSample(signalID: id, value: 42, rawValue: 42, enumName: nil, unit: "%",
            frameSequence: UInt64(seq), receivedAtEpoch: epoch, receivedAtMonotonicNanos: mono, source: .diagnostic)
        return .init(sequence: seq, sessionID: "freshness", kind: "SIGNAL", sourceTimestamp: epoch,
            receivedAtEpoch: epoch, receivedAtMonotonicNanos: mono, payloadJSON: String(decoding: try JSONEncoder().encode(s), as: UTF8.self))
    }
    private func fixture() throws -> MeasurementExport {
        let mark = PersistedMeasurement(sequence: 3, sessionID: "freshness", kind: "SYSTEM", sourceTimestamp: 20,
            receivedAtEpoch: 20, receivedAtMonotonicNanos: 100_000_000_000, payloadJSON: "{\"name\":\"MARK\"}")
        return .init(session: .init(sessionID: "freshness", startedAt: 0, endedAt: 110, mode: .demo),
            measurements: [try signal(1,id:"soc",epoch:100,mono:0),try signal(2,id:"later",epoch:50,mono:40_000_000_000),mark])
    }
    func testLongGapUsesRequestedMonotonicPositionAndKeepsOriginalSignalState() async throws {
        let t = try await MeasurementReplay.timeline(fixture(), signalTimeouts: ["soc":1,"later":20])
        let s = try await t.snapshot(at: 50)
        XCTAssertEqual(s.signalFreshness["soc"], .stale)
        XCTAssertEqual(s.signalFreshness["later"], .fresh)
        XCTAssertEqual(s.signalAges["soc"],50)
        XCTAssertEqual(s.signalAges["later"],10)
        XCTAssertEqual(s.signals.first{$0.signalID == "soc"}?.quality,.valid, "Recorded validity is separate from derived freshness")
        XCTAssertEqual(s.signals.first{$0.signalID == "soc"}?.receivedAtEpoch,100)
        XCTAssertEqual(s.signals.first{$0.signalID == "later"}?.receivedAtEpoch,50)
        XCTAssertNil(s.markTimestamp)
    }
    func testBackwardSeekRestoresFreshnessAndDropsFutureSignalWithWallClockRollback() async throws {
        let t = try await MeasurementReplay.timeline(fixture(), signalTimeouts:["soc":1,"later":20])
        let end = try await t.snapshot(at:100)
        XCTAssertEqual(end.signalFreshness["soc"],.stale)
        XCTAssertEqual(end.markTimestamp,20)
        let start = try await t.snapshot(at:0)
        XCTAssertEqual(start.signalFreshness["soc"],.fresh)
        XCTAssertEqual(start.signalAges["soc"],0)
        XCTAssertNil(start.signalFreshness["later"])
        XCTAssertNil(start.markTimestamp)
    }
    func testMissingPolicyIsUnknownAndInvalidPoliciesAreRejected() async throws {
        let t = try await MeasurementReplay.timeline(fixture())
        let s = try await t.snapshot(at:50)
        XCTAssertEqual(s.signalFreshness["soc"],.unknown)
        XCTAssertEqual(s.signalFreshness["later"],.unknown)
        for timeout in [0.0,-1,Double.nan,Double.infinity] {
            do { _ = try await MeasurementReplay.timeline(fixture(), signalTimeouts:["soc":timeout]);XCTFail("Invalid policy accepted") }
            catch { XCTAssertEqual(error as? MeasurementReplayError,.invalidExport) }
        }
    }
}
