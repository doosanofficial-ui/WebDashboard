import XCTest
@testable import TelemetryCore

final class CustomOBDPIDDraftTests: XCTestCase {
    private func draft() -> CustomOBDPIDDraft {
        var d = CustomOBDPIDDraft()
        d.id = "custom.coolant"; d.name = "Coolant"
        d.service = .mode01; d.command = "05"; d.requestCANID = "7E0"; d.responseCANID = "7E8"
        d.offset = "-40"; d.unit = "°C"
        return d
    }

    private func profile() throws -> AdapterProfile {
        var d = draft(); d.id = "existing.coolant"
        return try AdapterProfile(id: "fixture", name: "SYNTHETIC diagnostic profile", transport: .wifi,
            peripheralID: nil, serviceUUID: nil, writeCharacteristicUUID: nil,
            notifyCharacteristicUUID: nil, host: "127.0.0.1", port: 35000,
            signals: [], diagnosticQueries: [d.makeQuery()])
    }

    func testReadOnlyRequestAndOfflinePreview() throws {
        let d = draft(), q = try d.makeQuery()
        XCTAssertEqual(q.requestString, "0105\r")
        XCTAssertEqual(q.sourceRepository, "local-user")
        XCTAssertEqual(q.signals.first?.offset, -40)
        XCTAssertEqual(try d.preview("7E8 03 41 05 64").value, 60)
        XCTAssertEqual(try d.preview("7E8 03 41 05 28").value, 0)
    }

    func testInputCannotInjectELMCommandsOrInvalidNumbers() {
        let mutations: [(inout CustomOBDPIDDraft) -> Void] = [
            { $0.command = "05\rATZ" }, { $0.requestCANID = "7E0\nATSH" },
            { $0.responseCANID = "800" }, { $0.factor = "" }, { $0.factor = "nan" },
            { $0.offset = "infinity" }, { $0.minimum = "bad" },
            { $0.minimum = "50"; $0.maximum = "10" }, { $0.bitLength = "0" },
            { $0.startBit = "-1" }, { $0.pollInterval = "0" }, { $0.timeout = "0.1" },
            { $0.id = "  " }, { $0.name = " " }, { $0.id = "bad\nID" }
        ]
        for change in mutations {
            var d = draft(); change(&d)
            XCTAssertThrowsError(try d.makeQuery(), "Expected invalid draft: \(d)")
        }
        XCTAssertNil(OBDService(rawValue: "04"))
        XCTAssertNil(OBDService(rawValue: "2E"))
    }

    func testPreviewRejectsNoDataWrongECUAndExcessiveInput() {
        for response in ["NO DATA", "7E9 03 41 05 64", "7E8 03 41 0C 64", String(repeating: "A", count: 65537)] {
            XCTAssertThrowsError(try draft().preview(response))
        }
    }

    func testAdditionPreservesProfileAndRequiresSameSnapshot() throws {
        let original = try profile()
        let updated = try draft().appending(to: original, expected: original)
        XCTAssertEqual(updated.diagnosticQueries.count, 2)
        XCTAssertEqual(updated.diagnosticQueries.first, original.diagnosticQueries.first)
        XCTAssertEqual(updated.host, original.host)
        XCTAssertEqual(updated.signals, original.signals)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(try JSONDecoder().decode(AdapterProfile.self, from: JSONEncoder().encode(updated)), updated)
        XCTAssertThrowsError(try draft().appending(to: updated, expected: original))
        XCTAssertThrowsError(try draft().appending(to: updated, expected: updated))
    }

    func testBLEAddressAndEveryExistingFieldRemainUnchanged() throws {
        let original = try profile()
        let ble = try AdapterProfile(id: original.id, name: original.name, transport: .ble,
            peripheralID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            serviceUUID: "ABCD", writeCharacteristicUUID: "ABCE", notifyCharacteristicUUID: "ABCF",
            host: nil, port: nil, signals: [], diagnosticQueries: original.diagnosticQueries)
        let updated = try draft().appending(to: ble, expected: ble)
        let reconstructed = try AdapterProfile(id: updated.id, name: updated.name, transport: updated.transport,
            peripheralID: updated.peripheralID, serviceUUID: updated.serviceUUID,
            writeCharacteristicUUID: updated.writeCharacteristicUUID,
            notifyCharacteristicUUID: updated.notifyCharacteristicUUID, host: updated.host, port: updated.port,
            signals: updated.signals, diagnosticQueries: Array(updated.diagnosticQueries.dropLast()))
        XCTAssertEqual(reconstructed, ble)
        XCTAssertEqual(updated.diagnosticQueries.last, try draft().makeQuery())
    }

    func testExtendedHeaderAndService22() throws {
        var d = draft(); d.service = .service22; d.command = "abcd"; d.isExtended = true
        d.requestCANID = "0x18DA10F1"; d.responseCANID = "18DAF110"
        XCTAssertEqual(try d.makeQuery().requestString, "22ABCD\r")
        d.responseCANID = "FFFFFFFF"
        XCTAssertThrowsError(try d.makeQuery())
    }

    func testPassiveProfileCannotBeSilentlyConvertedToPolling() throws {
        let s = try SignalDefinition(id: "raw", name: "Raw", canID: 1, isExtended: false,
            startBit: 0, bitLength: 8, byteOrder: .intel, isSigned: false,
            factor: 1, offset: 0, minimum: nil, maximum: nil, unit: "", timeout: 1)
        let p = try AdapterProfile(id: "raw", name: "Passive", transport: .wifi, peripheralID: nil,
            serviceUUID: nil, writeCharacteristicUUID: nil, notifyCharacteristicUUID: nil,
            host: "127.0.0.1", port: 35000, signals: [s])
        XCTAssertThrowsError(try draft().appending(to: p, expected: p))
    }
}
