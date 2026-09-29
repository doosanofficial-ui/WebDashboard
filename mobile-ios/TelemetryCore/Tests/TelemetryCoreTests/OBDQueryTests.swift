import XCTest
@testable import TelemetryCore

final class OBDQueryTests: XCTestCase {
    private func definition(
        service: OBDService = .service22,
        command: String = "0101"
    ) throws -> OBDQueryDefinition {
        let signal = try OBDSignalDefinition(
            id: "SANTAFEHYB_HVBAT_SOC",
            name: "HV battery charge",
            startBit: 0,
            bitLength: 8,
            byteOrder: .intel,
            isSigned: false,
            factor: 0.5,
            offset: 0,
            minimum: 0,
            maximum: 100,
            unit: "percent",
            timeout: 3,
            enumMap: [:],
            suggestedMetric: "stateOfCharge",
            path: "Battery"
        )
        return try OBDQueryDefinition(
            id: "santafe-hybrid-hv-soc",
            name: "Santa Fe Hybrid HV SOC",
            requestCANID: 0x7E4,
            responseCANID: 0x7EC,
            isExtended: false,
            service: service,
            command: command,
            pollInterval: 1,
            timeout: 3,
            flowControl: true,
            sourceRepository: "OBDb/Hyundai-Santa-Fe-Hybrid",
            sourcePath: "signalsets/v3/default.json",
            sourceCommit: "fixture",
            signals: [signal]
        )
    }

    func testService22BuildsAnELMRequestWithoutMonitorAll() throws {
        let query = try definition()

        XCTAssertEqual(query.requestString, "220101\r")
        XCTAssertFalse(query.requestString.uppercased().contains("MA"))
        XCTAssertEqual(query.responseCANID, 0x7EC)
        XCTAssertTrue(query.flowControl)
    }

    func testSingleFrameResponseStripsHeaderDLCServiceAndCommand() throws {
        let query = try definition()

        let response = try OBDResponseParser.parse(
            "7EC 04 62 01 01 64\r",
            for: query,
            receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 200,
            sequence: 1
        )

        XCTAssertEqual(response.responseCANID, 0x7EC)
        XCTAssertEqual(response.service, .service22)
        XCTAssertEqual(response.command, "0101")
        XCTAssertEqual(response.payload, [0x64])
        XCTAssertEqual(response.sequence, 1)
    }

    func testMultiFrameResponseReassemblesISO15765Payload() throws {
        let query = try definition(command: "0102")
        let response = try OBDResponseParser.parse(
            "7EC 10 0C 62 01 02 64 65\r7EC 21 66 67 68 69 6A 6B 6C\r",
            for: query,
            receivedAtEpoch: 101,
            receivedAtMonotonicNanos: 201,
            sequence: 2
        )

        XCTAssertEqual(response.payload, [0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C])
    }

    func testWrongResponseAndNegativeResponsesFailClosed() throws {
        let query = try definition()

        XCTAssertThrowsError(try OBDResponseParser.parse(
            "7ED 04 62 01 01 64\r",
            for: query,
            receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 200,
            sequence: 1
        )) { error in
            XCTAssertEqual(error as? OBDResponseError, .unexpectedResponse)
        }

        XCTAssertThrowsError(try OBDResponseParser.parse(
            "7EC 03 7F 22 31\r",
            for: query,
            receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 200,
            sequence: 1
        )) { error in
            XCTAssertEqual(error as? OBDResponseError, .negativeResponse(code: 0x31))
        }
    }

    func testSignalDecoderAppliesScaleLimitsAndSuggestedMetric() throws {
        let query = try definition()
        let response = try OBDResponseParser.parse(
            "7EC 04 62 01 01 64\r",
            for: query,
            receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 200,
            sequence: 1
        )

        let decoded = try OBDSignalDecoder.decode(query.signals[0], response: response)

        XCTAssertEqual(decoded.signalID, "SANTAFEHYB_HVBAT_SOC")
        XCTAssertEqual(decoded.rawValue, 0x64)
        XCTAssertEqual(decoded.value, 50)
        XCTAssertEqual(decoded.unit, "percent")
        XCTAssertEqual(decoded.suggestedMetric, "stateOfCharge")
    }

