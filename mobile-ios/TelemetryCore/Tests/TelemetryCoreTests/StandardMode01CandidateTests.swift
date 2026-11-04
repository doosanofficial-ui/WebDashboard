import XCTest
@testable import TelemetryCore

final class StandardMode01CandidateTests: XCTestCase {
    private func context(request: UInt32 = 0x7E0, response: UInt32 = 0x7E8,
                         extended: Bool = false, poll: Double = 1, timeout: Double = 3,
                         stale: Double = 5, minimum: Double = 0.5,
                         maximum: Double = 10) throws -> StandardMode01CandidateContext {
        try .init(requestCANID: request, responseCANID: response, isExtended: extended,
                  pollInterval: poll, timeout: timeout, signalTimeout: stale,
                  minimumPollInterval: minimum, maximumTimeout: maximum)
    }
    private func response(_ pid: StandardMode01Candidate, _ payload: [UInt8],
                          canID: UInt32 = 0x7E8, service: OBDService = .mode01,
                          command: String? = nil) -> OBDResponse {
        OBDResponse(receivedAtEpoch: 1, receivedAtMonotonicNanos: 1,
                    responseCANID: canID, isExtended: false, service: service,
                    command: command ?? pid.rawValue, payload: payload, sequence: 1,
                    sourceAdapter: "synthetic", sourceTransport: "fixture")
    }
    func testExistingDecoderAgainstIndependentBoundaryExpectations() throws {
        let cases: [(StandardMode01Candidate, Int, String, Double, Double)] = [
            (.load, 1, "percent", 0, 100), (.fuelPressure, 1, "kPa", 0, 765),
            (.manifoldPressure, 1, "kPa", 0, 255), (.intakeTemperature, 1, "degC", -40, 215),
            (.airMassFlow, 2, "g/s", 0, 655.35), (.throttle, 1, "percent", 0, 100),
            (.engineRuntime, 2, "s", 0, 65535), (.fuelLevel, 1, "percent", 0, 100),
            (.barometricPressure, 1, "kPa", 0, 255), (.moduleVoltage, 2, "V", 0, 65.535),
            (.ambientTemperature, 1, "degC", -40, 215), (.oilTemperature, 1, "degC", -40, 215), (.fuelRate, 2, "L/h", 0, 3276.75), (.railGaugePressure, 2, "kPa", 0, 655350)
        ]
        XCTAssertEqual(StandardMode01Candidate.allCases.count, cases.count)
        for (pid, length, unit, low, high) in cases {
            let ctx = try context()
            let signal = try pid.signalDefinition(context: ctx)
            XCTAssertEqual(signal.unit, unit)
            XCTAssertEqual(signal.startBit, 7)
            XCTAssertEqual(signal.byteOrder, .motorola)
            XCTAssertEqual(signal.bitLength, length * 8)
            XCTAssertFalse(signal.isSigned)
            XCTAssertNil(signal.suggestedMetric)
            for (byte, expected) in [(UInt8(0), low), (UInt8(255), high)] {
                let value = response(pid, Array(repeating: byte, count: length))
                try pid.validateResponse(value, context: ctx)
                XCTAssertEqual(try OBDSignalDecoder.decode(signal, response: value).value,
                               expected, accuracy: 1e-10)
            }
            for size in 0...4 where size != length {
                XCTAssertThrowsError(try pid.validateResponse(response(pid, Array(repeating: 0, count: size)), context: ctx))
            }
        }
    }
    func testRailPressureReferenceAndResolution() throws {
        let pid = StandardMode01Candidate.railGaugePressure
        let ctx = try context()
        let signal = try pid.signalDefinition(context: ctx)
        XCTAssertEqual(signal.name, "Fuel rail pressure (atmospheric gauge)")
        XCTAssertTrue(pid.sourceDocumentationURL.contains("attachmentid=1800282"))
        XCTAssertTrue(pid.sourceDocumentationSection.contains("OCT2011"))
        for (bytes, expected) in [([0, 1], 10), ([1, 0], 2560), ([1, 2], 2580), ([128, 128], 328960)] as [([UInt8], Double)] {
            let value = response(pid, bytes)
            try pid.validateResponse(value, context: ctx)
            XCTAssertEqual(try OBDSignalDecoder.decode(signal, response: value).value, expected, accuracy: 1e-10)
        }
    }
    func testFuelRateSourceAndResolution() throws {
        let pid = StandardMode01Candidate.fuelRate
        XCTAssertEqual(pid.sourceDocumentationURL, "https://www.dashlogic.com/docs/technical/obdii_pids")
        XCTAssertEqual(StandardMode01Candidate.load.sourceDocumentationURL, StandardMode01Candidate.documentationURL)
        let ctx = try context()
        for (bytes, expected) in [([0, 1], 0.05), ([1, 0], 12.8), ([1, 2], 12.9), ([128, 128], 1644.8)] as [([UInt8], Double)] {
            let value = response(pid, bytes)
            try pid.validateResponse(value, context: ctx)
            XCTAssertEqual(try OBDSignalDecoder.decode(pid.signalDefinition(context: ctx), response: value).value, expected, accuracy: 1e-10)
        }
    }
    func testAsymmetricBytes() throws {
        for (pid, expected) in [(StandardMode01Candidate.airMassFlow, 2.58), (.engineRuntime, 258), (.moduleVoltage, 0.258)] {
            let ctx = try context()
            let value = response(pid, [1, 2])
            try pid.validateResponse(value, context: ctx)
            XCTAssertEqual(try OBDSignalDecoder.decode(pid.signalDefinition(context: ctx), response: value).value, expected, accuracy: 1e-12)
        }
    }
    func testExactResponseIdentity() throws {
        let pid = StandardMode01Candidate.load
        let ctx = try context()
        XCTAssertThrowsError(try pid.validateResponse(response(pid, [0], canID: 0x7E9), context: ctx))
        XCTAssertThrowsError(try pid.validateResponse(response(pid, [0], service: .service22), context: ctx))
        XCTAssertThrowsError(try pid.validateResponse(response(pid, [0], command: "11"), context: ctx))
        XCTAssertThrowsError(try pid.validateResponse(response(pid, [0]), context: context(extended: true)))
    }
    func testNoVehicleSupportClaimOrUnknownCandidateCoercion() {
        for pid in StandardMode01Candidate.allCases {
            XCTAssertFalse(pid.supportGuaranteed)
            XCTAssertFalse(pid.automaticallySelected)
        }
        for text in ["0C", "05", "0D", "FF", "04 ", "watts"] {
            XCTAssertNil(StandardMode01Candidate(rawValue: text))
        }
    }
    func testExplicitContextValidation() throws {
        XCTAssertNoThrow(try context(request: 0, response: 0x7FF))
        XCTAssertNoThrow(try context(request: 0x1FFFFFFF, response: 0x1FFFFFFF, extended: true))
        XCTAssertThrowsError(try context(request: 0x800))
        XCTAssertThrowsError(try context(response: 0x800))
        XCTAssertThrowsError(try context(response: 0x20000000, extended: true))
        for invalid in [0, -1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try context(poll: invalid))
            XCTAssertThrowsError(try context(timeout: invalid))
            XCTAssertThrowsError(try context(stale: invalid))
            XCTAssertThrowsError(try context(minimum: invalid))
            XCTAssertThrowsError(try context(maximum: invalid))
        }
        XCTAssertThrowsError(try context(poll: 0.25))
        XCTAssertThrowsError(try context(poll: 4))
        XCTAssertThrowsError(try context(timeout: 11, stale: 12))
        XCTAssertThrowsError(try context(stale: 2))
        XCTAssertThrowsError(try context(poll: 1e-10, minimum: 1e-10))
        XCTAssertThrowsError(try context(poll: 2e10, timeout: 2e10, stale: 2e10, maximum: 2e10))
        XCTAssertNoThrow(try context(poll: 1e-9, minimum: 1e-9))
    }
}
