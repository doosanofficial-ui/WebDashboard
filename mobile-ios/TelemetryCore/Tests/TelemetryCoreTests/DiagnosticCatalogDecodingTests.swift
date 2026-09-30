import Foundation
import XCTest
@testable import TelemetryCore

final class DiagnosticCatalogDecodingTests: XCTestCase {
    private func baseline(_ command: String) throws -> OBDQueryDefinition {
        try XCTUnwrap(SantaFeMX5HybridQueryCatalog.baselineQueries().first { $0.command == command })
    }

    private func extended(_ command: String) throws -> OBDQueryDefinition {
        try XCTUnwrap(SantaFeMX5HybridQueryCatalog.expandedQueries().first { $0.command == command })
    }

    private func response(_ query: OBDQueryDefinition, payload: [UInt8]) -> OBDResponse {
        OBDResponse(receivedAtEpoch: 100, receivedAtMonotonicNanos: 1_000,
            responseCANID: query.responseCANID, isExtended: query.isExtended,
            service: query.service, command: query.command, payload: payload,
            sequence: 7, sourceAdapter: "synthetic-fixture", sourceTransport: "test")
    }

    private func definition(startBit: Int, length: Int = 8,
                            order: ByteOrder = .intel) throws -> OBDSignalDefinition {
        try OBDSignalDefinition(id: "late-field", name: "Late field", startBit: startBit,
            bitLength: length, byteOrder: order, isSigned: false, factor: 1, offset: 0,
            minimum: nil, maximum: nil, unit: "fixture", timeout: 2)
    }

    func testExpandedCatalogBuildsWithoutActivatingCandidates() throws {
        let initial = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let expanded = try SantaFeMX5HybridQueryCatalog.expandedQueries()
        XCTAssertEqual(expanded.map(\.command), ["C101", "C00B", "E004"])
        XCTAssertTrue(Set(initial.map(\.id)).isDisjoint(with: expanded.map(\.id)))
        XCTAssertEqual(expanded.flatMap(\.signals).count, 9)
        XCTAssertTrue(expanded.allSatisfy { $0.sourceCommit == "c14ff9dd8a87482604200a859d7d734234d98892" })
    }

    func testWheelFieldsAfterEightBytesDecodeFromReassembledResponse() throws {
        let q = try extended("C101")
        // 0x12 application bytes: service/DID plus 15 payload bytes. Wheel
        // bytes 11...14 are 0x53...0x56; trailing transport padding is excluded.
        let text = "7EF 10 12 62 C1 01 00 00 00\r7EF 21 00 00 00 00 00 00 00\r7EF 22 00 53 54 55 56 00 00\r>"
        let r = try OBDResponseParser.parse(text, for: q, receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 1_000, sequence: 7, sourceAdapter: "fixture", sourceTransport: "test")
        XCTAssertEqual(r.payload.count, 15)
        let samples = try q.signals.map { try OBDSignalDecoder.decode($0, response: r) }
        XCTAssertEqual(samples.map(\.value), [83, 84, 85, 86])
        XCTAssertEqual(samples.map(\.receivedAtEpoch), [100, 100, 100, 100])
        XCTAssertEqual(samples.map(\.sequence), [7, 7, 7, 7])
    }

    func testAllFourPressureFieldsDecodeAtOriginalPayloadOffsets() throws {
        let q = try extended("C00B")
        var payload = [UInt8](repeating: 0, count: 17)
        for (offset, value) in zip([4, 8, 12, 16], [UInt8(160), 161, 162, 163]) { payload[offset] = value }
        let samples = try q.signals.map { try OBDSignalDecoder.decode($0, response: response(q, payload: payload)) }
        for (sample, expected) in zip(samples, [32.0, 32.2, 32.4, 32.6]) {
            XCTAssertEqual(sample.value, expected, accuracy: 1e-10)
            XCTAssertEqual(sample.unit, "psi")
        }
    }

    func testAuxiliaryChargeFieldAtByteNineteenRetainsItsUnit() throws {
        let q = try extended("E004")
        var payload = [UInt8](repeating: 0, count: 20)
        payload[19] = 63
        let sample = try OBDSignalDecoder.decode(q.signals[0], response: response(q, payload: payload))
        XCTAssertEqual(sample.value, 63)
        XCTAssertEqual(sample.unit, "percent", "Do not relabel this candidate as measured voltage")
    }

