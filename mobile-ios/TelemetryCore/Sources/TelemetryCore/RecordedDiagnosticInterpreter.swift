// PROPOSED ONLY: not compiled or integrated. No transport or command-generation API.
import Foundation

public enum RecordedDiagnosticService: UInt8, Equatable {
    case monitorStatus = 0x01, stored = 0x03, pending = 0x07, permanent = 0x0A
}
public enum RecordedDiagnosticFraming: Equatable { case legacy, iso15765CAN }
public enum RecordedDiagnosticClassification: Equatable {
    case payload, noData, unsupported, unknown, negative, malformed
}
public enum RecordedDiagnosticStatus: Equatable {
    case positive, noData, unsupported, unknown, negative, malformed
}
public struct RecordedDiagnosticResponse: Equatable {
    public let ecu: String
    public let service: RecordedDiagnosticService
    public let framing: RecordedDiagnosticFraming
    public let classification: RecordedDiagnosticClassification
    // Reassembled application payload only; no headers, PCI, checksum or transport filler.
    public let payload: [UInt8]
    public init(ecu: String, service: RecordedDiagnosticService, framing: RecordedDiagnosticFraming,
                classification: RecordedDiagnosticClassification, payload: [UInt8]) {
        self.ecu = ecu; self.service = service; self.framing = framing
        self.classification = classification; self.payload = payload
    }
}
public struct RecordedDiagnosticInterpretation: Equatable {
    public let response: RecordedDiagnosticResponse
    public let status: RecordedDiagnosticStatus
    // nil means no positive DTC evidence; [] means positively reported zero DTCs.
    public let codes: [String]?
    public let mil: Bool?
    public let storedCount: Int?
    // Opaque bytes only. No readiness interpretation is claimed.
    public let readinessRaw: [UInt8]?
    public let negativeCode: UInt8?
    public let issue: String?
}
public enum RecordedDiagnosticInterpreter {
    public static func interpret(_ response: RecordedDiagnosticResponse) -> RecordedDiagnosticInterpretation {
        func result(_ status: RecordedDiagnosticStatus, codes: [String]? = nil, mil: Bool? = nil,
                    count: Int? = nil, readiness: [UInt8]? = nil, negative: UInt8? = nil,
                    issue: String? = nil) -> RecordedDiagnosticInterpretation {
            RecordedDiagnosticInterpretation(response: response, status: status, codes: codes,
                mil: mil, storedCount: count, readinessRaw: readiness, negativeCode: negative, issue: issue)
        }
        func invalid(_ issue: String) -> RecordedDiagnosticInterpretation { result(.malformed, issue: issue) }
        guard !response.ecu.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return invalid("missingSource")
        }
        let bytes = response.payload
        switch response.classification {
        case .noData: return result(.noData)
        case .unsupported: return result(.unsupported)
        case .unknown: return result(.unknown)
        case .malformed: return result(.malformed)
        case .negative:
            guard bytes.count == 3, bytes[0] == 0x7F, bytes[1] == response.service.rawValue else {
                return invalid("invalidNegative")
            }
            return result(.negative, negative: bytes[2])
        case .payload: break
        }
        guard bytes.first == response.service.rawValue + 0x40 else { return invalid("unexpectedService") }
        // Unsupported interpretation layout, not a conclusion about ECU support.
        // Classified non-positive evidence is returned unchanged above.
        if response.service == .permanent && response.framing == .legacy {
            return invalid("unsupportedFraming")
        }
        if response.service == .monitorStatus {
            guard bytes.count == 6, bytes[1] == 0x01 else { return invalid("invalidMonitorPayload") }
            return result(.positive, mil: bytes[2] & 0x80 != 0, count: Int(bytes[2] & 0x7F),
                          readiness: Array(bytes[3...5]))
        }
        let isCAN = response.framing == .iso15765CAN
        let offset = isCAN ? 2 : 1
        guard bytes.count >= offset, (bytes.count - offset) % 2 == 0 else { return invalid("invalidPairLength") }
        if !isCAN && bytes.count == 1 { return invalid("missingLegacyEvidence") }
        let pairs: [UInt16] = stride(from: offset, to: bytes.count, by: 2).map {
            (UInt16(bytes[$0]) << 8) | UInt16(bytes[$0 + 1])
        }
        let values: [UInt16]
        if isCAN {
            let count = Int(bytes[1])
            guard pairs.count >= count else { return invalid("truncatedCount") }
            guard !pairs.prefix(count).contains(0) else { return invalid("zeroWithinCount") }
            guard pairs.dropFirst(count).allSatisfy({ $0 == 0 }) else { return invalid("extraNonpadding") }
            values = Array(pairs.prefix(count))
        } else {
            let zero = pairs.firstIndex(of: 0) ?? pairs.count
            guard pairs.dropFirst(zero).allSatisfy({ $0 == 0 }) else { return invalid("nonpaddingAfterZero") }
            values = Array(pairs.prefix(zero))
        }
        let families = ["P", "C", "B", "U"]
        let codes = values.map { value -> String in
            let family = families[Int(value >> 14)]
            let digit = String((value >> 12) & 3)
            let suffix = String(format: "%03X", Int(value & 0x0FFF))
            return family + digit + suffix
        }
        return result(.positive, codes: codes)
    }
}
