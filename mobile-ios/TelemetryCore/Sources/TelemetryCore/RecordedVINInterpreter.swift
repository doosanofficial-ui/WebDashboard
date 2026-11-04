// PROPOSED ONLY. No requests, transport parsing, persistence or identity verification.
import Foundation

public enum RecordedVINFraming: Equatable { case iso15765CAN, legacy, unknown }
public enum RecordedVINClassification: Equatable { case payload, noData, unsupported, unknown, negative, malformed }
public enum RecordedVINStatus: String, Equatable { case positive, noData, unsupported, unknown, negative, malformed }
public struct RecordedVINResponse: Equatable {
    public let ecu: String
    public let framing: RecordedVINFraming
    public let classification: RecordedVINClassification
    // Reassembled application bytes, excluding headers, ISO-TP PCI and transport filler.
    public let payload: [UInt8]
    public init(ecu: String, framing: RecordedVINFraming, classification: RecordedVINClassification, payload: [UInt8]) {
        self.ecu = ecu; self.framing = framing; self.classification = classification; self.payload = payload
    }
}
// Deliberately not Codable: do not persist/export source response or VIN through this API.
public struct RecordedVINInterpretation: Equatable {
    public let response: RecordedVINResponse
    public let status: RecordedVINStatus
    public let vin: String?
    public let negativeCode: UInt8?
    public let issue: String?
    // Strict status-only projection excludes VIN, payload, ECU strings and free text.
    public var supportSummary: [String: String] { ["status": status.rawValue] }
}
public enum RecordedVINInterpreter {
    public static func interpret(_ response: RecordedVINResponse) -> RecordedVINInterpretation {
        func result(_ status: RecordedVINStatus, issue: String? = nil, vin: String? = nil,
                    negative: UInt8? = nil) -> RecordedVINInterpretation {
            RecordedVINInterpretation(response: response, status: status, vin: vin, negativeCode: negative, issue: issue)
        }
        guard !response.ecu.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return result(.malformed, issue: "missingSource")
        }
        let bytes = response.payload
        switch response.classification {
        case .noData: return result(.noData)
        case .unsupported: return result(.unsupported)
        case .unknown: return result(.unknown)
        case .malformed: return result(.malformed)
        case .negative:
            guard bytes.count == 3, bytes[0] == 0x7F, bytes[1] == 0x09 else {
                return result(.malformed, issue: "invalidNegative")
            }
            return result(.negative, negative: bytes[2])
        case .payload: break
        }
        guard response.framing == .iso15765CAN else { return result(.unknown, issue: "unsupportedFraming") }
        guard bytes.count == 20 else { return result(.malformed, issue: "invalidLength") }
        guard Array(bytes.prefix(3)) == [0x49, 0x02, 0x01] else { return result(.malformed, issue: "invalidHeader") }
        let allowed = Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789".utf8)
        let characters = bytes.dropFirst(3)
        guard characters.allSatisfy({ allowed.contains($0) }) else { return result(.malformed, issue: "invalidAlphabet") }
        return result(.positive, vin: String(decoding: characters, as: UTF8.self))
    }
}
