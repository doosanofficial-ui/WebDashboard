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
}
