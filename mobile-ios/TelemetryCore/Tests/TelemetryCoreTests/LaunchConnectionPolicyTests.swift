import XCTest
@testable import TelemetryCore

final class LaunchConnectionPolicyTests: XCTestCase {
    typealias P = LaunchConnectionPolicy
    func evidence(profile: String = "p", fingerprint: String = "f", launch: String = "l",
                  session: String = "s", generation: UInt64 = 1, foreground: Bool = true,
                  permissions: Bool = true, observed: Bool = true, idle: Bool = true,
                  captured: TimeInterval = 10) -> P.Evidence {
        .init(profile: profile, fingerprint: fingerprint, launch: launch, session: session,
              generation: generation, foreground: foreground, permissions: permissions,
              observed: observed, idle: idle, captured: captured)
    }
    func policy(enabled: Bool = true, state: P.State = .ready, instance: String = "i") -> P {
        .init(instance: instance, grant: .init(profile: "p", fingerprint: "f", generation: 1,
                                             enabled: enabled), restoredLedger: state)
    }
    func testExactIntent() throws {
        var p = policy(); let e = evidence(); let i = try XCTUnwrap(p.propose(e, now: 10))
        XCTAssertEqual(i.evidence, e); XCTAssertEqual(i.instance, "i"); XCTAssertEqual(p.state, .pending)
    }
    func testManualDefault() {
        var p = policy(enabled: false); XCTAssertNil(p.propose(evidence(), now: 10))
        var unknown = P(instance: "i", grant: .init(profile: "p", fingerprint: "f", generation: 1, enabled: true))
        XCTAssertNil(unknown.propose(evidence(), now: 10))
    }
    func testRestoredConsumedLedger() {
        for state: P.State in [.unknown, .pending, .uncertain, .suppressed, .complete, .refused, .reconciled] {
            var p = policy(state: state); XCTAssertNil(p.propose(evidence(), now: 10))
        }
    }
    func testRejectsChangedUnknownOrDeniedEvidence() {
        let cases = [evidence(profile: "new"), evidence(fingerprint: "new"), evidence(launch: ""),
                     evidence(session: ""), evidence(generation: 2), evidence(foreground: false),
                     evidence(permissions: false), evidence(observed: false), evidence(idle: false)]
        for e in cases {
            var p = policy(); XCTAssertNil(p.propose(e, now: 10)); XCTAssertEqual(p.state, .suppressed)
            XCTAssertNil(p.propose(evidence(), now: 10))
        }
    }
    func testInvalidTimes() {
        for time in [7.99, 11, -.infinity, .infinity, .nan] {
            var p = policy(); XCTAssertNil(p.propose(evidence(captured: time), now: 10))
        }
        for time in [-1.0, .nan, .infinity] {
            var p = policy(); XCTAssertNil(p.propose(evidence(), now: time))
        }
        var p = policy(); XCTAssertNotNil(p.propose(evidence(), now: 12))
    }
    func testEmptyGrantAndInstance() {
        for g in [P.Grant(profile: "", fingerprint: "f", generation: 1, enabled: true),
                  P.Grant(profile: "p", fingerprint: "", generation: 1, enabled: true),
                  P.Grant(profile: "p", fingerprint: "f", generation: 0, enabled: true)] {
            var p = P(instance: "i", grant: g, restoredLedger: .ready)
            XCTAssertNil(p.propose(evidence(), now: 10))
        }
        var p = policy(instance: ""); XCTAssertNil(p.propose(evidence(), now: 10))
    }
    func testSingleIntent() {
        var p = policy(); XCTAssertNotNil(p.propose(evidence(), now: 10))
        XCTAssertNil(p.propose(evidence(launch: "new"), now: 10))
    }
    func testReservationRequired() throws {
        var p = policy(); let e = evidence(); let i = try XCTUnwrap(p.propose(e, now: 10))
        XCTAssertFalse(p.canExecute(i, evidence: e, now: 10, reservationCommitted: false))
        XCTAssertTrue(p.canExecute(i, evidence: e, now: 10, reservationCommitted: true))
    }
    func testDispatchRevalidation() throws {
        var p = policy(); let i = try XCTUnwrap(p.propose(evidence(), now: 10))
        for e in [evidence(launch: "new"), evidence(session: "new"), evidence(generation: 2),
                  evidence(profile: "new"), evidence(fingerprint: "new"), evidence(foreground: false),
                  evidence(permissions: false), evidence(observed: false), evidence(idle: false)] {
            XCTAssertFalse(p.canExecute(i, evidence: e, now: 10, reservationCommitted: true))
        }
        XCTAssertFalse(p.canExecute(i, evidence: evidence(), now: 12.01, reservationCommitted: true))
    }
    func testForeignAcknowledgment() throws {
        var p = policy(); _ = p.propose(evidence(), now: 10)
        var other = policy(instance: "other"); let i = try XCTUnwrap(other.propose(evidence(), now: 10))
        XCTAssertFalse(p.acknowledge(i, outcome: .accepted)); XCTAssertEqual(p.state, .pending)
        XCTAssertFalse(p.canExecute(i, evidence: evidence(), now: 10, reservationCommitted: true))
    }
    func testEveryOutcomeConsumedAcrossRestart() throws {
        let pairs: [(P.Acknowledgment, P.State)] = [(.accepted, .complete), (.refused, .refused), (.uncertain, .uncertain)]
        for (outcome, state) in pairs {
            var p = policy(); let i = try XCTUnwrap(p.propose(evidence(), now: 10))
            XCTAssertTrue(p.acknowledge(i, outcome: outcome)); XCTAssertEqual(p.state, state)
            XCTAssertFalse(p.acknowledge(i, outcome: .accepted)); XCTAssertNil(p.propose(evidence(), now: 10))
            var restarted = policy(state: state, instance: "restart")
            XCTAssertNil(restarted.propose(evidence(), now: 10))
        }
    }
    func testManualStopPending() throws {
        var p = policy(); let i = try XCTUnwrap(p.propose(evidence(), now: 10)); p.suppress()
        XCTAssertEqual(p.state, .uncertain); XCTAssertFalse(p.acknowledge(i, outcome: .accepted))
        XCTAssertFalse(p.canExecute(i, evidence: evidence(), now: 10, reservationCommitted: true))
    }
    func testManualStopBeforeIntent() {
        var p = policy(); p.suppress(); XCTAssertEqual(p.state, .suppressed)
        XCTAssertNil(p.propose(evidence(), now: 10))
    }
    func testFencedReconciliationNeverRearms() throws {
        var p = policy(); let i = try XCTUnwrap(p.propose(evidence(), now: 10))
        XCTAssertTrue(p.acknowledge(i, outcome: .uncertain))
        XCTAssertFalse(p.reconcile(i, olderWorkFenced: false))
        var other = policy(instance: "other"); let foreign = try XCTUnwrap(other.propose(evidence(), now: 10))
        XCTAssertFalse(p.reconcile(foreign, olderWorkFenced: true))
        XCTAssertTrue(p.reconcile(i, olderWorkFenced: true)); XCTAssertEqual(p.state, .reconciled)
        XCTAssertFalse(p.reconcile(i, olderWorkFenced: true)); XCTAssertNil(p.propose(evidence(), now: 10))
    }
    func futurePolicy(bound: Int = 2, used: Set<String> = []) -> P {
        .init(instance: "i", grant: .init(profile: "p", fingerprint: "f", generation: 1,
                                        enabled: true, futureLaunches: true, maxAttempts: bound),
              restoredLedger: .ready, restoredUsedLaunches: used)
    }
    func testFutureNeedsClosureNotAcceptance() throws {
        var p = futurePolicy(); let i = try XCTUnwrap(p.propose(evidence(), now: 10))
        XCTAssertTrue(p.acknowledge(i, outcome: .accepted))
        XCTAssertNil(p.propose(evidence(launch: "next"), now: 10))
        XCTAssertFalse(p.close(i, authoritativeClosed: false))
        XCTAssertTrue(p.close(i, authoritativeClosed: true))
        XCTAssertNotNil(p.propose(evidence(launch: "next"), now: 10))
    }
    func testFutureBudgetAndLaunchDedup() throws {
        var p = futurePolicy(); let i = try XCTUnwrap(p.propose(evidence(), now: 10))
        p.acknowledge(i, outcome: .accepted); p.close(i, authoritativeClosed: true)
        XCTAssertNil(p.propose(evidence(), now: 10))
        let j = try XCTUnwrap(p.propose(evidence(launch: "next"), now: 10))
        p.acknowledge(j, outcome: .accepted); p.close(j, authoritativeClosed: true)
        XCTAssertNil(p.propose(evidence(launch: "third"), now: 10))
    }
    func testOneShotClosureDoesNotRearm() throws {
        var p = policy(); let i = try XCTUnwrap(p.propose(evidence(), now: 10))
        p.acknowledge(i, outcome: .accepted); XCTAssertTrue(p.close(i, authoritativeClosed: true))
        XCTAssertEqual(p.state, .complete)
        XCTAssertNil(p.propose(evidence(launch: "next"), now: 10))
    }
    func testFutureClosureExactAndTerminal() throws {
        var p = futurePolicy(); let i = try XCTUnwrap(p.propose(evidence(), now: 10))
        XCTAssertFalse(p.close(i, authoritativeClosed: true))
        var other = policy(instance: "other"); let foreign = try XCTUnwrap(other.propose(evidence(), now: 10))
        p.acknowledge(i, outcome: .accepted); XCTAssertFalse(p.close(foreign, authoritativeClosed: true))
        XCTAssertTrue(p.close(i, authoritativeClosed: true)); XCTAssertFalse(p.close(i, authoritativeClosed: true))
        let j = try XCTUnwrap(p.propose(evidence(launch: "next"), now: 10))
        p.acknowledge(j, outcome: .uncertain); XCTAssertFalse(p.close(j, authoritativeClosed: true))
        p.reconcile(j, olderWorkFenced: true); XCTAssertNil(p.propose(evidence(launch: "third"), now: 10))
    }
    func testFutureRestoredHistoryPreservesBudget() throws {
        var p = futurePolicy(used: ["l"]); XCTAssertNil(p.propose(evidence(), now: 10))
        let i = try XCTUnwrap(p.propose(evidence(launch: "next"), now: 10))
        p.acknowledge(i, outcome: .accepted); p.close(i, authoritativeClosed: true)
        var restored = futurePolicy(used: p.usedLaunches)
        XCTAssertNil(restored.propose(evidence(launch: "third"), now: 10))
    }
    func testFutureInvalidBounds() {
        for bound in [-1, 0, 33] {
            var p = futurePolicy(bound: bound); XCTAssertNil(p.propose(evidence(), now: 10))
        }
    }
    func testFutureRefusalAndStopCannotCloseOrRearm() throws {
        for stop in [false, true] {
            var p = futurePolicy(); let i = try XCTUnwrap(p.propose(evidence(), now: 10))
            if stop { p.suppress() } else { p.acknowledge(i, outcome: .refused) }
            XCTAssertFalse(p.close(i, authoritativeClosed: true))
            XCTAssertNil(p.propose(evidence(launch: "next"), now: 10))
        }
    }

    func testFutureDuplicateLaunchRevocationLatches() throws {
        var p = futurePolicy(); let i = try XCTUnwrap(p.propose(evidence(), now: 10))
        p.acknowledge(i, outcome: .accepted); p.close(i, authoritativeClosed: true)
        XCTAssertNil(p.propose(evidence(permissions: false), now: 10))
        XCTAssertEqual(p.state, .suppressed)
        XCTAssertNil(p.propose(evidence(launch: "next"), now: 10))
    }

}