    func testSignalDecoderSupportsSignedValuesAndEnums() throws {
        let signal = try OBDSignalDefinition(
            id: "signed",
            name: "Signed",
            startBit: 0,
            bitLength: 8,
            byteOrder: .intel,
            isSigned: true,
            factor: 0.5,
            offset: -1,
            minimum: -65,
            maximum: 63,
            unit: "scalar",
            timeout: 1,
            enumMap: [0: "OFF", 255: "ON"],
            suggestedMetric: nil,
            path: "Control"
        )
        let query = try definition()
        let response = try OBDResponseParser.parse(
            "7EC 04 62 01 01 FF\r",
            for: query,
            receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 200,
            sequence: 1
        )

        let decoded = try OBDSignalDecoder.decode(signal, response: response)

        XCTAssertEqual(decoded.signedRawValue, -1)
        XCTAssertEqual(decoded.value, -1.5)
        XCTAssertEqual(decoded.enumName, "ON")
    }

    func testCompactOBDbGoldenResponseDecodesSantaFeHybridSOC() throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let response = try OBDResponseParser.parse(
            """
            7EC103E6201018FF3FF
            7EC21EF650000000000
            7EC2200280A29292323
            7EC23272823000038B5
            7EC2425B402096D8800
            7EC2502323F00023200
            7EC260000980A000090
            7EC2755003B61530001
            7EC2805097E177503E8
            """,
            for: query,
            receivedAtEpoch: 200,
            receivedAtMonotonicNanos: 300,
            sequence: 9,
            sourceAdapter: "fixture-elm327",
            sourceTransport: "fixture"
        )

        let decoded = try OBDSignalDecoder.decode(query.signals[0], response: response)

        XCTAssertEqual(response.payload[4], 0x65)
        XCTAssertEqual(decoded.rawValue, 0x65)
        XCTAssertEqual(decoded.value, 50.5)
        XCTAssertEqual(decoded.sourceAdapter, "fixture-elm327")
        XCTAssertEqual(decoded.sourceTransport, "fixture")
    }

    func testSantaFeCatalogCarriesOBDbProvenanceAndReadOnlyQueryShape() throws {
        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()

        XCTAssertEqual(query.requestCANID, 0x7E4)
        XCTAssertEqual(query.responseCANID, 0x7EC)
        XCTAssertEqual(query.requestString, "220101\r")
        XCTAssertTrue(query.flowControl)
        XCTAssertEqual(query.sourceRepository, "OBDb/Hyundai-Santa-Fe-Hybrid")
        XCTAssertEqual(query.sourceCommit, "c14ff9dd8a87482604200a859d7d734234d98892")
        XCTAssertEqual(query.signals[0].startBit, 32)
        XCTAssertEqual(query.signals[0].factor, 0.5)
        XCTAssertEqual(query.signals[0].suggestedMetric, "stateOfCharge")
    }

    func testInitialSantaFeCatalogChecksBaselineBeforeHVSignal() throws {
        let queries = try SantaFeMX5HybridQueryCatalog.initialQueries()

        XCTAssertEqual(queries.count, 5)
        XCTAssertEqual(queries.prefix(4).map(\.service), [.mode01, .mode01, .mode01, .mode01])
        XCTAssertEqual(queries.last?.id, "santafe-mx5-hev-hv-soc")
    }

    func testInvalidQueryTimingAndEmptySignalsAreRejected() throws {
        let signal = try OBDSignalDefinition(
            id: "signal",
            name: "Signal",
            startBit: 0,
            bitLength: 8,
            byteOrder: .intel,
            isSigned: false,
            factor: 1,
            offset: 0,
            minimum: 0,
            maximum: 255,
            unit: "scalar",
            timeout: 1,
            enumMap: [:],
            suggestedMetric: nil,
            path: "Engine"
        )

        XCTAssertThrowsError(try OBDQueryDefinition(
            id: "bad",
            name: "Bad",
            requestCANID: 0x7E4,
            responseCANID: 0x7EC,
            isExtended: false,
            service: .service22,
            command: "0101",
            pollInterval: 0,
            timeout: 1,
            flowControl: false,
            sourceRepository: "fixture",
            sourcePath: "fixture",
            sourceCommit: "fixture",
            signals: [signal]
        )) { error in
            XCTAssertEqual(error as? OBDQueryError, .invalidTiming)
        }

        XCTAssertThrowsError(try OBDQueryDefinition(
            id: "empty",
            name: "Empty",
            requestCANID: 0x7E4,
            responseCANID: 0x7EC,
            isExtended: false,
            service: .service22,
            command: "0101",
            pollInterval: 1,
            timeout: 1,
            flowControl: false,
            sourceRepository: "fixture",
            sourcePath: "fixture",
            sourceCommit: "fixture",
            signals: []
        )) { error in
            XCTAssertEqual(error as? OBDQueryError, .emptySignalCatalog)
        }
    }
}
