import XCTest
@testable import TelemetryCore

final class RecordedVINInterpreterTests: XCTestCase {
    private let fixture = Array("ABCDEFGHJKLMNPRST".utf8) // Synthetic, not an issued VIN.
    private var payload: [UInt8] { [0x49, 2, 1] + fixture }
    private func check(_ bytes: [UInt8]? = nil, ecu: String = "ECU-A",
                       framing: RecordedVINFraming = .iso15765CAN,
                       classification: RecordedVINClassification = .payload) -> RecordedVINInterpretation {
        RecordedVINInterpreter.interpret(RecordedVINResponse(ecu: ecu, framing: framing,
            classification: classification, payload: bytes ?? payload))
    }
    func testPositive() { XCTAssertEqual(check().status, .positive); XCTAssertEqual(check().vin, String(decoding: fixture, as: UTF8.self)) }
    func testProvenance() {
        for ecu in ["ECU-A", "ECU-B"] {
            XCTAssertEqual(check(ecu: ecu).response.ecu, ecu)
            XCTAssertEqual(check(ecu: ecu).response.payload, payload)
        }
    }
    func testMissingSource() {
        for ecu in ["", " \n"] { XCTAssertEqual(check(ecu: ecu).issue, "missingSource") }
    }
    func testClassifications() {
        let pairs: [(RecordedVINClassification, RecordedVINStatus)] = [(.noData, .noData), (.unsupported, .unsupported), (.unknown, .unknown), (.malformed, .malformed)]
        for (classification, status) in pairs {
            XCTAssertEqual(check(classification: classification).status, status)
            XCTAssertNil(check(classification: classification).vin)
        }
    }
    func testNegative() {
        let result = check([0x7F, 9, 0x78], classification: .negative)
        XCTAssertEqual(result.status, .negative); XCTAssertEqual(result.negativeCode, 0x78); XCTAssertNil(result.vin)
    }
    func testNegativeMalformed() {
        let cases: [[UInt8]] = [[], [0x7F, 1, 0x78], [0x7F, 9], [0x7F, 9, 0x78, 0]]
        for bytes in cases {
            XCTAssertEqual(check(bytes, classification: .negative).status, .malformed)
        }
    }
    func testLegacyUnknown() {
        let framings: [RecordedVINFraming] = [.legacy, .unknown]
        for framing in framings {
            XCTAssertEqual(check(framing: framing).status, .unknown)
            XCTAssertEqual(check(framing: framing).issue, "unsupportedFraming")
            XCTAssertNil(check(framing: framing).vin)
        }
    }
    func testNoDataLegacy() { XCTAssertEqual(check(framing: .legacy, classification: .noData).status, .noData) }
    func testExactLength() {
        for bytes in [[], Array(payload.dropLast()), payload + [0], payload + [65], [0x10, 0x14] + payload] {
            XCTAssertEqual(check(bytes).status, .malformed)
        }
    }
    func testHeader() {
        let headers: [[UInt8]] = [[0x48, 2, 1], [0x49, 3, 1], [0x49, 2, 0], [0x49, 2, 2]]
        for header in headers {
            XCTAssertEqual(check(header + fixture).status, .malformed)
        }
    }
    func testAllByteAlphabet() {
        let allowed = Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789".utf8)
        for value in 0...255 {
            let byte = UInt8(value)
            XCTAssertEqual(check(Array(payload.dropLast()) + [byte]).status, allowed.contains(byte) ? .positive : .malformed)
        }
    }
    func testNoCheckDigitPolicy() {
        for byte in "ABCDEFGHJKLMNPRSTUVWXYZ0123456789".utf8 {
            var bytes = payload; bytes[11] = byte
            XCTAssertEqual(check(bytes).status, .positive)
        }
    }
    func testNoPartialVIN() { XCTAssertNil(check(Array(payload.dropLast()) + [73]).vin) }
    func testReportAllowlist() {
        XCTAssertEqual(check(ecu: String(decoding: fixture, as: UTF8.self)).supportSummary, ["status": "positive"])
    }
}
