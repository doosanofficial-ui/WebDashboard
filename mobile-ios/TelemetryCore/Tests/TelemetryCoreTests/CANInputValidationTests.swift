import Foundation
import XCTest
@testable import TelemetryCore

final class CANInputValidationTests: XCTestCase {
    private func frame() throws -> CANFrame {
        try CANFrame(receivedAtEpoch: 100.125, receivedAtMonotonicNanos: 1234,
            canID: 0x123, isExtended: false, dlc: 1, payload: [2],
            sourceAdapter: "fixture", sourceTransport: "test", sequence: 7)
    }
    private func definition(factor: Double = 0.5, offset: Double = 0) throws -> SignalDefinition {
        try SignalDefinition(id: "s", name: "Signal", canID: 0x123, isExtended: false,
            startBit: 0, bitLength: 8, byteOrder: .intel, isSigned: false,
            factor: factor, offset: offset, minimum: nil, maximum: nil, unit: "unit", timeout: 1)
    }
    private func replacing<T: Encodable>(_ value: T, key: String, with replacement: Any) throws -> Data {
        let data = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object[key] = replacement
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testFrameJSONCannotBypassDLCValidation() throws {
        for dlc in [-1, 9, Int.max] {
            let data = try replacing(frame(), key: "dlc", with: dlc)
            XCTAssertThrowsError(try JSONDecoder().decode(CANFrame.self, from: data))
        }
    }
    func testFrameJSONCannotBypassPayloadLengthValidation() throws {
        let data = try replacing(frame(), key: "payload", with: [1, 2])
        XCTAssertThrowsError(try JSONDecoder().decode(CANFrame.self, from: data))
    }
    func testFrameJSONCannotBypassStandardIDRange() throws {
        let data = try replacing(frame(), key: "canID", with: 0x800)
        XCTAssertThrowsError(try JSONDecoder().decode(CANFrame.self, from: data))
    }
    func testFrameJSONCannotBypassExtendedIDRange() throws {
        let value = try CANFrame(receivedAtEpoch: 100, receivedAtMonotonicNanos: 1,
            canID: 0x1FFFFFFF, isExtended: true, dlc: 0, payload: [],
            sourceAdapter: "fixture", sourceTransport: "test", sequence: 1)
        let data = try replacing(value, key: "canID", with: 0x20000000)
        XCTAssertThrowsError(try JSONDecoder().decode(CANFrame.self, from: data))
    }
    func testSignalJSONCannotBypassBitRangeValidation() throws {
        for start in [-1, 64, Int.max] {
            let data = try replacing(definition(), key: "startBit", with: start)
            XCTAssertThrowsError(try JSONDecoder().decode(SignalDefinition.self, from: data))
        }
        for length in [0, 65, Int.max] {
            let data = try replacing(definition(), key: "bitLength", with: length)
            XCTAssertThrowsError(try JSONDecoder().decode(SignalDefinition.self, from: data))
        }
    }
    func testSignalJSONCannotBypassIdentityAndTimeoutValidation() throws {
        for (key, value) in [("id", ""), ("name", "")] {
            let data = try replacing(definition(), key: key, with: value)
            XCTAssertThrowsError(try JSONDecoder().decode(SignalDefinition.self, from: data))
        }
        for timeout in [0.0, -1.0] {
            let data = try replacing(definition(), key: "timeout", with: timeout)
            XCTAssertThrowsError(try JSONDecoder().decode(SignalDefinition.self, from: data))
        }
    }
    func testSignalJSONCannotBypassCANIDOrLimitsValidation() throws {
        let id = try replacing(definition(), key: "canID", with: 0x800)
        XCTAssertThrowsError(try JSONDecoder().decode(SignalDefinition.self, from: id))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(definition())) as? [String: Any])
        object["minimum"] = 10.0; object["maximum"] = 1.0
        let limits = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(SignalDefinition.self, from: limits))
    }
    func testValidFrameAndSignalRoundTripWithoutChangingWireKeys() throws {
        let f = try frame(); let d = try definition()
        XCTAssertEqual(try JSONDecoder().decode(CANFrame.self, from: JSONEncoder().encode(f)), f)
        XCTAssertEqual(try JSONDecoder().decode(SignalDefinition.self, from: JSONEncoder().encode(d)), d)
    }
    func testDecoderRejectsMultiplicationOverflowInsteadOfReturningInfinity() throws {
        XCTAssertThrowsError(try SignalDecoder.decode(frame(), definition: definition(factor: .greatestFiniteMagnitude))) { error in
            XCTAssertEqual(error as? SignalDecodeError, .valueOutOfRange)
        }
    }
    func testDecoderRejectsAdditionOverflowAndAcceptsOrdinaryZero() throws {
        XCTAssertThrowsError(try SignalDecoder.decode(frame(), definition: definition(factor: .greatestFiniteMagnitude / 2, offset: .greatestFiniteMagnitude)))
        let zero = try SignalDecoder.decode(frame(), definition: definition(factor: 0))
        XCTAssertEqual(zero.value, 0)
    }
}
