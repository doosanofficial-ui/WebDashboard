import Foundation

public enum TelemetryError: Error, Equatable {
    case invalidLocation, invalidBatch, invalidAcknowledgement, queueFull, storage, eventConflict
}

public struct EventFields: Codable, Sendable, Equatable {
    public var lat: Double?
    public var lon: Double?
    public var spd: Double?
    public var hdg: Double?
    public var acc: Double?
    public var alt: Double?
    public var note: String?
    public var state: String?
}

public struct EventMetadata: Codable, Sendable, Equatable {
    public let bgState: String
    public let os: String
    enum CodingKeys: String, CodingKey { case bgState = "bg_state", os }
}

public struct TelemetryEvent: Codable, Sendable, Equatable {
    public let id: String
    public let type: String
    public let capturedAt: Double
    public let data: EventFields
    public let meta: EventMetadata
    enum CodingKeys: String, CodingKey { case id, type, capturedAt = "captured_t", data, meta }

    private init(type: String, capturedAt: Double, data: EventFields, background: Bool) throws {
        guard capturedAt.isFinite, capturedAt > 0 else { throw TelemetryError.invalidLocation }
        self.id = UUID().uuidString.lowercased()
        self.type = type
        self.capturedAt = capturedAt
        self.data = data
        self.meta = .init(bgState: background ? "background" : "foreground", os: "iOS")
    }

    public static func gps(latitude: Double, longitude: Double, speed: Double?, heading: Double?,
                           accuracy: Double?, altitude: Double?, capturedAt: Double,
                           background: Bool) throws -> Self {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { throw TelemetryError.invalidLocation }
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        let spd = finite(speed).flatMap { $0 >= 0 ? $0 : nil }
        let hdg = finite(heading).flatMap { $0 >= 0 && $0 < 360 ? $0 : nil }
        let acc = finite(accuracy).flatMap { $0 >= 0 ? $0 : nil }
        let fields = EventFields(lat: latitude, lon: longitude, spd: spd, hdg: hdg,
                                 acc: acc, alt: finite(altitude))
        return try .init(type: "GPS", capturedAt: capturedAt, data: fields, background: background)
    }

    public static func mark(note: String, capturedAt: Double, background: Bool) throws -> Self {
        guard note.unicodeScalars.count <= 500, !note.contains("\0") else { throw TelemetryError.invalidBatch }
        return try .init(type: "MARK", capturedAt: capturedAt, data: EventFields(note: note), background: background)
    }

    public static func state(_ value: String, capturedAt: Double) throws -> Self {
        guard ["foreground", "background", "stopped"].contains(value) else { throw TelemetryError.invalidBatch }
        return try .init(type: "STATE", capturedAt: capturedAt, data: EventFields(state: value), background: value == "background")
    }
}

public struct UploadBatch: Codable, Sendable {
    public let version: Int
    public let clientID: String
    public let events: [TelemetryEvent]
    enum CodingKeys: String, CodingKey { case version = "v", clientID = "client_id", events }

    public init(clientID: String, events: [TelemetryEvent]) throws {
        guard clientID.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) != nil,
              (1...200).contains(events.count) else { throw TelemetryError.invalidBatch }
        self.version = 2
        self.clientID = clientID
        self.events = events
    }
}

public struct Acknowledgement: Codable, Sendable {
    public let version: Int
    public let clientID: String
    public let acked: [String]
    enum CodingKeys: String, CodingKey { case version = "v", clientID = "client_id", acked }
    public init(version: Int, clientID: String, acked: [String]) {
        self.version = version; self.clientID = clientID; self.acked = acked
    }
}
