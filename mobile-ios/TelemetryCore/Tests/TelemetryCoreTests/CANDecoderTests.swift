import XCTest
@testable import TelemetryCore

final class CANDecoderTests: XCTestCase {
    private func frame(_ payload: [UInt8], id: UInt32 = 0x123, extended: Bool = false) throws -> CANFrame {
        try CANFrame(
            receivedAtEpoch: 1_700_000_000,
            receivedAtMonotonicNanos: 42,
            canID: id,
            isExtended: extended,
            dlc: payload.count,
            payload: payload,
            sourceAdapter: "mock",
            sourceTransport: "test",
            sequence: 1
        )
    }

    private func definition(
        id: UInt32 = 0x123,
        startBit: Int,
        bitLength: Int,
        byteOrder: ByteOrder = .intel,
        signed: Bool = false,
        factor: Double = 1,
        offset: Double = 0,
        minimum: Double? = nil,
        maximum: Double? = nil,
        enumMap: [UInt64: String] = [:]
    ) throws -> SignalDefinition {
        try SignalDefinition(
            id: "test.signal",
            name: "Test Signal",
            canID: id,
            isExtended: false,
            startBit: startBit,
            bitLength: bitLength,
            byteOrder: byteOrder,
            isSigned: signed,
            factor: factor,
            offset: offset,
            minimum: minimum,
            maximum: maximum,
            unit: "unit",
            timeout: 0.5,
            enumMap: enumMap
        )
    }

    func testFrameValidatesIdentifierDlcAndPreservesRawPayload() throws {
        let standard = try frame([0x11, 0x22])
        XCTAssertEqual(standard.canID, 0x123)
        XCTAssertFalse(standard.isExtended)
        XCTAssertEqual(standard.dlc, 2)
        XCTAssertEqual(standard.payload, [0x11, 0x22])
        XCTAssertEqual(standard.sourceAdapter, "mock")

        let extended = try frame([0xAA], id: 0x1ABCDE, extended: true)
        XCTAssertTrue(extended.isExtended)
        XCTAssertEqual(extended.canID, 0x1ABCDE)

        XCTAssertThrowsError(try frame([0x00], id: 0x800))
        XCTAssertThrowsError(try frame([0x00], id: 0x20000000, extended: true))
        XCTAssertThrowsError(try CANFrame(
            receivedAtEpoch: 1,
            receivedAtMonotonicNanos: 1,
            canID: 0x123,
            isExtended: false,
            dlc: 2,
            payload: [0x00],
            sourceAdapter: "mock",
            sourceTransport: "test",
            sequence: 1
        ))
        XCTAssertThrowsError(try CANFrame(
            receivedAtEpoch: 1,
            receivedAtMonotonicNanos: 1,
            canID: 0x123,
            isExtended: false,
            dlc: 9,
            payload: Array(repeating: 0, count: 9),
            sourceAdapter: "mock",
            sourceTransport: "test",
            sequence: 1
        ))
    }

    func testIntelSignalExtractsMultiByteUnsignedValue() throws {
        let result = try SignalDecoder.decode(
            frame([0x34, 0x12]),
            definition: definition(startBit: 0, bitLength: 16)
        )
        XCTAssertEqual(result.rawValue, 0x1234)
        XCTAssertEqual(result.value, 4660)
    }

    func testMotorolaSignalExtractsCrossByteValueUsingDBCStartBit() throws {
        let result = try SignalDecoder.decode(
            frame([0x14, 0xA0]),
            definition: definition(startBit: 4, bitLength: 8, byteOrder: .motorola)
        )
        XCTAssertEqual(result.rawValue, 0xA5)
        XCTAssertEqual(result.value, 165)
    }

    func testSignedSignalUsesTwosComplementBeforeScaling() throws {
        let result = try SignalDecoder.decode(
            frame([0xFF, 0x0F]),
            definition: definition(startBit: 0, bitLength: 12, signed: true, factor: 0.5, offset: 10)
        )
        XCTAssertEqual(result.rawValue, 0xFFF)
        XCTAssertEqual(result.signedRawValue, -1)
        XCTAssertEqual(result.value, 9.5, accuracy: 0.0001)
    }

    func testFactorOffsetRangeAndEnumMappingArePreserved() throws {
        let scaled = try SignalDecoder.decode(
            frame([0x14]),
            definition: definition(startBit: 0, bitLength: 8, factor: 0.5, offset: -10, minimum: 0, maximum: 20)
        )
        XCTAssertEqual(scaled.value, 0, accuracy: 0.0001)
        XCTAssertNil(scaled.enumName)

        let enumerated = try SignalDecoder.decode(
            frame([0x01]),
            definition: definition(startBit: 0, bitLength: 8, minimum: 0, maximum: 1, enumMap: [0: "off", 1: "on"])
        )
        XCTAssertEqual(enumerated.enumName, "on")
    }

    func testDecoderRejectsWrongFrameAndInvalidSignalDefinition() throws {
        let mismatched = try definition(id: 0x456, startBit: 0, bitLength: 8)
        XCTAssertThrowsError(try SignalDecoder.decode(frame([0x01]), definition: mismatched))

        XCTAssertThrowsError(try definition(startBit: 0, bitLength: 0))
        XCTAssertThrowsError(try definition(startBit: 63, bitLength: 2))
        XCTAssertThrowsError(try definition(startBit: 0, bitLength: 65))
    }
}
