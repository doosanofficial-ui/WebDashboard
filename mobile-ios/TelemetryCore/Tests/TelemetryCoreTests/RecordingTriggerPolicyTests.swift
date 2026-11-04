import XCTest
@testable import TelemetryCore

/// Prepared mirror only. NOT compiled or run in this task.
final class RecordingTriggerPolicyTests: XCTestCase {
    typealias Policy = RecordingTriggerPolicy
    func make() -> Policy { Policy(instance: "instance-A", source: "adapter-A", session: "session-A", permitted: true)! }
    func ready(_ inactivity: Double? = nil) -> Policy {
        var p = make(); p.reconnect(now: 0)
        XCTAssertTrue(p.arm(now: 1, explicit: true, inactivity: inactivity)); return p
    }
    func sample(_ p: inout Policy, _ now: Double = 2, captured: Double? = nil, source: String = "adapter-A", session: String = "session-A", generation: UInt64? = nil, quality: String = "qualified", values: [Double] = [0], demo: Bool = false) -> Policy.Intent? {
        let epoch = generation ?? p.generation
        return p.telemetry(now: now, captured: captured ?? now, source: source, session: session, generation: epoch, quality: quality, values: values, demo: demo)
    }
    func running(_ inactivity: Double? = nil) throws -> Policy {
        var p = ready(inactivity); let i = try XCTUnwrap(sample(&p)); XCTAssertTrue(p.ack(i, accepted: true, now: 2.1)); return p
    }
    func testDefaultOffAndRestartCannotTrigger() {
        var p = make(); p.reconnect(now: 0); XCTAssertNil(sample(&p)); XCTAssertEqual(p.state, .off)
    }
    func testArmRequiresExplicitConnectedPermission() {
        var p = make(); XCTAssertFalse(p.arm(now: 1, explicit: true)); p.reconnect(now: 1)
        XCTAssertFalse(p.arm(now: 1)); _ = p.permission(false, now: 1); XCTAssertFalse(p.arm(now: 1, explicit: true))
    }
    func testStartPendingIsNotRecordingAndOnce() throws {
        var p = ready(); let i = try XCTUnwrap(sample(&p)); XCTAssertEqual(i.action, .start); XCTAssertEqual(p.state, .startPending)
        XCTAssertNil(sample(&p, 2.1)); XCTAssertTrue(p.ack(i, accepted: true, now: 2.2)); XCTAssertEqual(p.state, .recording)
        XCTAssertFalse(p.ack(i, accepted: true, now: 2.3))
    }
    func testDenialRequiresNewExplicitArm() throws {
        var p = ready(); let i = try XCTUnwrap(sample(&p)); XCTAssertTrue(p.ack(i, accepted: false, now: 2.1))
        XCTAssertEqual(p.state, .off); XCTAssertNil(sample(&p, 3))
    }
    func testDisarmPendingRejectsDelayedSuccess() throws {
        var p = ready(); let i = try XCTUnwrap(sample(&p)); p.disarm(now: 2.1)
        XCTAssertEqual(p.state, .uncertain); XCTAssertFalse(p.ack(i, accepted: true, now: 2.2)); XCTAssertFalse(p.arm(now: 3, explicit: true))
    }
    func testDisarmArmedOff() {
        var p = ready(); p.disarm(now: 2); XCTAssertNil(sample(&p, 3)); XCTAssertEqual(p.state, .off)
    }
    func testDisarmRunningDoesNotStopOrInventIdle() throws {
        var p = try running(5); p.disarm(now: 3); XCTAssertEqual(p.state, .recording); XCTAssertNil(p.tick(now: 30))
    }
    func testManualRecordingNeverStopped() {
        var p = ready(5); p.manual(true, now: 2); XCTAssertNil(p.stop(now: 3)); XCTAssertNil(p.permission(false, now: 4))
        XCTAssertNil(p.tick(now: 40)); XCTAssertEqual(p.state, .manual); XCTAssertFalse(p.arm(now: 41, explicit: true))
    }
    func testManualTakeoverInvalidatesPending() throws {
        var p = ready(); let i = try XCTUnwrap(sample(&p)); p.manual(true, now: 2.1)
        XCTAssertFalse(p.ack(i, accepted: true, now: 2.2)); XCTAssertEqual(p.state, .manual)
        p.manual(false, now: 3); XCTAssertNil(sample(&p, 4))
    }
    func testReconnectDisarmsAndGenerationFencesOldData() {
        var p = ready(); let old = p.generation; p.disconnect(now: 2); p.reconnect(now: 3)
        XCTAssertNil(sample(&p, 4)); XCTAssertTrue(p.arm(now: 5, explicit: true))
        XCTAssertNil(sample(&p, 6, generation: old)); XCTAssertNotNil(sample(&p, 6))
    }
    func testReconnectPendingNeedsIdleReconciliation() throws {
        var p = ready(); let i = try XCTUnwrap(sample(&p)); p.disconnect(now: 2.1); p.reconnect(now: 3)
        XCTAssertFalse(p.ack(i, accepted: true, now: 4)); XCTAssertFalse(p.arm(now: 4, explicit: true))
        let epoch = p.generation
        XCTAssertFalse(p.confirmIdle(instance: "wrong", generation: epoch, now: 4))
        XCTAssertFalse(p.confirmIdle(instance: "instance-A", generation: epoch - 1, now: 4))
        XCTAssertTrue(p.confirmIdle(instance: "instance-A", generation: epoch, now: 4))
        XCTAssertNil(sample(&p, 5)); XCTAssertTrue(p.arm(now: 5, explicit: true))
    }
    func testRevocationStopsOnlyAcknowledgedPolicyRecordingOnce() throws {
        var p = try running(); let i = try XCTUnwrap(p.permission(false, now: 3))
        XCTAssertEqual(i.action, .stop); XCTAssertEqual(i.reason, .permissionRevoked)
        XCTAssertNil(p.permission(false, now: 4)); XCTAssertTrue(p.ack(i, accepted: true, now: 4))
        _ = p.permission(true, now: 5); XCTAssertNil(sample(&p, 6))
    }
    func testRevocationPendingFencesAck() throws {
        var p = ready(); let i = try XCTUnwrap(sample(&p)); _ = p.permission(false, now: 2.1)
        XCTAssertFalse(p.ack(i, accepted: true, now: 3)); XCTAssertEqual(p.state, .uncertain)
    }
    func testStartTimeoutHasNoRestartOrFalseIdle() throws {
        var p = ready(); let i = try XCTUnwrap(sample(&p)); XCTAssertNil(p.tick(now: 12))
        XCTAssertEqual(p.state, .uncertain); XCTAssertFalse(p.ack(i, accepted: true, now: 13))
        XCTAssertNil(sample(&p, 14)); XCTAssertFalse(p.arm(now: 14, explicit: true))
    }
    func testClockRollbackFailsClosed() {
        var p = ready(); XCTAssertNil(sample(&p, 0.5)); XCTAssertEqual(p.state, .off); XCTAssertNil(sample(&p, 3))
    }
    func testPendingRollbackRequiresReconciliation() throws {
        var p = ready(); let i = try XCTUnwrap(sample(&p)); XCTAssertNil(p.tick(now: 1.5))
        XCTAssertEqual(p.state, .uncertain); XCTAssertFalse(p.ack(i, accepted: true, now: 3))
    }
    func testUnknownStaleDemoEmptyNonfiniteCannotTrigger() {
        for quality in ["unknown", "stale"] { var p = ready(); XCTAssertNil(sample(&p, quality: quality)); XCTAssertEqual(p.state, .armed) }
        let valueCases: [[Double]] = [[], [.nan], [.infinity]]
        for values in valueCases { var p = ready(); XCTAssertNil(sample(&p, values: values)); XCTAssertEqual(p.state, .armed) }
        for captured in [-1.0, 3, 0] { var p = ready(); XCTAssertNil(sample(&p, captured: captured)); XCTAssertEqual(p.state, .armed) }
        var p = ready(); XCTAssertNil(sample(&p, demo: true)); XCTAssertNil(sample(&p, source: "other")); XCTAssertNil(sample(&p, session: "other"))
    }
    func testOldAfterArmTelemetryIsStale() {
        var p = ready(); XCTAssertNil(sample(&p, 5, captured: 1)); XCTAssertEqual(p.state, .armed)
    }
    func testZeroQualifiedTelemetryIsNotEngineInference() {
        var p = ready(); XCTAssertEqual(sample(&p, values: [0])?.action, .start)
    }
    func testWrongNonceAndInstanceCallbackRejected() throws {
        var p = ready(); let i = try XCTUnwrap(sample(&p))
        let wrong = [
            Policy.Intent(action: i.action, reason: i.reason, instance: "other", source: i.source, session: i.session, generation: i.generation, nonce: i.nonce),
            Policy.Intent(action: i.action, reason: i.reason, instance: i.instance, source: "other", session: i.session, generation: i.generation, nonce: i.nonce),
            Policy.Intent(action: i.action, reason: i.reason, instance: i.instance, source: i.source, session: "other", generation: i.generation, nonce: i.nonce),
            Policy.Intent(action: i.action, reason: i.reason, instance: i.instance, source: i.source, session: i.session, generation: i.generation - 1, nonce: i.nonce),
            Policy.Intent(action: i.action, reason: i.reason, instance: i.instance, source: i.source, session: i.session, generation: i.generation, nonce: i.nonce + 1),
            Policy.Intent(action: .stop, reason: i.reason, instance: i.instance, source: i.source, session: i.session, generation: i.generation, nonce: i.nonce)]
        for bad in wrong { XCTAssertFalse(p.ack(bad, accepted: true, now: 2.1)) }
        XCTAssertTrue(p.ack(i, accepted: true, now: 2.2))
    }
    func testInactivityStopMeansOnlyLackOfTelemetry() throws {
        var p = try running(5); XCTAssertNil(p.tick(now: 6.9)); let i = try XCTUnwrap(p.tick(now: 7))
        XCTAssertEqual(i.action, .stop); XCTAssertEqual(i.reason, .telemetryInactive); XCTAssertEqual(p.state, .stopPending)
        XCTAssertNil(p.tick(now: 8)); XCTAssertTrue(p.ack(i, accepted: true, now: 8)); XCTAssertEqual(p.state, .off); XCTAssertNil(sample(&p, 9))
    }
    func testFreshTelemetryExtendsDeadlineButUnknownDoesNot() throws {
        var p = try running(5); _ = sample(&p, 6); XCTAssertNil(p.tick(now: 10)); _ = sample(&p, 10, quality: "unknown")
        XCTAssertEqual(p.tick(now: 11)?.action, .stop)
    }
    func testReplayedSampleDoesNotExtendInactivity() throws {
        var p = try running(5); _ = sample(&p, 4, captured: 2); XCTAssertEqual(p.tick(now: 7)?.action, .stop)
    }
    func testNoDefaultInactivityStop() throws {
        var p = try running(); XCTAssertNil(p.tick(now: 1000)); XCTAssertEqual(p.state, .recording)
    }
    func testStopDenialKeepsRecordingWithoutAutomaticRetry() throws {
        var p = try running(5); let i = try XCTUnwrap(p.tick(now: 7)); XCTAssertTrue(p.ack(i, accepted: false, now: 8))
        XCTAssertEqual(p.state, .recording); XCTAssertNil(p.tick(now: 100)); XCTAssertNotNil(p.stop(now: 101))
    }
    func testStopTimeoutIsUncertainNotStopped() throws {
        var p = try running(); let i = try XCTUnwrap(p.stop(now: 3)); XCTAssertNil(p.tick(now: 13))
        XCTAssertEqual(p.state, .uncertain); XCTAssertFalse(p.ack(i, accepted: true, now: 14))
    }
    func testInvalidInactivityAndTimesReject() {
        for value in [0.0, -1, .nan, .infinity] { var p = make(); p.reconnect(now: 0); XCTAssertFalse(p.arm(now: 1, explicit: true, inactivity: value)) }
        var p = ready(); XCTAssertNil(sample(&p, .nan)); XCTAssertNil(sample(&p, .infinity))
    }
    func testRearmWhilePendingOrOwnedRejected() throws {
        var p = ready(); _ = sample(&p); XCTAssertFalse(p.arm(now: 3, explicit: true))
        p = try running(); XCTAssertFalse(p.arm(now: 3, explicit: true))
    }
    func testExecutorGateRejectsStaleAndInvalidatedIntents() throws {
        var p = ready(); let i = try XCTUnwrap(sample(&p))
        XCTAssertTrue(p.canExecute(i, now: 2.1)); XCTAssertFalse(p.canExecute(i, now: 4.1))
        p = ready(); let next = try XCTUnwrap(sample(&p)); p.disarm(now: 2.2); XCTAssertFalse(p.canExecute(next, now: 2.2))
    }
    func testExecutorStopGateSurvivesPermissionRevocationNotManualTakeover() throws {
        var p = try running(); let i = try XCTUnwrap(p.permission(false, now: 3))
        XCTAssertTrue(p.canExecute(i, now: 3.1)); p.manual(true, now: 4); XCTAssertFalse(p.canExecute(i, now: 4))
    }

}
