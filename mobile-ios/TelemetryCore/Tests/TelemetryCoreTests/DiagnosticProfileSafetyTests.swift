import Foundation
import XCTest
@testable import TelemetryCore

final class DiagnosticProfileSafetyTests: XCTestCase {
    private func signal(_ id: String, startBit: Int = 0, factor: Double = 1) throws -> OBDSignalDefinition {
        try OBDSignalDefinition(id: id, name: "Measurement", startBit: startBit,
            bitLength: 8, byteOrder: .intel, isSigned: false, factor: factor, offset: 0,
            minimum: nil, maximum: nil, unit: "fixture", timeout: 2)
    }

    private func query(_ id: String = "query", signals: [OBDSignalDefinition],
                       interval: Double = 0.125) throws -> OBDQueryDefinition {
        try OBDQueryDefinition(id: id, name: "Fixture query", requestCANID: 0x7E4,
            responseCANID: 0x7EC, isExtended: false, service: .service22, command: "0101",
            pollInterval: interval, timeout: max(1, interval), flowControl: true,
            sourceRepository: "test-fixture", sourcePath: "independent", sourceCommit: "fixture-v1",
            signals: signals)
    }

    private func raw(_ id: String) throws -> SignalDefinition {
        try SignalDefinition(id: id, name: "Measurement", canID: 0x123, isExtended: false,
            startBit: 0, bitLength: 8, byteOrder: .intel, isSigned: false, factor: 1,
            offset: 0, minimum: nil, maximum: nil, unit: "fixture", timeout: 2)
    }

