import XCTest
@testable import TelemetryCore

final class DashboardConditionTests: XCTestCase {
    func testGreaterThanUsesHysteresisOnRelease() {
        var runtime = DashboardConditionRuntime()
        let condition = DashboardCondition(op: .greaterThan, threshold: 10, hysteresis: 2)
        XCTAssertTrue(runtime.update(condition: condition, value: 11, rawValue: nil, stale: false, now: 1))
        XCTAssertTrue(runtime.update(condition: condition, value: 9, rawValue: nil, stale: false, now: 2))
        XCTAssertFalse(runtime.update(condition: condition, value: 7.9, rawValue: nil, stale: false, now: 3))
    }

    func testHoldTimeDelaysActivation() {
        var runtime = DashboardConditionRuntime()
        let condition = DashboardCondition(op: .greaterThan, threshold: 10, holdTime: 1)
        XCTAssertFalse(runtime.update(condition: condition, value: 11, rawValue: nil, stale: false, now: 1))
        XCTAssertFalse(runtime.update(condition: condition, value: 11, rawValue: nil, stale: false, now: 1.9))
        XCTAssertTrue(runtime.update(condition: condition, value: 11, rawValue: nil, stale: false, now: 2.01))
    }

    func testRangeBitAndStaleConditions() {
        var range = DashboardConditionRuntime()
        XCTAssertTrue(range.update(
            condition: DashboardCondition(op: .withinRange, threshold: 2, upperThreshold: 4),
            value: 3, rawValue: nil, stale: false, now: 1
        ))

        var bit = DashboardConditionRuntime()
        XCTAssertTrue(bit.update(
            condition: DashboardCondition(op: .bitSet, threshold: nil, bit: 3),
            value: 0, rawValue: 0b1000, stale: false, now: 1
        ))

        var stale = DashboardConditionRuntime()
        XCTAssertTrue(stale.update(
            condition: DashboardCondition(op: .equals, threshold: 1, staleIsActive: true),
            value: nil, rawValue: nil, stale: true, now: 1
        ))
    }
}
