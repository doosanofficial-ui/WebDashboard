import Foundation
import XCTest
@testable import TelemetryCore

final class RecordingStatusTests: XCTestCase {
    func testControlStatusIsDistinctFromMeasurementAndRetainsSafeCounts() throws {
        let data = Data(#"{"v":1,"type":"recording_status","recording":{"state":"failed","pending":2,"unconfirmed":3,"rejected":1,"error":"private-canary"},"sig":{"ws_fl":99}}"#.utf8)
        let update = try XCTUnwrap(RecordingStatusUpdate.decode(data))
        XCTAssertTrue(update.isControl)
        XCTAssertTrue(update.status.isWarning)
        XCTAssertEqual(update.status.text, "Server CSV failed: 6 unresolved")
        XCTAssertFalse(update.status.text.contains("private-canary"))
    }

    func testCanSnapshotIncludesPendingStatusButOldServersRemainUnknown() throws {
        let data = Data(#"{"v":1,"sig":{"ws_fl":12},"status":{"recording":{"state":"delayed","pending":5,"unconfirmed":0,"rejected":0}}}"#.utf8)
        let update = try XCTUnwrap(RecordingStatusUpdate.decode(data))
        XCTAssertFalse(update.isControl)
        XCTAssertEqual(update.status.text, "Server CSV delayed: 5 pending")
        XCTAssertNil(RecordingStatusUpdate.decode(Data(#"{"v":1,"status":{"seq":1}}"#.utf8)))
    }

    func testMalformedStatusFailsSafeWithoutCounterOverflow() throws {
        for recording in [#"{"state":"ready","pending":-1,"unconfirmed":0,"rejected":0}"#,
                          #"{"state":"ready","pending":true,"unconfirmed":0,"rejected":0}"#,
                          #"{"state":"failed","pending":9223372036854775807,"unconfirmed":1,"rejected":0}"#,
                          #"{"state":"private-canary","pending":0,"unconfirmed":0,"rejected":0}"#,
                          #""not-an-object""#] {
            let data = Data("{\"v\":1,\"type\":\"recording_status\",\"recording\":\(recording)}".utf8)
            let update = try XCTUnwrap(RecordingStatusUpdate.decode(data))
            XCTAssertTrue(update.isControl)
            XCTAssertEqual(update.status.text, "Server CSV status unknown")
        }
    }
}
