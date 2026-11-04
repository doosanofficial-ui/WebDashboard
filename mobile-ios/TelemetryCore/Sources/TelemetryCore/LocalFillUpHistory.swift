import Foundation

/// Local, user-entered evidence. No persistence, import, network, or settings side effects.
public struct LocalFillUpRecord: Codable, Equatable, Sendable {
    public enum VolumeUnit: String, Codable, Sendable {
        case liters, usGallons, imperialGallons
        public var litersPerUnit: Double {
            switch self {
            case .liters: return 1
            case .usGallons: return 3.785411784
            case .imperialGallons: return 4.54609
            }
        }
    }
    public enum DistanceUnit: String, Codable, Sendable {
        case km, miles
        public var kilometersPerUnit: Double { self == .km ? 1 : 1.609344 }
    }
    public enum TankState: String, Codable, Sendable { case full, partial, unknown }
    /// Applies to the history AFTER the preceding record THROUGH this fill.
    /// complete must be explicitly confirmed, never inferred from record spacing.
    public enum Completeness: String, Codable, Sendable { case complete, missing, uncertain }
    public enum ValidationError: Error { case invalidIdentity, invalidNumber }

    public let id: String
    public let vehicle: String
    /// Change this identity on odometer replacement/reset/rollover; never repair silently.
    public let epoch: String
    /// Actual fill chronology, Unix seconds. Import time is not a substitute.
    public let time: Double
    public let odometer: Double
    public let distanceUnit: DistanceUnit
    public let volume: Double?
    public let volumeUnit: VolumeUnit
    public let tank: TankState
    public let completeness: Completeness

    public init(id: String, vehicle: String, epoch: String, time: Double,
                odometer: Double, distanceUnit: DistanceUnit, volume: Double?,
                volumeUnit: VolumeUnit, tank: TankState, completeness: Completeness) throws {
        guard [id, vehicle, epoch].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ValidationError.invalidIdentity
        }
        guard time.isFinite, odometer.isFinite, odometer >= 0,
              volume.map({ $0.isFinite && $0 > 0 }) ?? true else { throw ValidationError.invalidNumber }
        self.id = id; self.vehicle = vehicle; self.epoch = epoch; self.time = time
        self.odometer = odometer; self.distanceUnit = distanceUnit
        self.volume = volume; self.volumeUnit = volumeUnit; self.tank = tank; self.completeness = completeness
    }
    private enum CodingKeys: String, CodingKey {
        case id, vehicle, epoch, time, odometer, distanceUnit, volume, volumeUnit, tank, completeness
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Optional volume is represented by an explicit null, not an omitted field.
        guard c.contains(.volume) else {
            throw DecodingError.keyNotFound(CodingKeys.volume, .init(codingPath: decoder.codingPath, debugDescription: "Explicit volume or null required"))
        }
        try self.init(id: c.decode(String.self, forKey: .id), vehicle: c.decode(String.self, forKey: .vehicle),
                      epoch: c.decode(String.self, forKey: .epoch), time: c.decode(Double.self, forKey: .time),
                      odometer: c.decode(Double.self, forKey: .odometer), distanceUnit: c.decode(DistanceUnit.self, forKey: .distanceUnit),
                      volume: c.decodeIfPresent(Double.self, forKey: .volume), volumeUnit: c.decode(VolumeUnit.self, forKey: .volumeUnit),
                      tank: c.decode(TankState.self, forKey: .tank), completeness: c.decode(Completeness.self, forKey: .completeness))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(vehicle, forKey: .vehicle); try c.encode(epoch, forKey: .epoch)
        try c.encode(time, forKey: .time); try c.encode(odometer, forKey: .odometer)
        try c.encode(distanceUnit, forKey: .distanceUnit); try c.encode(volume, forKey: .volume)
        try c.encode(volumeUnit, forKey: .volumeUnit); try c.encode(tank, forKey: .tank)
        try c.encode(completeness, forKey: .completeness)
    }
}

