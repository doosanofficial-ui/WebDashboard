import XCTest
@testable import TelemetryCore

final class OBDPollingScheduleTests: XCTestCase {
    func testInitialQueriesKeepProfileOrderWithoutCrossQuerySleep() {
        var schedule = OBDPollingSchedule(intervals: [5_000, 1_000, 1_000, 250, 1_000], now: 0)
        for index in 0..<5 {
            XCTAssertEqual(schedule.next(at: 0), .init(queryIndex: index, delayNanoseconds: 0))
            schedule.complete(index, at: 0)
        }
    }

    func testSpeedDeadlineIsIndependentOfOtherIntervals() {
        var schedule = OBDPollingSchedule(intervals: [5_000, 1_000, 1_000, 250, 1_000], now: 0)
        for index in 0..<5 { schedule.complete(index, at: 0) }
        XCTAssertEqual(schedule.next(at: 0), .init(queryIndex: 3, delayNanoseconds: 250))
        XCTAssertEqual(schedule.next(at: 249), .init(queryIndex: 3, delayNanoseconds: 1))
        XCTAssertEqual(schedule.next(at: 250), .init(queryIndex: 3, delayNanoseconds: 0))
    }

    func testSlowTireQueryDoesNotBlockNextSpeedSample() {
        var schedule = OBDPollingSchedule(intervals: [250, 15_000], now: 100)
        schedule.complete(0, at: 100)
        schedule.complete(1, at: 100)
        XCTAssertEqual(schedule.next(at: 100), .init(queryIndex: 0, delayNanoseconds: 250))
    }

    func testOverdueQueriesAreFairWithoutCatchUpBursts() {
        var schedule = OBDPollingSchedule(intervals: [10, 100], now: 0)
        schedule.complete(0, at: 0)
        schedule.complete(1, at: 0)
        XCTAssertEqual(schedule.next(at: 500), .init(queryIndex: 0, delayNanoseconds: 0))
        schedule.complete(0, at: 500)
        XCTAssertEqual(schedule.next(at: 500), .init(queryIndex: 1, delayNanoseconds: 0))
        schedule.complete(1, at: 500)
        XCTAssertEqual(schedule.next(at: 500), .init(queryIndex: 0, delayNanoseconds: 10))
    }

    func testCompletionTimeIncludesSlowTransport() {
        var schedule = OBDPollingSchedule(intervals: [100], now: 0)
        schedule.complete(0, at: 700)
        XCTAssertEqual(schedule.next(at: 700), .init(queryIndex: 0, delayNanoseconds: 100))
        XCTAssertEqual(schedule.next(at: 799), .init(queryIndex: 0, delayNanoseconds: 1))
    }

    func testDuplicateDefinitionsRemainDistinctSlots() {
        var schedule = OBDPollingSchedule(intervals: [100, 100], now: 0)
        XCTAssertEqual(schedule.next(at: 0), .init(queryIndex: 0, delayNanoseconds: 0))
        schedule.complete(0, at: 0)
        XCTAssertEqual(schedule.next(at: 0), .init(queryIndex: 1, delayNanoseconds: 0))
        schedule.complete(1, at: 0)
        XCTAssertEqual(schedule.next(at: 0), .init(queryIndex: 0, delayNanoseconds: 100))
    }

    func testSkippedUnsupportedSlotsAreDeferredWithoutBusyLoop() {
        var schedule = OBDPollingSchedule(intervals: [100, 200], now: 0)
        schedule.complete(0, at: 0)
        schedule.complete(1, at: 0)
        XCTAssertEqual(schedule.next(at: 0), .init(queryIndex: 0, delayNanoseconds: 100))
    }

    func testNewSessionDoesNotReuseOldDeadlines() {
        var previous = OBDPollingSchedule(intervals: [100], now: 0)
        previous.complete(0, at: 1_000)
        let fresh = OBDPollingSchedule(intervals: [100], now: 1_000)
        XCTAssertEqual(fresh.next(at: 1_000), .init(queryIndex: 0, delayNanoseconds: 0))
    }

    func testDeadlineAdditionDoesNotWrap() {
        var schedule = OBDPollingSchedule(intervals: [20], now: UInt64.max - 5)
        schedule.complete(0, at: UInt64.max - 5)
        XCTAssertEqual(schedule.next(at: UInt64.max - 5), .init(queryIndex: 0, delayNanoseconds: 5))
    }
}
