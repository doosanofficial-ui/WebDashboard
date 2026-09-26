import Foundation

public enum OBDPID: UInt8, CaseIterable, Sendable {
    case supported = 0x00, coolant = 0x05, rpm = 0x0C, speed = 0x0D

    public var command: Data {
        Data(String(format: "01%02X\r", Int(rawValue)).utf8)
    }
}

public enum OBDReply: Equatable, Sendable {
    case supported(Set<UInt8>)
    case measurement(signal: String, value: Double, unit: String)
    case noData
}

public enum ELM327Error: Error, Equatable {
    case invalidASCII, bufferOverflow, malformedResponse, unexpectedResponse
    case ambiguousResponse, adapterFailure
}

private func isELMByte(_ byte: UInt8) -> Bool {
    (32...126).contains(byte) || byte == 9 || byte == 10 || byte == 13
}

/// One instance per transport connection; a disconnect discards incomplete bytes.
public struct ELM327Framer {
    private var pending: [UInt8] = []
    public init() {}

    public mutating func feed(_ fragment: Data) throws -> [String] {
        do {
            guard fragment.count <= 4096 else { throw ELM327Error.bufferOverflow }
            guard fragment.allSatisfy(isELMByte) else { throw ELM327Error.invalidASCII }
            var responses: [String] = []
            for byte in fragment {
                if byte == 62 { // ELM prompt terminates a reply, not a BLE packet.
                    let text = String(decoding: pending, as: UTF8.self)
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        responses.append(text)
                    }
                    pending.removeAll(keepingCapacity: true)
                } else {
                    guard pending.count < 4096 else { throw ELM327Error.bufferOverflow }
                    pending.append(byte)
                }
            }
            return responses
        } catch {
            pending.removeAll()
            throw error
        }
    }
}

/// Initial scope: headerless Mode 01 replies. Never infer ECU identity or strip headers.
public enum ELM327Decoder {
    public static func decode(_ response: String, for pid: OBDPID) throws -> OBDReply {
        guard response.utf8.count <= 4096 else { throw ELM327Error.bufferOverflow }
        guard response.utf8.allSatisfy(isELMByte) else { throw ELM327Error.invalidASCII }
        let echo = String(format: "01%02X", Int(pid.rawValue))
        var lines: [String] = []
        for raw in response.uppercased().components(separatedBy: .newlines) {
            var line = raw.filter { $0 != " " && $0 != "\t" }
            if line == echo { continue }
            if line.hasPrefix("SEARCHING...") { line.removeFirst("SEARCHING...".count) }
            if !line.isEmpty { lines.append(line) }
        }
        guard !lines.isEmpty else { throw ELM327Error.malformedResponse }
        guard lines.count == 1 else { throw ELM327Error.ambiguousResponse }
        let line = lines[0]
        if line == "NODATA" { return .noData }
        if ["?", "STOPPED", "UNABLETOCONNECT", "CANERROR", "BUSERROR", "BUFFERFULL", "LVRESET"].contains(line) {
            throw ELM327Error.adapterFailure
        }
        let hex = Array(line.utf8)
        guard hex.count.isMultiple(of: 2), hex.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else {
            throw ELM327Error.malformedResponse
        }
        let bytes = stride(from: 0, to: hex.count, by: 2).map {
            UInt8(String(decoding: hex[$0...($0 + 1)], as: UTF8.self), radix: 16)!
        }
        guard bytes.count >= 2, bytes[0] == 0x41, bytes[1] == pid.rawValue else {
            throw ELM327Error.unexpectedResponse
        }
        let expected = pid == .supported ? 6 : pid == .rpm ? 4 : 3
        guard bytes.count == expected else { throw ELM327Error.malformedResponse }
        switch pid {
        case .supported:
            let mask = bytes[2...5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            var supported = Set<UInt8>()
            for candidate in 1...32 {
                let bit = UInt32(1) << (32 - candidate)
                if mask & bit != 0 { supported.insert(UInt8(candidate)) }
            }
            return .supported(supported)
        case .coolant:
            return .measurement(signal: "obd_coolant_c", value: Double(bytes[2]) - 40, unit: "degC")
        case .rpm:
            let value = Double(Int(bytes[2]) * 256 + Int(bytes[3])) / 4
            return .measurement(signal: "obd_engine_rpm", value: value, unit: "rpm")
        case .speed:
            return .measurement(signal: "obd_vehicle_speed_kmh", value: Double(bytes[2]), unit: "km/h")
        }
    }
}