public enum LocalFillUpHistory {
    public enum HistoryError: Error { case duplicateIdentity, nonIncreasingChronology, mixedVehicle }
    public enum Exclusion: String, Equatable, Sendable {
        case incompleteHistory, unknownTankState, missingVolume, odometerDiscontinuity
        case nonPositiveDistance, numericRange
    }
    public struct Interval: Equatable, Sendable {
        public let startID: String
        public let endID: String
        /// Starting full fill is excluded; intervening partials and ending full fill are included.
        public let includedVolumeRecordIDs: [String]
        public let exclusions: [Exclusion]
        public let kilometers: Double?
        public let liters: Double?
        public let litersPer100Kilometers: Double?
        /// Full-tank repeatability and user entry error are unquantified, even with complete records.
        public let uncertainty = "User-entered full-to-full estimate; tank repeatability and entry error are unquantified."
    }
    public struct Summary: Equatable, Sendable {
        public let intervals: [Interval]
        /// No pair of full anchors covers these records. Do not count them as consumed fuel.
        public let unanchoredRecordIDs: [String]
    }
    public static func summarize(_ records: [LocalFillUpRecord]) throws -> Summary {
        var ids = Set<String>()
        for (i, r) in records.enumerated() {
            guard ids.insert(r.id).inserted else { throw HistoryError.duplicateIdentity }
            if i > 0 {
                guard r.time > records[i - 1].time else { throw HistoryError.nonIncreasingChronology }
                guard r.vehicle == records[0].vehicle else { throw HistoryError.mixedVehicle }
            }
        }
        let anchors = records.indices.filter { records[$0].tank == .full }
        var intervals: [Interval] = []
        var used = Set<Int>()
        for (start, end) in zip(anchors, anchors.dropFirst()) {
            let a = records[start], b = records[end]
            let segment = records[(start + 1)...end]
            var reasons: [Exclusion] = []
            if segment.contains(where: { $0.completeness != .complete }) { reasons.append(.incompleteHistory) }
            if segment.contains(where: { $0.tank == .unknown }) { reasons.append(.unknownTankState) }
            if segment.contains(where: { $0.volume == nil }) { reasons.append(.missingVolume) }
            if segment.contains(where: { $0.epoch != a.epoch }) || ((start + 1)...end).contains(where: {
                records[$0].odometer * records[$0].distanceUnit.kilometersPerUnit <
                records[$0 - 1].odometer * records[$0 - 1].distanceUnit.kilometersPerUnit
            }) { reasons.append(.odometerDiscontinuity) }
            let km = b.odometer * b.distanceUnit.kilometersPerUnit - a.odometer * a.distanceUnit.kilometersPerUnit
            let liters = segment.reduce(0.0) { $0 + ($1.volume ?? 0) * $1.volumeUnit.litersPerUnit }
            let l100 = km > 0 ? liters / km * 100 : 0
            if km <= 0 { reasons.append(.nonPositiveDistance) }
            if ![km, liters, l100].allSatisfy({ $0.isFinite }) || (km > 0 && liters > 0 && l100 <= 0) { reasons.append(.numericRange) }
            intervals.append(Interval(startID: a.id, endID: b.id, includedVolumeRecordIDs: segment.map(\.id),
                                      exclusions: reasons, kilometers: reasons.isEmpty ? km : nil,
                                      liters: reasons.isEmpty ? liters : nil,
                                      litersPer100Kilometers: reasons.isEmpty ? l100 : nil))
            used.formUnion(start...end)
        }
        return Summary(intervals: intervals, unanchoredRecordIDs: records.indices.filter { !used.contains($0) }.map { records[$0].id })
    }
}

/// Explicit gate, not an implemented calibration calculator. A scalar/session total cannot prove a match.
public enum LocalFillUpCalibrationGate {
    public enum MissingProof: String, CaseIterable, Sendable {
        case sameVehicleAndFuelTankScope
        case exactPostFillStartAndEndAnchorIdentityAndTime
        case completeAdmittedMeasuredFuelCoverageBetweenAnchors
        case compatibleMeasuredFuelVolumeSemanticsAndUnits
        case originalEvidenceProvenanceAndNoDuplicateOrOverlappingCoverage
    }
    public static var requiredAdapterProof: [MissingProof] { MissingProof.allCases }
    public static var proposalAvailable: Bool { false }
    // Deliberately no factor, settings mutation, or vehicle diagnosis API.
}
