// Candidate qualification tests, copied into the pinned upstream test target.
// No Bluetooth manager, vehicle connection or ECU command is created.
import Foundation
import XCTest
@testable import SwiftOBD2

final class DashboardAcceptanceTests: XCTestCase {
    func testNoReplyReturnsWithinDeadlineWithoutExternalReset() async {
        let processor = BLEMessageProcessor()
        let completed = expectation(description: "Response timeout must finish the caller")
        let operation = Task {
            do {
                _ = try await processor.waitForResponse(timeout: 0.02)
                XCTFail("A missing response must fail, not return data")
            } catch {}
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 0.5)
        // Release an upstream continuation if the acceptance assertion failed.
        processor.reset()
        _ = await operation.result
    }
}
