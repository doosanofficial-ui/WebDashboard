import XCTest
@testable import TelemetryCore

final class ServerCANFrameTests: XCTestCase {
    func testValidFrameRoundTripsWithStableContractKeys() throws {
        let frame = try ServerCANFrame(
            version: 1,
            serverTimestamp: 1_700_000_000.25,
            signals: ["ws_fl": 12.5, "yaw": -0.25],
            status: .init(sequence: 42, drop: 3)
        )

        let data = try JSONEncoder().encode(frame)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["t"] as? Double, 1_700_000_000.25)

        let decoded = try JSONDecoder().decode(ServerCANFrame.self, from: data)
        XCTAssertEqual(decoded, frame)
    }

    func testInvalidRemoteValuesAreRejectedBeforeUiIngestion() throws {
        XCTAssertThrowsError(try ServerCANFrame(
            version: 2,
            serverTimestamp: 1,
            signals: [:],
            status: .init(sequence: 0, drop: 0)
        ))
        XCTAssertThrowsError(try ServerCANFrame(
            version: 1,
            serverTimestamp: .infinity,
            signals: [:],
            status: .init(sequence: 0, drop: 0)
        ))
        XCTAssertThrowsError(try ServerCANFrame(
            version: 1,
            serverTimestamp: 1,
            signals: ["bad\0key": 1],
            status: .init(sequence: 0, drop: 0)
        ))
        XCTAssertThrowsError(try ServerCANFrame(
            version: 1,
            serverTimestamp: 1,
            signals: ["bad": .nan],
            status: .init(sequence: 0, drop: 0)
        ))
        XCTAssertThrowsError(try ServerCANFrame(
            version: 1,
            serverTimestamp: 1,
            signals: [:],
            status: .init(sequence: -1, drop: 0)
        ))
    }

    func testDecoderRejectsOversizedSignalCatalog() {
        let signals = Dictionary(uniqueKeysWithValues: (0..<257).map { ("sig\($0)", Double($0)) })
        XCTAssertThrowsError(try ServerCANFrame(
            version: 1,
            serverTimestamp: 1,
            signals: signals,
            status: .init(sequence: 0, drop: 0)
        ))
    }

    func testOptionalRawCANFDFrameRoundTripsWithV1Snapshot() throws {
        let raw = try ServerCANRawFrame(
            timestamp: 1_700_000_000.25,
            channel: "CAN1",
            source: "canoe",
            arbitrationID: 0x212,
            isExtended: false,
            isFD: true,
            bitrateSwitch: true,
            errorStateIndicator: false,
            dlc: 15,
            data: Array(0..<64)
        )
        let frame = try ServerCANFrame(
            version: 1,
            serverTimestamp: 1_700_000_000.25,
            signals: ["yaw": -0.25],
            status: .init(sequence: 42, drop: 3),
            raw: raw
        )
        let decoded = try JSONDecoder().decode(
            ServerCANFrame.self,
            from: JSONEncoder().encode(frame)
        )
        XCTAssertEqual(decoded.raw, raw)
        XCTAssertEqual(decoded.raw?.data.count, 64)
        XCTAssertEqual(decoded.raw?.dlc, 15)
    }

    func testRawFrameRejectsClassicalDLCFlagsAndInvalidFDPayload() throws {
        XCTAssertThrowsError(try ServerCANRawFrame(
            timestamp: 1,
            channel: nil,
            source: "test",
            arbitrationID: 1,
            isExtended: false,
            isFD: false,
            bitrateSwitch: true,
            errorStateIndicator: false,
            dlc: 1,
            data: [0]
        ))
        XCTAssertThrowsError(try ServerCANRawFrame(
            timestamp: 1,
            channel: nil,
            source: "test",
            arbitrationID: 1,
            isExtended: false,
            isFD: true,
            bitrateSwitch: false,
            errorStateIndicator: false,
            dlc: 9,
            data: Array(repeating: 0, count: 9)
        ))
    }

    func testRawFrameRejectsDeclaredDataLengthMismatch() throws {
        let json = """
        {"t":1,"source":"test","arbitration_id":1,"extended":false,"fd":false,"brs":false,"esi":false,"dlc":1,"data_length":8,"data":[0]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ServerCANRawFrame.self, from: json)) { error in
            XCTAssertEqual(error as? ServerCANRawFrameError, .dataLengthMismatch)
        }
    }
}