    private func profile(raw: [SignalDefinition] = [],
                         queries: [OBDQueryDefinition] = []) throws -> AdapterProfile {
        // Loopback is fixture metadata only; these tests never open a transport.
        try AdapterProfile(id: "fixture-profile", name: "Fixture", transport: .wifi,
            peripheralID: nil, serviceUUID: nil, writeCharacteristicUUID: nil,
            notifyCharacteristicUUID: nil, host: "127.0.0.1", port: 35000,
            signals: raw, diagnosticQueries: queries)
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    func testQueryConstructorRejectsDuplicateSignalIDsBeforeResponseDelivery() throws {
        let signals = try [signal("soc"), signal("soc", startBit: 8)]
        XCTAssertThrowsError(try query(signals: signals))
    }

    func testQueryJSONRejectsDuplicateSignalIDs() throws {
        var json = try object(query(signals: [signal("soc")]))
        let entry = try object(signal("soc"))
        json["signals"] = [entry, entry]
        XCTAssertThrowsError(try JSONDecoder().decode(OBDQueryDefinition.self, from: data(json)))
    }

    func testProfileRejectsSignalCollisionAcrossDistinctQueries() throws {
        let queries = try [query("a", signals: [signal("soc")]), query("b", signals: [signal("soc")])]
        XCTAssertThrowsError(try profile(queries: queries)) {
            XCTAssertEqual($0 as? AdapterProfileError, .duplicateSignalID("soc"))
        }
    }

    func testProfileJSONRejectsSignalCollisionAcrossDistinctQueries() throws {
        let a = try query("a", signals: [signal("soc")])
        let b = try query("b", signals: [signal("soc")])
        var json = try object(profile(queries: [a]))
        json["diagnosticQueries"] = try [object(a), object(b)]
        XCTAssertThrowsError(try JSONDecoder().decode(AdapterProfile.self, from: data(json))) {
            XCTAssertEqual($0 as? AdapterProfileError, .duplicateSignalID("soc"))
        }
    }

    func testProfileRejectsRawAndDiagnosticSignalIDCollision() throws {
        let r = try raw("speed")
        let q = try query(signals: [signal("speed")])
        XCTAssertThrowsError(try profile(raw: [r], queries: [q])) {
            XCTAssertEqual($0 as? AdapterProfileError, .duplicateSignalID("speed"))
        }
    }

    func testProfileJSONRejectsRawAndDiagnosticSignalIDCollision() throws {
        var json = try object(profile(raw: [raw("speed")]))
        json["schema_version"] = 2
        json["diagnosticQueries"] = try [object(query(signals: [signal("speed")]))]
        XCTAssertThrowsError(try JSONDecoder().decode(AdapterProfile.self, from: data(json))) {
            XCTAssertEqual($0 as? AdapterProfileError, .duplicateSignalID("speed"))
        }
    }

    func testDuplicateQueryIDsRemainRejected() throws {
        let a = try query("same", signals: [signal("soc")])
        let b = try query("same", signals: [signal("rpm")])
        XCTAssertThrowsError(try profile(queries: [a, b])) {
            XCTAssertEqual($0 as? AdapterProfileError, .duplicateDiagnosticQueryID("same"))
        }
    }

    func testUniqueIDsMayShareDisplayLabelsAndRoundTripSchemaTwo() throws {
        let a = try query("a", signals: [signal("soc"), signal("voltage", startBit: 8)])
        let b = try query("b", signals: [signal("rpm")])
        let original = try profile(raw: [raw("wheel-speed")], queries: [a, b])
        XCTAssertEqual(original.schemaVersion, 2)
        let restored = try JSONDecoder().decode(AdapterProfile.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.diagnosticQueries.flatMap(\.signals).map(\.id), ["soc", "voltage", "rpm"])
    }

    func testRawOnlySchemaOneRemainsUnchanged() throws {
        let original = try profile(raw: [raw("wheel-speed")])
        XCTAssertEqual(original.schemaVersion, 1)
        XCTAssertEqual(try JSONDecoder().decode(AdapterProfile.self, from: JSONEncoder().encode(original)), original)
    }

    func testValidMultiSignalResponseStillDecodesIndependentValues() throws {
        let q = try query(signals: [signal("soc", factor: 0.5), signal("other", startBit: 8)])
        let response = try OBDResponseParser.parse("7EC 05 62 01 01 64 2A\r>", for: q,
            receivedAtEpoch: 100, receivedAtMonotonicNanos: 1_000, sequence: 7)
        let values = try q.signals.map { try OBDSignalDecoder.decode($0, response: response) }
        // Independent fixture values: 0x64 / 2 = 50; 0x2A = 42.
        XCTAssertEqual(values.map(\.value), [50, 42])
        XCTAssertEqual(values.map(\.signalID), ["soc", "other"])
        XCTAssertEqual(response.payload, [0x64, 0x2A])
        XCTAssertEqual(response.receivedAtEpoch, 100)
    }

    func testFinitePollIntervalCannotOverflowSchedulerNanoseconds() throws {
        let signals = try [signal("soc")]
        for interval in [Double.greatestFiniteMagnitude, 1e20, Double(UInt64.max) / 1e9] {
            XCTAssertThrowsError(try query(signals: signals, interval: interval)) {
                XCTAssertEqual($0 as? OBDQueryError, .invalidTiming)
            }
        }
    }

    func testJSONCannotBypassPollingConversionValidation() throws {
        var json = try object(query(signals: [signal("soc")]))
        json["pollInterval"] = 1e20
        json["timeout"] = 1e20
        XCTAssertThrowsError(try JSONDecoder().decode(OBDQueryDefinition.self, from: data(json))) {
            XCTAssertEqual($0 as? OBDQueryError, .invalidTiming)
        }
    }

    func testSubNanosecondPollingCannotBecomeZeroDelay() throws {
        let signals = try [signal("soc")]
        for interval in [Double.leastNonzeroMagnitude, 0.5e-9, (1e-9).nextDown] {
            XCTAssertThrowsError(try query(signals: signals, interval: interval)) {
                XCTAssertEqual($0 as? OBDQueryError, .invalidTiming)
            }
        }
    }

    func testSmallestRepresentableDelayAndFractionalNanosecondsStayCompatible() throws {
        let signals = try [signal("soc")]
        for interval in [1e-9, 1.5e-9] {
            let q = try query(signals: signals, interval: interval)
            XCTAssertEqual(q.pollInterval, interval)
            XCTAssertEqual(UInt64(q.pollInterval * 1e9), 1)
        }
    }

    func testOrdinaryIntervalsKeepWireValuesAndSchedulerConversion() throws {
        let signals = try [signal("soc")]
        for (interval, nanos) in [(0.125, UInt64(125_000_000)), (1.0, 1_000_000_000),
                                  (60.0, 60_000_000_000), (3600.0, 3_600_000_000_000)] {
            let q = try query(signals: signals, interval: interval)
            let restored = try JSONDecoder().decode(OBDQueryDefinition.self, from: JSONEncoder().encode(q))
            XCTAssertEqual(restored, q)
            XCTAssertEqual(UInt64(restored.pollInterval * 1e9), nanos)
            XCTAssertEqual(restored.requestString, "220101\r")
        }
    }

    func testLargeRepresentablePollingIntervalIsNotArbitrarilyClamped() throws {
        let interval = (Double(UInt64.max) / 1e9).nextDown
        let q = try query(signals: [signal("soc")], interval: interval)
        XCTAssertEqual(q.pollInterval, interval)
        XCTAssertNotNil(UInt64(exactly: (q.pollInterval * 1e9).rounded(.towardZero)))
    }
}
