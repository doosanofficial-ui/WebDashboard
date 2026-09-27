import XCTest
@testable import TelemetryCore

final class ReliabilityTests: XCTestCase {
    func testFrameSequenceTrackerCountsOnlyForwardGaps() {
        var tracker = FrameSequenceTracker()

        XCTAssertEqual(tracker.accept(sequence: 10), 0)
        XCTAssertEqual(tracker.accept(sequence: 12), 1)
        XCTAssertEqual(tracker.accept(sequence: 11), 0)
        XCTAssertEqual(tracker.accept(sequence: 12), 0)
        XCTAssertEqual(tracker.lastSequence, 12)
        XCTAssertEqual(tracker.receivedCount, 4)
        XCTAssertEqual(tracker.dropCount, 1)
    }

    func testFrameSequenceTrackerResetStartsNewConnectionWithoutInheritedDrops() {
        var tracker = FrameSequenceTracker()
        _ = tracker.accept(sequence: 100)
        _ = tracker.accept(sequence: 103)

        tracker.reset()

        XCTAssertNil(tracker.lastSequence)
        XCTAssertEqual(tracker.receivedCount, 0)
        XCTAssertEqual(tracker.dropCount, 0)
        XCTAssertEqual(tracker.accept(sequence: 1), 0)
    }

    func testReconnectBackoffDoublesAndCapsUntilReset() {
        var backoff = ReconnectBackoff(initialSeconds: 1, maximumSeconds: 4)

        XCTAssertEqual(backoff.nextDelaySeconds(), 1)
        XCTAssertEqual(backoff.nextDelaySeconds(), 2)
        XCTAssertEqual(backoff.nextDelaySeconds(), 4)
        XCTAssertEqual(backoff.nextDelaySeconds(), 4)

        backoff.reset()
        XCTAssertEqual(backoff.nextDelaySeconds(), 1)
    }

    func testPingMetricsExposeLastRttAndConsecutiveFailures() {
        var metrics = PingMetrics()

        XCTAssertNil(metrics.lastRTTMilliseconds)
        XCTAssertEqual(metrics.consecutiveFailures, 0)

        metrics.recordSuccess(rttMilliseconds: 42.5)
        XCTAssertEqual(metrics.lastRTTMilliseconds, 42.5)
        XCTAssertEqual(metrics.consecutiveFailures, 0)

        metrics.recordFailure()
        metrics.recordFailure()
        XCTAssertEqual(metrics.lastRTTMilliseconds, 42.5)
        XCTAssertEqual(metrics.consecutiveFailures, 2)

        metrics.recordSuccess(rttMilliseconds: 55)
        XCTAssertEqual(metrics.lastRTTMilliseconds, 55)
        XCTAssertEqual(metrics.consecutiveFailures, 0)

        metrics.reset()
        XCTAssertNil(metrics.lastRTTMilliseconds)
        XCTAssertEqual(metrics.consecutiveFailures, 0)
    }
}
