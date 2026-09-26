import Foundation
import XCTest
@testable import TelemetryCore

final class AdapterProfileTests: XCTestCase {
    private func signal(id: String = "speed") throws -> SignalDefinition {
        try SignalDefinition(
            id: id, name: id, canID: 0x123, isExtended: false,
            startBit: 0, bitLength: 16, byteOrder: .intel, isSigned: false,
            factor: 0.1, offset: 0, minimum: 0, maximum: 6553.5,
            unit: "km/h", timeout: 0.5
        )
    }

    func testWiFiProfileAndSignalCatalogRoundTrip() throws {
        let profile = try AdapterProfile(
            id: "bt4n-wifi",
            name: "BT4N Wi-Fi observed profile",
            transport: .wifi,
            peripheralID: nil,
            serviceUUID: nil,
            writeCharacteristicUUID: nil,
            notifyCharacteristicUUID: nil,
            host: "192.168.4.1",
            port: 35000,
            signals: [try signal()]
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AdapterProfile.self, from: data)

        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.signal(id: "speed")?.canID, 0x123)
    }

    func testUnsupportedSchemaVersionIsRejected() throws {
        let json = Data("""
        {"schema_version":2,"id":"x","name":"X","transport":"wifi","host":"127.0.0.1","port":1,"signals":[]}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AdapterProfile.self, from: json)) { error in
            XCTAssertEqual(error as? AdapterProfileError, .unsupportedSchemaVersion(2))
        }
    }

    func testDuplicateSignalIDsAreRejected() throws {
        XCTAssertThrowsError(try AdapterProfile(
            id: "duplicate", name: "Duplicate", transport: .wifi,
            peripheralID: nil, serviceUUID: nil, writeCharacteristicUUID: nil,
            notifyCharacteristicUUID: nil, host: "127.0.0.1", port: 1,
            signals: [try signal(), try signal()]
        )) { error in
            XCTAssertEqual(error as? AdapterProfileError, .duplicateSignalID("speed"))
        }
    }

    func testTransportSpecificRequiredFieldsFailClosed() throws {
        XCTAssertThrowsError(try AdapterProfile(
            id: "wifi-missing", name: "Wi-Fi", transport: .wifi,
            peripheralID: nil, serviceUUID: nil, writeCharacteristicUUID: nil,
            notifyCharacteristicUUID: nil, host: nil, port: nil, signals: [try signal()]
        )) { error in
            XCTAssertEqual(error as? AdapterProfileError, .missingWiFiEndpoint)
        }

        XCTAssertThrowsError(try AdapterProfile(
            id: "ble-missing", name: "BLE", transport: .ble,
            peripheralID: nil, serviceUUID: "", writeCharacteristicUUID: "",
            notifyCharacteristicUUID: "", host: nil, port: nil, signals: [try signal()]
        )) { error in
            XCTAssertEqual(error as? AdapterProfileError, .missingBLEProfile)
        }
    }

    func testEmptySignalCatalogIsRejected() throws {
        XCTAssertThrowsError(try AdapterProfile(
            id: "empty", name: "Empty", transport: .wifi,
            peripheralID: nil, serviceUUID: nil, writeCharacteristicUUID: nil,
            notifyCharacteristicUUID: nil, host: "127.0.0.1", port: 1, signals: []
        )) { error in
            XCTAssertEqual(error as? AdapterProfileError, .emptySignalCatalog)
        }
    }

    func testBLEUUIDsMustBeHexBluetoothIdentifiers() throws {
        XCTAssertThrowsError(try AdapterProfile(
            id: "invalid-uuid", name: "Invalid", transport: .ble,
            peripheralID: UUID(), serviceUUID: "not-a-uuid",
            writeCharacteristicUUID: "FFE1", notifyCharacteristicUUID: "FFE2",
            host: nil, port: nil, signals: [try signal()]
        )) { error in
            XCTAssertEqual(error as? AdapterProfileError, .invalidBLEUUID("not-a-uuid"))
        }
    }
}
