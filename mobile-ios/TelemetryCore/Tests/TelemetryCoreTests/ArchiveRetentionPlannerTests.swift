import Foundation
import XCTest
@testable import TelemetryCore
// UNRUN: integrate this file into the native Core test target alongside the proposed Core source.
final class ArchiveRetentionPlannerTests: XCTestCase {
    typealias P = ArchiveRetentionPlanner
    func entry(_ id: String = "a", end: Double? = 0) -> P.Entry { .init(id: id, scope: "car", endedAt: end) }
    func snapshot(_ entries: [P.Entry]? = nil, revision: String = "r1", at: Double = 1000) -> P.Snapshot {
        .init(revision: revision, scope: "car", capturedAt: at, entries: entries ?? [entry()])
    }
    func testExplicitOptIn() throws {
        XCTAssertEqual(try P.plan(snapshot: snapshot(), policy: nil, now: 1000).candidates, [])
    }
    func testCutoffStrict() throws {
        let p = try P.plan(snapshot: snapshot([entry("before", end: 899), entry("exact", end: 900), entry("after", end: 901)]), policy: .elapsed(seconds: 100), now: 1000)
        XCTAssertEqual(p.candidates, ["before"])
        XCTAssertEqual(p.decisions.first(where: { $0.id == "exact" })?.reason, .withinRetention)
    }
    func testProtectedOpenRecoveryRecovered() throws {
        let entries: [P.Entry] = [
            .init(id: "pin", scope: "car", endedAt: 0, protected: true),
            .init(id: "open", scope: "car", endedAt: 0, open: true),
            .init(id: "pending", scope: "car", endedAt: 0, recoveryPending: true),
            .init(id: "recovered", scope: "car", endedAt: 0, recovered: true)]
        let p = try P.plan(snapshot: snapshot(entries), policy: .elapsed(seconds: 100), now: 1000)
        XCTAssertEqual(p.candidates, [])
        XCTAssertEqual(p.decisions.map(\.reason), [.open, .recoveryPending, .protected, .recovered])
    }
    func testMissingInvalidFutureAndZero() throws {
        for end: Double? in [nil, -1, .nan, .infinity, 1001] {
            XCTAssertEqual(try P.plan(snapshot: snapshot([entry(end: end)]), policy: .elapsed(seconds: 100), now: 1000).candidates, [])
        }
        XCTAssertEqual(try P.plan(snapshot: snapshot(), policy: .elapsed(seconds: 100), now: 1000).candidates, ["a"])
    }
    func testDuplicateIDsAndScope() {
        for entries in [[entry(), entry()], [.init(id: "a", scope: "other", endedAt: 0)], [entry("")]] {
            XCTAssertThrowsError(try P.plan(snapshot: snapshot(entries), policy: .elapsed(seconds: 100), now: 1000))
        }
    }
    func testLimits() {
        XCTAssertThrowsError(try P.plan(snapshot: snapshot((0...10000).map { entry(String($0)) }), policy: .elapsed(seconds: 100), now: 1000))
        for amount in [0, -1, 315576001] {
            XCTAssertThrowsError(try P.plan(snapshot: snapshot(), policy: .elapsed(seconds: amount), now: 1000))
        }
    }
    func testRollbackAndExpiredSnapshot() {
        for now in [999.0, 1301, .nan] {
            XCTAssertThrowsError(try P.plan(snapshot: snapshot(), policy: .elapsed(seconds: 100), now: now))
        }
    }
    func testStaleSnapshot() throws {
        let s = snapshot(); let policy = P.Policy.elapsed(seconds: 100)
        let p = try P.plan(snapshot: s, policy: policy, now: 1000)
        XCTAssertTrue(P.validate(p, current: s, policy: policy, now: 1000))
        XCTAssertFalse(P.validate(p, current: snapshot(revision: "r2"), policy: policy, now: 1000))
        XCTAssertFalse(P.validate(p, current: snapshot([.init(id: "a", scope: "car", endedAt: 0, protected: true)]), policy: policy, now: 1000))
        XCTAssertFalse(P.validate(p, current: s, policy: policy, now: 999))
        XCTAssertFalse(P.validate(p, current: s, policy: .elapsed(seconds: 101), now: 1000))
    }
    func testDeterminismAndOriginalIDs() throws {
        let s = snapshot([entry("a"), entry("Z-Original")])
        let p = try P.plan(snapshot: s, policy: .elapsed(seconds: 100), now: 1000)
        XCTAssertEqual(p.candidates, ["Z-Original", "a"])
        XCTAssertEqual(p, try P.plan(snapshot: s, policy: .elapsed(seconds: 100), now: 1000))
    }
    func testKeepAll() throws {
        let p = try P.plan(snapshot: snapshot(), policy: .keepAll, now: 1000)
        XCTAssertEqual(p.candidates, []); XCTAssertEqual(p.decisions.first?.reason, .keepAll)
    }
    func testCalendarDSTNotElapsed() throws {
        let now = 1710129600.0
        let s = snapshot([entry(end: 1710045000)], at: now)
        let p = try P.plan(snapshot: s, policy: .calendarDays(1, timeZoneID: "America/New_York"), now: now)
        XCTAssertEqual(p.cutoff, 1710046800); XCTAssertEqual(p.candidates, ["a"])
        XCTAssertEqual(try P.plan(snapshot: s, policy: .elapsed(seconds: 86400), now: now).candidates, [])
    }
    func testTimezoneAndCalendarBounds() {
        for policy: P.Policy in [.calendarDays(1, timeZoneID: "fake"), .calendarDays(0, timeZoneID: "UTC"), .calendarDays(3651, timeZoneID: "UTC")] {
            XCTAssertThrowsError(try P.plan(snapshot: snapshot(), policy: policy, now: 1000))
        }
        // Unknown policy kinds, missing zones and bool-as-number are unrepresentable in this typed API.
    }
    func testSnapshotMetadataBounds() {
        for s: P.Snapshot in [.init(revision: "", scope: "car", capturedAt: 1000, entries: []),
                              .init(revision: "r", scope: "", capturedAt: 1000, entries: []), snapshot(at: -1)] {
            XCTAssertThrowsError(try P.plan(snapshot: s, policy: .elapsed(seconds: 100), now: 1000))
        }
    }
}
