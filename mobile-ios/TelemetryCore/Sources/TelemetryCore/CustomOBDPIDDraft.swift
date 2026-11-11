import Foundation

/// Text-entry boundary for one user-authored read-only signal. Constructing,
/// previewing or appending a draft has no transport or measurement side effects.
public struct CustomOBDPIDDraft: Equatable, Sendable {
    public var id = ""
    public var name = ""
    public var service: OBDService = .mode01
    public var command = ""
    public var requestCANID = ""
    public var responseCANID = ""
    public var isExtended = false
    public var startBit = "0"
    public var bitLength = "8"
    public var byteOrder: ByteOrder = .intel
    public var isSigned = false
    public var factor = "1"
    public var offset = "0"
    public var minimum = ""
    public var maximum = ""
    public var unit = ""
    public var pollInterval = "1"
    public var timeout = "3"
    public var flowControl = true

    public init() {}

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidField(String)
        case profileChanged
        case requiresDiagnosticProfile
        case sampleTooLarge
    }

    public struct Preview: Equatable, Sendable {
        public let value: Double
        public let unit: String
        public let rawValue: UInt64
    }

    public func makeQuery() throws -> OBDQueryDefinition {
        let signalID = trimmed(id)
        let allowedID = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !signalID.isEmpty, signalID.count <= 128,
              signalID.unicodeScalars.allSatisfy(allowedID.contains) else {
            throw ValidationError.invalidField("Signal ID")
        }
        let signalName = try label(name, field: "Name", limit: 80, allowEmpty: false)
        let signalUnit = try label(unit, field: "Unit", limit: 24, allowEmpty: true)
        let signal = try OBDSignalDefinition(id: signalID, name: signalName,
            startBit: integer(startBit, field: "Start bit"), bitLength: integer(bitLength, field: "Bit length"),
            byteOrder: byteOrder, isSigned: isSigned, factor: number(factor, field: "Factor"),
            offset: number(offset, field: "Offset"), minimum: optionalNumber(minimum, field: "Minimum"),
            maximum: optionalNumber(maximum, field: "Maximum"), unit: signalUnit,
            timeout: number(timeout, field: "Timeout"))
        return try OBDQueryDefinition(id: "custom." + signalID, name: signalName,
            requestCANID: header(requestCANID, field: "Request ECU"),
            responseCANID: header(responseCANID, field: "Response ECU"), isExtended: isExtended,
            service: service, command: trimmed(command), pollInterval: number(pollInterval, field: "Poll interval"),
            timeout: number(timeout, field: "Timeout"), flowControl: flowControl,
            sourceRepository: "local-user", sourcePath: "custom-pid/" + signalID,
            sourceCommit: "unverified", signals: [signal])
    }

    /// Only copied/synthetic text is decoded. The result has no timestamp or
    /// quality claim and cannot be mistaken for an observed live measurement.
    public func preview(_ text: String) throws -> Preview {
        guard text.utf8.count <= 65_536 else { throw ValidationError.sampleTooLarge }
        let query = try makeQuery()
        let response = try OBDResponseParser.parse(text, for: query, receivedAtEpoch: 0,
            receivedAtMonotonicNanos: 0, sequence: 0,
            sourceAdapter: "offline-preview", sourceTransport: "none")
        let decoded = try OBDSignalDecoder.decode(query.signals[0], response: response)
        return Preview(value: decoded.value, unit: decoded.unit, rawValue: decoded.rawValue)
    }

    public func appending(to current: AdapterProfile, expected: AdapterProfile) throws -> AdapterProfile {
        guard current == expected else { throw ValidationError.profileChanged }
        // The current controller selects passive CAN versus diagnostic polling
        // from this list. Do not silently change a user's acquisition mode.
        guard !current.diagnosticQueries.isEmpty else { throw ValidationError.requiresDiagnosticProfile }
        return try AdapterProfile(id: current.id, name: current.name, transport: current.transport,
            peripheralID: current.peripheralID, serviceUUID: current.serviceUUID,
            writeCharacteristicUUID: current.writeCharacteristicUUID,
            notifyCharacteristicUUID: current.notifyCharacteristicUUID, host: current.host, port: current.port,
            signals: current.signals, diagnosticQueries: current.diagnosticQueries + [makeQuery()])
    }

    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func label(_ value: String, field: String, limit: Int, allowEmpty: Bool) throws -> String {
        let value = trimmed(value)
        guard (allowEmpty || !value.isEmpty), value.count <= limit,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ValidationError.invalidField(field)
        }
        return value
    }

    private func number(_ value: String, field: String) throws -> Double {
        guard let result = Double(trimmed(value)), result.isFinite else { throw ValidationError.invalidField(field) }
        return result
    }

    private func optionalNumber(_ value: String, field: String) throws -> Double? {
        trimmed(value).isEmpty ? nil : try number(value, field: field)
    }

    private func integer(_ value: String, field: String) throws -> Int {
        guard let result = Int(trimmed(value)) else { throw ValidationError.invalidField(field) }
        return result
    }

    private func header(_ value: String, field: String) throws -> UInt32 {
        var value = trimmed(value).uppercased()
        if value.hasPrefix("0X") { value.removeFirst(2) }
        guard !value.isEmpty, value.count <= 8,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
              let result = UInt32(value, radix: 16) else { throw ValidationError.invalidField(field) }
        return result
    }
}
