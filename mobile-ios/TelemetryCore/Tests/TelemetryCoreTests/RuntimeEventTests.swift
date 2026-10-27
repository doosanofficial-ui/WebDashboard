import XCTest
@testable import TelemetryCore

final class RuntimeEventTests: XCTestCase {
    func testAdapterStatesMapToStableRecordingEvents() {
        XCTAssertEqual(AdapterRuntimeEvent(state: "Live adapter starting"), .starting)
        XCTAssertEqual(AdapterRuntimeEvent(state: "Live adapter monitoring"), .monitoring)
        XCTAssertEqual(AdapterRuntimeEvent(state: "Live adapter recovering: buffer full; retrying in 2s"), .reconnecting)
        XCTAssertEqual(AdapterRuntimeEvent(state: "Adapter disconnected"), .disconnected)
        XCTAssertEqual(AdapterRuntimeEvent(state: "Live adapter profile invalid"), .error)
    }

    func testDiagnosticFailureNamesPreserveQueryDataAndStableErrorCodes() {
        let queryID = "query,:\"quoted\"\n진단🚗"
        let cases: [(OBDQuerySessionError, String)] = [
            (.invalidState, "invalid_state"), (.transport, "transport"), (.timeout, "timeout"),
            (.unsupportedCommand, "unsupported_command"), (.bufferFull, "buffer_full"),
            (.disconnected, "disconnected"), (.response(.noData), "no_data"),
            (.response(.bufferFull), "buffer_full"), (.response(.negativeResponse(code: 0xAB)), "negative_response_AB"),
            (.response(.serviceMismatch), "malformed_response"),
            (.decode(.payloadTooShort), "payload_too_short"), (.decode(.valueOutOfRange), "value_out_of_range")
        ]
        for (error, expected) in cases {
            let failure = DiagnosticQueryFailure(queryID: queryID, error: error)
            XCTAssertEqual(failure.queryID, queryID)
            XCTAssertEqual(failure.errorCode, expected)
            XCTAssertEqual(failure.recordingName, "diagnostic_query_failed:\(queryID):\(expected)")
        }
    }
}
