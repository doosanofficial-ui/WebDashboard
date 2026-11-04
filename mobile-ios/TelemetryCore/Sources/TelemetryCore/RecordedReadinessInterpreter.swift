// PROPOSED ONLY. Native compilation deferred. Recorded evidence only; no commands.
import Foundation

public enum RecordedReadinessSchema: Equatable { case unknown, j1979DA2011 }
public enum RecordedReadinessFamily: Equatable { case sparkMonitors, compressionMonitors }
public enum RecordedReadinessCompletion: Equatable { case notApplicable, complete, incomplete, unknown }
public enum RecordedReadinessGroup: Equatable { case continuousOrOncePerTrip, nonContinuous }
public enum RecordedReadinessStatus: Equatable {
    case decoded, partial, unknownSchema, notApplicable, noData, unsupported, unknown, negative, malformed
}
public struct RecordedReadinessMonitor: Equatable {
    public let id: String
    public let group: RecordedReadinessGroup
    public let supported: Bool
    public let completion: RecordedReadinessCompletion
}
public struct RecordedReadinessInterpretation: Equatable {
    // Bounded original evidence. No ECU aggregation or claim of vehicle engine identity.
    public let ecu: String
    public let payload: [UInt8]
    public let evidenceTruncated: Bool
    public let raw: [UInt8]?
    public let schema: RecordedReadinessSchema
    public let status: RecordedReadinessStatus
    public let family: RecordedReadinessFamily?
    public let monitors: [RecordedReadinessMonitor]?
    public let issues: [String]
    public var supportedCount: Int? { monitors.map { $0.filter(\.supported).count } }
    public var completedCount: Int? { monitors.map { $0.filter { $0.supported && $0.completion == .complete }.count } }
    public var incompleteCount: Int? { monitors.map { $0.filter { $0.supported && $0.completion == .incomplete }.count } }
}
public enum RecordedReadinessInterpreter {
    // Selecting the edition is a caller evidence gate, never infer it from model/year/fuel.
    // Unknown is deliberately the default. This is not an emissions inspection decision.
    public static func interpret(_ input: RecordedDiagnosticInterpretation,
                                 schema: RecordedReadinessSchema = .unknown) -> RecordedReadinessInterpretation {
        let response = input.response
        let oversized = response.payload.count > 1024 || response.ecu.count > 256
        func result(_ status: RecordedReadinessStatus, family: RecordedReadinessFamily? = nil,
                    monitors: [RecordedReadinessMonitor]? = nil, issues: [String] = []) -> RecordedReadinessInterpretation {
            RecordedReadinessInterpretation(ecu: String(response.ecu.prefix(256)),
                payload: Array(response.payload.prefix(1024)), evidenceTruncated: oversized,
                raw: input.readinessRaw.map { Array($0.prefix(3)) }, schema: schema,
                status: status, family: family, monitors: monitors, issues: issues)
        }
        guard !oversized, !response.ecu.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return result(.malformed)
        }
        guard response.service == .monitorStatus else { return result(.notApplicable) }
        switch input.status {
        case .noData: return result(.noData)
        case .unsupported: return result(.unsupported)
        case .unknown: return result(.unknown)
        case .negative: return result(.negative)
        case .malformed: return result(.malformed)
        case .positive: break
        }
        let p = response.payload
        guard response.classification == .payload, p.count == 6, p[0] == 0x41, p[1] == 1,
              let raw = input.readinessRaw, raw.count == 3, raw == Array(p[3...5]) else {
            return result(.malformed)
        }
        guard schema == .j1979DA2011 else { return result(.unknownSchema) }
        let b = raw[0], c = raw[1], d = raw[2]
        let compression = b & 8 != 0
        let names: [String?] = compression
            ? ["nmhcCatalyst", "noxSCR", nil, "boostPressure", nil, "exhaustGasSensor", "particulateFilter", "egrVVT"]
            : ["catalyst", "heatedCatalyst", "evaporative", "secondaryAir", nil, "oxygenSensor", "oxygenHeater", "egrVVT"]
        var issues: [String] = []
        if b & 128 != 0 || (c | d) & (compression ? 20 : 16) != 0 { issues.append("reservedBitsSet") }
        var monitors: [RecordedReadinessMonitor] = []
        func add(_ name: String, _ group: RecordedReadinessGroup, _ supported: Bool, _ incomplete: Bool) {
            let completion: RecordedReadinessCompletion
            if supported { completion = incomplete ? .incomplete : .complete }
            else {
                completion = incomplete ? .unknown : .notApplicable
                if incomplete { issues.append("unsupportedStatusSet:" + name) }
            }
            monitors.append(RecordedReadinessMonitor(id: name, group: group, supported: supported, completion: completion))
        }
        for (index, name) in ["misfire", "fuelSystem", "components"].enumerated() {
            add(name, .continuousOrOncePerTrip, b & (UInt8(1) << index) != 0,
                b & (UInt8(1) << (index + 4)) != 0)
        }
        for (index, name) in names.enumerated() {
            guard let name else { continue }
            add(name, .nonContinuous, c & (UInt8(1) << index) != 0, d & (UInt8(1) << index) != 0)
        }
        return result(issues.isEmpty ? .decoded : .partial,
                      family: compression ? .compressionMonitors : .sparkMonitors,
                      monitors: monitors, issues: issues)
    }
}
