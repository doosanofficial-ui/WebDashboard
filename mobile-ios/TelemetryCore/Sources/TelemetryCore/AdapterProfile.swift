import Foundation

public enum AdapterTransportKind: String, Codable, Equatable, Sendable {
    case ble
    case wifi
}

public enum AdapterProfileError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidProfile
    case duplicateSignalID(String)
    case missingWiFiEndpoint
    case missingBLEProfile
}

public struct AdapterProfile: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let transport: AdapterTransportKind
    public let peripheralID: UUID?
    public let serviceUUID: String?
    public let writeCharacteristicUUID: String?
    public let notifyCharacteristicUUID: String?
    public let host: String?
    public let port: Int?
    public let signals: [SignalDefinition]

    public init(
        id: String,
        name: String,
        transport: AdapterTransportKind,
        peripheralID: UUID?,
        serviceUUID: String?,
        writeCharacteristicUUID: String?,
        notifyCharacteristicUUID: String?,
        host: String?,
        port: Int?,
        signals: [SignalDefinition]
    ) throws {
        guard !id.isEmpty, !name.isEmpty else { throw AdapterProfileError.invalidProfile }
        var ids = Set<String>()
        for signal in signals {
            guard ids.insert(signal.id).inserted else {
                throw AdapterProfileError.duplicateSignalID(signal.id)
            }
        }
        switch transport {
        case .wifi:
            guard let host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let port, (1...65_535).contains(port) else {
                throw AdapterProfileError.missingWiFiEndpoint
            }
        case .ble:
            guard peripheralID != nil,
                  let serviceUUID, !serviceUUID.isEmpty,
                  let writeCharacteristicUUID, !writeCharacteristicUUID.isEmpty,
                  let notifyCharacteristicUUID, !notifyCharacteristicUUID.isEmpty else {
                throw AdapterProfileError.missingBLEProfile
            }
        }
        schemaVersion = 1
        self.id = id
        self.name = name
        self.transport = transport
        self.peripheralID = peripheralID
        self.serviceUUID = serviceUUID
        self.writeCharacteristicUUID = writeCharacteristicUUID
        self.notifyCharacteristicUUID = notifyCharacteristicUUID
        self.host = host
        self.port = port
        self.signals = signals
    }

    public func signal(id: String) -> SignalDefinition? {
        signals.first { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id, name, transport, peripheralID, serviceUUID,
             writeCharacteristicUUID, notifyCharacteristicUUID, host, port, signals
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw AdapterProfileError.unsupportedSchemaVersion(version) }
        try self.init(
            id: values.decode(String.self, forKey: .id),
            name: values.decode(String.self, forKey: .name),
            transport: values.decode(AdapterTransportKind.self, forKey: .transport),
            peripheralID: values.decodeIfPresent(UUID.self, forKey: .peripheralID),
            serviceUUID: values.decodeIfPresent(String.self, forKey: .serviceUUID),
            writeCharacteristicUUID: values.decodeIfPresent(String.self, forKey: .writeCharacteristicUUID),
            notifyCharacteristicUUID: values.decodeIfPresent(String.self, forKey: .notifyCharacteristicUUID),
            host: values.decodeIfPresent(String.self, forKey: .host),
            port: values.decodeIfPresent(Int.self, forKey: .port),
            signals: values.decode([SignalDefinition].self, forKey: .signals)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(transport, forKey: .transport)
        try values.encodeIfPresent(peripheralID, forKey: .peripheralID)
        try values.encodeIfPresent(serviceUUID, forKey: .serviceUUID)
        try values.encodeIfPresent(writeCharacteristicUUID, forKey: .writeCharacteristicUUID)
        try values.encodeIfPresent(notifyCharacteristicUUID, forKey: .notifyCharacteristicUUID)
        try values.encodeIfPresent(host, forKey: .host)
        try values.encodeIfPresent(port, forKey: .port)
        try values.encode(signals, forKey: .signals)
    }
}
