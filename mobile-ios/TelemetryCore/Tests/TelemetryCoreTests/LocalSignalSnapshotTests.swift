import XCTest
@testable import TelemetryCore

final class LocalSignalSnapshotTests: XCTestCase {
    func testAlternatingQueriesRetainIndependentLatestValues() throws {
        var cache = LocalSignalSnapshot()
        try cache.merge(["soc": 50.5], receivedAt: 100, source: "diagnostic")
        try cache.merge(["rpm": 900], receivedAt: 101, source: "diagnostic")
        XCTAssertEqual(cache.values, ["soc": 50.5, "rpm": 900])
    }

    func testOtherSignalNeverRefreshesPreviousReceiveTime() throws {
        var cache = LocalSignalSnapshot()
        try cache.merge(["soc": 50.5], receivedAt: 100.125, source: "diagnostic")
        try cache.merge(["rpm": 900], receivedAt: 110, source: "diagnostic")
        XCTAssertEqual(cache.receivedAtEpoch, ["soc": 100.125, "rpm": 110])
    }

    func testNewCallbackUpdatesOnlyItsOwnKeys() throws {
        var cache = LocalSignalSnapshot()
        try cache.merge(["fl": 1, "fr": 2], receivedAt: 100, source: "rawCAN")
        try cache.merge(["fl": 3], receivedAt: 101, source: "rawCAN")
        XCTAssertEqual(cache.values, ["fl": 3, "fr": 2])
        XCTAssertEqual(cache.receivedAtEpoch, ["fl": 101, "fr": 100])
    }

    func testEqualTimestampCallbacksStillMerge() throws {
        var cache = LocalSignalSnapshot()
        try cache.merge(["soc": 50], receivedAt: 100, source: "diagnostic")
        try cache.merge(["rpm": 900], receivedAt: 100, source: "diagnostic")
        XCTAssertEqual(cache.values.count, 2)
    }

    func testClockAdjustmentDoesNotDiscardOrRetimestampNewCallback() throws {
        var cache = LocalSignalSnapshot()
        try cache.merge(["soc": 50], receivedAt: 100, source: "diagnostic")
        try cache.merge(["soc": 51], receivedAt: 99, source: "diagnostic")
        XCTAssertEqual(cache.values["soc"], 51)
        XCTAssertEqual(cache.receivedAtEpoch["soc"], 99)
    }

    func testChangingSourceClearsOldMeasurementsAndTimes() throws {
        var cache = LocalSignalSnapshot()
        try cache.merge(["demo.signal": 99], receivedAt: 100, source: "Demo")
        try cache.merge(["soc": 50], receivedAt: 101, source: "Diagnostic")
        XCTAssertEqual(cache.values, ["soc": 50])
        XCTAssertEqual(cache.receivedAtEpoch, ["soc": 101])
        XCTAssertEqual(cache.source, "Diagnostic")
    }

    func testResetClearsSameSourceSessionBeforeReconnect() throws {
        var cache = LocalSignalSnapshot()
        try cache.merge(["soc": 50], receivedAt: 100, source: "Diagnostic")
        cache.reset()
        XCTAssertTrue(cache.values.isEmpty)
        XCTAssertTrue(cache.receivedAtEpoch.isEmpty)
        XCTAssertNil(cache.source)
        try cache.merge(["rpm": 900], receivedAt: 101, source: "Diagnostic")
        XCTAssertEqual(cache.values, ["rpm": 900])
    }

    func testZeroAndNegativePhysicalValuesRemainValid() throws {
        var cache = LocalSignalSnapshot()
        try cache.merge(["speed": 0, "current": -18.2], receivedAt: 100, source: "Diagnostic")
        XCTAssertEqual(cache.values, ["speed": 0, "current": -18.2])
    }

    func testNonFiniteTimestampRejectsWithoutMutation() throws {
        var cache = LocalSignalSnapshot()
        try cache.merge(["soc": 50], receivedAt: 100, source: "Diagnostic")
        let before = cache
        for timestamp in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try cache.merge(["rpm": 900], receivedAt: timestamp, source: "Diagnostic"))
            XCTAssertEqual(cache, before)
        }
    }

    func testNonFiniteValueRejectsWholeUpdateWithoutClearingSource() throws {
        var cache = LocalSignalSnapshot()
        try cache.merge(["soc": 50], receivedAt: 100, source: "Diagnostic")
        let before = cache
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try cache.merge(["good": 1, "bad": value], receivedAt: 101, source: "Demo"))
            XCTAssertEqual(cache, before)
        }
    }

    func testInvalidKeyOrSourceIsRejectedWithoutMutation() throws {
        var cache = LocalSignalSnapshot()
        try cache.merge(["soc": 50], receivedAt: 100, source: "Diagnostic")
        let before = cache
        for key in ["", "bad\0key", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try cache.merge([key: 1], receivedAt: 101, source: "Diagnostic"))
            XCTAssertEqual(cache, before)
        }
        XCTAssertThrowsError(try cache.merge(["rpm": 900], receivedAt: 101, source: ""))
        XCTAssertEqual(cache, before)
    }

    func testEmptyCallbackDoesNotEraseExistingSnapshot() throws {
        var cache = LocalSignalSnapshot()
        try cache.merge(["soc": 50], receivedAt: 100, source: "Diagnostic")
        let before = cache
        XCTAssertThrowsError(try cache.merge([:], receivedAt: 101, source: "Demo"))
        XCTAssertEqual(cache, before)
    }

    func testCapacityMatchesExistingSnapshotContractAndRejectsAtomically() throws {
        var cache = LocalSignalSnapshot()
        let values = Dictionary(uniqueKeysWithValues: (0..<256).map { ("signal.\($0)", Double($0)) })
        try cache.merge(values, receivedAt: 100, source: "Diagnostic")
        let before = cache
        XCTAssertThrowsError(try cache.merge(["extra": 1], receivedAt: 101, source: "Diagnostic")) { error in
            XCTAssertEqual(error as? LocalSignalSnapshotError, .tooManySignals)
        }
        XCTAssertEqual(cache, before)
        try cache.merge(["signal.0": 10], receivedAt: 102, source: "Diagnostic")
        XCTAssertEqual(cache.values["signal.0"], 10)
        XCTAssertEqual(cache.values.count, 256)
    }

    func testSourceChangeDoesNotInheritPreviousCapacity() throws {
        var cache = LocalSignalSnapshot()
        let values = Dictionary(uniqueKeysWithValues: (0..<256).map { ("signal.\($0)", Double($0)) })
        try cache.merge(values, receivedAt: 100, source: "Demo")
        try cache.merge(["soc": 50], receivedAt: 101, source: "Diagnostic")
        XCTAssertEqual(cache.values, ["soc": 50])
    }
}
