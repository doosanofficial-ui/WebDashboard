import Foundation
import XCTest
@testable import TelemetryCore

final class ELM327Tests: XCTestCase {
    func testCommandsAreTypedMode01ReadsOnly() {
        XCTAssertEqual(OBDPID.allCases.map { String(decoding: $0.command, as: UTF8.self) },
                       ["0100\r", "0105\r", "010C\r", "010D\r"])
        XCTAssertNil(OBDPID(rawValue: 0x2F))
    }

    func testFragmentedNotificationsWaitForPromptAndPreserveMultipleResponses() throws {
        var framer = ELM327Framer()
        XCTAssertEqual(try framer.feed(Data("41 0C 1".utf8)), [])
        XCTAssertEqual(try framer.feed(Data("A F8\r>41 0D 00\r>".utf8)),
                       ["41 0C 1A F8\r", "41 0D 00\r"])
        XCTAssertEqual(try framer.feed(Data(">".utf8)), [])
    }

    func testOversizedAndInvalidByteInputDiscardsPartialState() throws {
        var framer = ELM327Framer()
        _ = try framer.feed(Data("41 0C".utf8))
        XCTAssertThrowsError(try framer.feed(Data(repeating: 65, count: 4097)))
        XCTAssertEqual(try framer.feed(Data("410D00>".utf8)), ["410D00"])
        XCTAssertThrowsError(try framer.feed(Data([0xFF])))
        XCTAssertThrowsError(try framer.feed(Data([0])))
        _ = try framer.feed(Data(repeating: 65, count: 4090))
        XCTAssertThrowsError(try framer.feed(Data(repeating: 65, count: 7)))
        XCTAssertEqual(try framer.feed(Data("410D01>".utf8)), ["410D01"])
    }

    func testScalingAndGenuineZeroHaveExplicitUnits() throws {
        XCTAssertEqual(try ELM327Decoder.decode("41 0C 1A F8", for: .rpm),
                       .measurement(signal: "obd_engine_rpm", value: 1726, unit: "rpm"))
        XCTAssertEqual(try ELM327Decoder.decode("41 05 7B", for: .coolant),
                       .measurement(signal: "obd_coolant_c", value: 83, unit: "degC"))
        XCTAssertEqual(try ELM327Decoder.decode("410D28", for: .speed),
                       .measurement(signal: "obd_vehicle_speed_kmh", value: 40, unit: "km/h"))
        XCTAssertEqual(try ELM327Decoder.decode("410C0000", for: .rpm),
                       .measurement(signal: "obd_engine_rpm", value: 0, unit: "rpm"))
        XCTAssertEqual(try ELM327Decoder.decode("410D00", for: .speed),
                       .measurement(signal: "obd_vehicle_speed_kmh", value: 0, unit: "km/h"))
    }

    func testCapabilityBitmapUsesMostSignificantBitForPIDOne() throws {
        XCTAssertEqual(try ELM327Decoder.decode("410008180001", for: .supported),
                       .supported([0x05, 0x0C, 0x0D, 0x20]))
        XCTAssertEqual(try ELM327Decoder.decode("410080000000", for: .supported), .supported([1]))
        XCTAssertEqual(try ELM327Decoder.decode("410000000000", for: .supported), .supported([]))
    }

    func testNoDataIsNeitherNumericZeroNorConfirmedUnsupported() throws {
        XCTAssertEqual(try ELM327Decoder.decode("010C\rNO DATA\r", for: .rpm), .noData)
        for response in ["?", "STOPPED", "CAN ERROR", "UNABLE TO CONNECT", "BUS ERROR"] {
            XCTAssertThrowsError(try ELM327Decoder.decode(response, for: .rpm))
        }
    }

    func testWrongPIDMalformedHeadersAndMultipleECUsFailClosed() {
        for response in ["410D00", "410C1A", "410C1AF800", "410CZZZZ", "", "OK",
                         "7E8 04 41 0C 1A F8", "410C1AF8\r410C1AF8", "410C1AF8\rNO DATA",
                         "410C1AF8\rSTOPPED", "\u{00FF}", "410C1AF8>"] {
            XCTAssertThrowsError(try ELM327Decoder.decode(response, for: .rpm), response)
        }
        XCTAssertThrowsError(try ELM327Decoder.decode(String(repeating: "A", count: 4097), for: .rpm))
    }

    func testEchoSearchWhitespaceAndLowercaseAreHandledWithoutInventingValues() throws {
        XCTAssertEqual(try ELM327Decoder.decode("01 0c\r\nSEARCHING...41 0c 1a f8\r\n", for: .rpm),
                       .measurement(signal: "obd_engine_rpm", value: 1726, unit: "rpm"))
        XCTAssertThrowsError(try ELM327Decoder.decode("010C\rSEARCHING...", for: .rpm))
    }
}
