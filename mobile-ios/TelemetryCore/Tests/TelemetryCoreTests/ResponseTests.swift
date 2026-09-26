import Foundation
import XCTest
@testable import TelemetryCore

final class ResponseTests: XCTestCase {
    func testKnownServerFailureSurvivesTheResponseBoundaryWithoutReflection() throws {
        let body = Data(#"{"error":{"code":"unauthorized","message":"untrusted-secret-example"}}"#.utf8)
        let result = IngestHTTPReply.decode(status: 401, body: body)
        guard case .failure(let code, let message, let retryable) = result else { return XCTFail("Missing error") }
        XCTAssertEqual(code, "unauthorized")
        XCTAssertTrue(message.contains("credential"))
        XCTAssertFalse(message.contains("untrusted-secret-example"))
        XCTAssertFalse(retryable)
    }

    func testStorageFailureIsRetryableAndKeepsItsCode() {
        let body = Data(#"{"error":{"code":"storage_unavailable","message":"private-path"}}"#.utf8)
        guard case .failure(let code, _, let retryable) = IngestHTTPReply.decode(status: 503, body: body) else {
            return XCTFail("Missing error")
        }
        XCTAssertEqual(code, "storage_unavailable")
        XCTAssertTrue(retryable)
    }

    func testOnlyValidV2AcknowledgementsAreAccepted() {
        let valid = Data(#"{"v":2,"client_id":"device-1","acked":["5c6a7f61-24c4-4ed9-8216-5fd0ffde1001"]}"#.utf8)
        guard case .acknowledged(let ack) = IngestHTTPReply.decode(status: 200, body: valid) else {
            return XCTFail("Missing ack")
        }
        XCTAssertEqual(ack.clientID, "device-1")
        XCTAssertEqual(ack.acked, ["5c6a7f61-24c4-4ed9-8216-5fd0ffde1001"])
        for invalid in ["{}", "<html>offline</html>", #"{"v":1,"client_id":"device-1","acked":[]}"#] {
            guard case .failure(let code, _, _) = IngestHTTPReply.decode(status: 200, body: Data(invalid.utf8)) else {
                return XCTFail("Invalid ack accepted")
            }
            XCTAssertEqual(code, "invalid_response")
        }
    }
}
