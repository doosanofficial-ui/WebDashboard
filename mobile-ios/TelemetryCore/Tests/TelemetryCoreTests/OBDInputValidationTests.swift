import Foundation
import XCTest
@testable import TelemetryCore

final class OBDInputValidationTests: XCTestCase {
    private func signal(start: Int = 0, factor: Double = 0.5, offset: Double = 0) throws -> OBDSignalDefinition {
        try OBDSignalDefinition(id: "s", name: "Signal", startBit: start, bitLength: 8,
            byteOrder: .intel, isSigned: false, factor: factor, offset: offset,
            minimum: nil, maximum: nil, unit: "unit", timeout: 1)
    }
    private func response() -> OBDResponse {
        OBDResponse(receivedAtEpoch: 100, receivedAtMonotonicNanos: 1000,
            responseCANID: 0x7EC, isExtended: false, service: .service22,
            command: "0101", payload: [2], sequence: 1, sourceAdapter: "fixture", sourceTransport: "test")
    }
    func testExtremeStartBitIsRejectedWithoutIntegerTrap() throws {
        for start in [Int.max, Int.max - 1, 64, -1] {
            XCTAssertThrowsError(try signal(start: start)) { error in
                XCTAssertEqual(error as? OBDQueryError, .invalidBitRange)
            }
        }
    }
    func testJSONExtremeStartBitIsRejectedWithoutIntegerTrap() throws {
        let data = try JSONEncoder().encode(signal())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["startBit"] = Int.max
        XCTAssertThrowsError(try JSONDecoder().decode(OBDSignalDefinition.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }
    func testDiagnosticDecoderRejectsFiniteScalingThatOverflows() throws {
        XCTAssertThrowsError(try OBDSignalDecoder.decode(signal(factor: .greatestFiniteMagnitude), response: response())) { error in
            XCTAssertEqual(error as? OBDSignalDecodeError, .valueOutOfRange)
        }
        XCTAssertThrowsError(try OBDSignalDecoder.decode(signal(factor: .greatestFiniteMagnitude / 2,
            offset: .greatestFiniteMagnitude), response: response()))
    }
    func testValidProfileRoundTripAndRealZeroRemainSupported() throws {
        let definition = try signal(factor: 0)
        XCTAssertEqual(try JSONDecoder().decode(OBDSignalDefinition.self, from: JSONEncoder().encode(definition)), definition)
        let decoded = try OBDSignalDecoder.decode(definition, response: response())
        XCTAssertEqual(decoded.value, 0)
        XCTAssertEqual(decoded.rawValue, 2)
    }
}