    func testMotorolaFieldMayStartBeyondFirstClassicalFrame() throws {
        let d = try definition(startBit: 87, length: 16, order: .motorola)
        var payload = [UInt8](repeating: 0, count: 12)
        payload[10] = 0x12
        payload[11] = 0x34
        let q = try baseline("0C")
        let decoded = try OBDSignalDecoder.decode(d, response: response(q, payload: payload))
        XCTAssertEqual(decoded.rawValue, 0x1234)
    }

    func testDiagnosticDefinitionHasBoundedPayloadAndScalarRanges() throws {
        let maxBits = 4095 * 8 // Supported parser's 12-bit ISO-TP length bound.
        XCTAssertNoThrow(try definition(startBit: maxBits - 8))
        XCTAssertNoThrow(try definition(startBit: maxBits - 1, order: .motorola))
        for start in [-1, maxBits, Int.max] {
            XCTAssertThrowsError(try definition(startBit: start))
        }
        XCTAssertThrowsError(try definition(startBit: maxBits - 4, length: 8))
        XCTAssertThrowsError(try definition(startBit: maxBits - 1, length: 9, order: .motorola))
        XCTAssertThrowsError(try definition(startBit: 88, length: 65))
    }

    func testLateFieldStillRejectsAnActuallyShortResponse() throws {
        let d = try definition(startBit: 88)
        let q = try baseline("0C")
        XCTAssertThrowsError(try OBDSignalDecoder.decode(d, response: response(q, payload: [0, 0]))) {
            XCTAssertEqual($0 as? OBDSignalDecodeError, .payloadTooShort)
        }
    }

    func testRawCANDefinitionRemainsLimitedToOneClassicalFrame() {
        XCTAssertThrowsError(try SignalDefinition(id: "raw", name: "Raw", canID: 0x123,
            isExtended: false, startBit: 64, bitLength: 8, byteOrder: .intel, isSigned: false,
            factor: 1, offset: 0, minimum: nil, maximum: nil, unit: "fixture", timeout: 2)) {
            XCTAssertEqual($0 as? SignalDefinitionError, .invalidBitRange)
        }
    }

    func testMode01RPMUsesNetworkByteOrderAndPreservesRealZero() throws {
        let q = try baseline("0C")
        let r = try OBDResponseParser.parse("7E8 04 41 0C 1A F8\r>", for: q,
            receivedAtEpoch: 100, receivedAtMonotonicNanos: 1_000, sequence: 7)
        let sample = try OBDSignalDecoder.decode(q.signals[0], response: r)
        XCTAssertEqual(sample.value, 1726) // (0x1A * 256 + 0xF8) / 4
        XCTAssertEqual(sample.rawValue, 0x1AF8)
        XCTAssertEqual(try OBDSignalDecoder.decode(q.signals[0], response: response(q, payload: [0, 0])).value, 0)
    }

    func testMode01SupportedBitmapKeepsMostSignificantByteFirst() throws {
        let q = try baseline("00")
        let r = try OBDResponseParser.parse("7E8 06 41 00 08 18 00 01\r>", for: q,
            receivedAtEpoch: 100, receivedAtMonotonicNanos: 1_000, sequence: 7)
        let sample = try OBDSignalDecoder.decode(q.signals[0], response: r)
        XCTAssertEqual(sample.rawValue, 0x08180001)
        // Bits corresponding to PIDs 05, 0C, 0D and 20, not a byte-swapped mask.
        XCTAssertEqual(sample.rawValue & 0x08180001, 0x08180001)
    }

    func testSingleByteBaselineAndHVSOCDefinitionsStayCompatible() throws {
        let coolant = try baseline("05")
        let speed = try baseline("0D")
        let soc = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        XCTAssertEqual(try OBDSignalDecoder.decode(coolant.signals[0], response: response(coolant, payload: [0x7B])).value, 83)
        XCTAssertEqual(try OBDSignalDecoder.decode(speed.signals[0], response: response(speed, payload: [0x28])).value, 40)
        XCTAssertEqual(try OBDSignalDecoder.decode(soc.signals[0], response: response(soc, payload: [0, 0, 0, 0, 100])).value, 50)
    }
}
