import XCTest
@testable import TelemetryCore

final class RecordingLifecycleTests: XCTestCase {
    func testNewLifecycleIsIdleAndStartsOnlyOnce() {
        var lifecycle = RecordingLifecycle()

        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertTrue(lifecycle.start())
        XCTAssertFalse(lifecycle.start())
        XCTAssertEqual(lifecycle.state, .recording)
    }

    func testStopCompletesAnActiveSessionAndResetReturnsToIdle() {
        var lifecycle = RecordingLifecycle()
        XCTAssertTrue(lifecycle.start())

        XCTAssertTrue(lifecycle.stop())
        XCTAssertFalse(lifecycle.stop())
        XCTAssertEqual(lifecycle.state, .completed)

        lifecycle.reset()
        XCTAssertEqual(lifecycle.state, .idle)
    }

    func testFailureIsVisibleAndCanBeRetriedAfterReset() {
        var lifecycle = RecordingLifecycle()
        XCTAssertTrue(lifecycle.start())
        lifecycle.fail()

        XCTAssertEqual(lifecycle.state, .failed)
        XCTAssertFalse(lifecycle.stop())
        lifecycle.reset()
        XCTAssertTrue(lifecycle.start())
    }
}
