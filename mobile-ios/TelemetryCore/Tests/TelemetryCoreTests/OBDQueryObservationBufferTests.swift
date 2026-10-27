import XCTest
@testable import TelemetryCore

final class OBDQueryObservationBufferTests: XCTestCase {
    private func receipt(_ ordinal: UInt64, id: String = "query") -> OBDQueryObservation {
        OBDQueryObservation(outcome: .failure(queryID: id, error: .response(.noData)), ordinal: ordinal,
            supportByQueryID: [id: .unknown], freshSupportQueryIDs: [], timestamp: Double(ordinal))
    }
    func testRepeatedEqualOutcomesKeepTheirOriginalReceiptOrder() {
        let buffer = OBDQueryObservationBuffer(capacity: 2)
        let first = receipt(1), next = receipt(2)
        buffer.append(first); buffer.append(next)
        XCTAssertEqual(buffer.take(for: first.outcome), first)
        XCTAssertEqual(buffer.take(for: next.outcome), next)
        XCTAssertFalse(buffer.isUnavailable)
    }
    func testOverflowDoesNotMisattributeNewestReceiptToAnOlderOutcome() {
        let buffer = OBDQueryObservationBuffer(capacity: 1)
        buffer.append(receipt(1)); buffer.append(receipt(2))
        XCTAssertNil(buffer.take(for: receipt(1).outcome))
        XCTAssertTrue(buffer.isUnavailable)
        buffer.append(receipt(3))
        XCTAssertNil(buffer.take(for: receipt(3).outcome))
    }
    func testMissingOutOfOrderAndMismatchedReceiptsInvalidateProjection() {
        let missing = OBDQueryObservationBuffer()
        XCTAssertNil(missing.take(for: receipt(1).outcome))
        let gap = OBDQueryObservationBuffer(); gap.append(receipt(2))
        XCTAssertTrue(gap.isUnavailable)
        let mismatch = OBDQueryObservationBuffer(); mismatch.append(receipt(1))
        XCTAssertNil(mismatch.take(for: receipt(1, id: "different").outcome))
        XCTAssertTrue(mismatch.isUnavailable)
    }
}
