// Candidate qualification tests for the pinned upstream SPM package.
import XCTest
import LTSupportAutomotive

final class DashboardAcceptanceTests: XCTestCase {
    func testMode01PID06DoesNotGetMistakenForMode06() throws {
        let decoder = LTOBD2ProtocolISO15765_4(numberOfBitsInHeader: 11)
        let result = try XCTUnwrap(decoder.decode(["7E8 03 41 06 7C"], originatingCommand: "0106")["7E8"])
        XCTAssertEqual(result.payload.map(\.intValue), [124])
    }

    func testCANPaddingIsNotReturnedAsMeasurementPayload() throws {
        let decoder = LTOBD2ProtocolISO15765_4(numberOfBitsInHeader: 11)
        let result = try XCTUnwrap(decoder.decode(["7E8 04 41 0C 1A F8 00 00 00"], originatingCommand: "010C")["7E8"])
        XCTAssertEqual(result.payload.map(\.intValue), [26, 248])
    }
}
