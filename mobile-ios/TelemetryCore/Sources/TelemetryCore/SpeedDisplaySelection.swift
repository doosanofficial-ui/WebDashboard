import Foundation

/// Additive presentation policy. Never feeds a recording, analysis or calibration pipeline.
public enum SpeedDisplayMode: String, Codable, Sendable {
    case preserveExisting, obdOnly, gpsOnly, preferOBDWithFallback, preferGPSWithFallback
}
public enum SpeedDisplaySource: String, Codable, Sendable { case obd, gps }
public enum SpeedDisplayUnit: String, Codable, Sendable { case metersPerSecond, kilometersPerHour, milesPerHour }
public struct SpeedDisplayObservation: Equatable, Sendable {
    public let source: SpeedDisplaySource
    public let value: Double
    public let unit: SpeedDisplayUnit
    public let monotonicTime: Double
    public let scope: String
    public let generation: Int
    public let producer: String
    public let segment: Int
    public let qualityAccepted: Bool
    /// Only speed uncertainty in m/s, never horizontal position accuracy in meters.
    public let speedAccuracyMetersPerSecond: Double?
    public init(source: SpeedDisplaySource, value: Double, unit: SpeedDisplayUnit,
                monotonicTime: Double, scope: String, generation: Int, producer: String,
                segment: Int, qualityAccepted: Bool, speedAccuracyMetersPerSecond: Double?) {
        self.source = source; self.value = value; self.unit = unit
        self.monotonicTime = monotonicTime; self.scope = scope; self.generation = generation
        self.producer = producer; self.segment = segment; self.qualityAccepted = qualityAccepted
        self.speedAccuracyMetersPerSecond = speedAccuracyMetersPerSecond
    }
}
public enum SpeedDisplayStatus: String, Sendable { case preserveExisting, unavailable, available, invalidContextPolicyOrClock }
public enum SpeedDisplayRejection: String, Sendable {
    case missing, provenance, quality, valueOrUnit, timestamp, stale, regression, segmentRegression, gpsAccuracy
}
public struct SpeedDisplayDecision: Sendable {
    public let status: SpeedDisplayStatus
    public let observation: SpeedDisplayObservation?
    public let metersPerSecond: Double?
    public let usedFallback: Bool
    public let continuityBoundary: Bool
    public let rejections: [SpeedDisplaySource: SpeedDisplayRejection]
    public var displayOnly: Bool { true }
    public var label: String? {
        guard let source = observation?.source else { return nil }
        return source == .obd ? "OBD" : "GPS"
    }
}
/// Own on a single serial execution context. Create only for an explicit new scope/generation.
/// Do not reconstruct every render: this state retains monotonic and segment watermarks.
public struct SpeedDisplaySelector: Sendable {
    private let scope: String
    private let generation: Int
    private var lastNow: Double?
    private var watermarks: [SpeedDisplaySource: Double] = [:]
    private struct ProducerKey: Hashable, Sendable { let source: SpeedDisplaySource; let producer: String }
    private var segments: [ProducerKey: Int] = [:]
    private struct ContinuityKey: Equatable, Sendable {
        let mode: SpeedDisplayMode; let source: SpeedDisplaySource; let producer: String; let segment: Int
    }
    private var previous: ContinuityKey?
    private var seen = false
    public init(scope: String, generation: Int) { self.scope = scope; self.generation = generation }
    public mutating func select(mode: SpeedDisplayMode = .preserveExisting, now: Double,
                                obd: SpeedDisplayObservation? = nil, gps: SpeedDisplayObservation? = nil,
                                maximumAge: Double = 2, maximumGPSAccuracy: Double = 3) -> SpeedDisplayDecision {
        var status: SpeedDisplayStatus = .unavailable
        var selected: SpeedDisplayObservation?
        var fallback = false
        var rejections: [SpeedDisplaySource: SpeedDisplayRejection] = [:]
        let valid = !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && generation >= 0
            && maximumAge.isFinite && maximumAge >= 0 && maximumGPSAccuracy.isFinite && maximumGPSAccuracy >= 0
            && now.isFinite && now >= 0 && (lastNow.map { now >= $0 } ?? true)
        if !valid { status = .invalidContextPolicyOrClock }
        else {
            lastNow = now
            if mode == .preserveExisting { status = .preserveExisting }
            else {
                var candidates: [SpeedDisplaySource: SpeedDisplayObservation] = [:]
                for (source, sample) in [(SpeedDisplaySource.obd, obd), (SpeedDisplaySource.gps, gps)] {
                    if let reason = reject(sample, source: source, now: now, maximumAge: maximumAge, maximumGPSAccuracy: maximumGPSAccuracy) {
                        rejections[source] = reason
                    } else if let sample {
                        watermarks[source] = sample.monotonicTime
                        segments[ProducerKey(source: source, producer: sample.producer)] = sample.segment
                        candidates[source] = sample
                    }
                }
                let order: [SpeedDisplaySource]
                switch mode {
                case .preserveExisting: order = []
                case .obdOnly: order = [.obd]
                case .gpsOnly: order = [.gps]
                case .preferOBDWithFallback: order = [.obd, .gps]
                case .preferGPSWithFallback: order = [.gps, .obd]
                }
                for (index, source) in order.enumerated() {
                    if let sample = candidates[source] { selected = sample; fallback = index > 0; status = .available; break }
                }
            }
        }
        let key = selected.map { ContinuityKey(mode: mode, source: $0.source, producer: $0.producer, segment: $0.segment) }
        let boundary = seen && key != previous
        previous = key; seen = true
        let value = selected.map { sample -> Double in
            switch sample.unit {
            case .metersPerSecond: return sample.value
            case .kilometersPerHour: return sample.value / 3.6
            case .milesPerHour: return sample.value * 0.44704
            }
        }
        return .init(status: status, observation: selected, metersPerSecond: value,
                     usedFallback: fallback, continuityBoundary: boundary, rejections: rejections)
    }
    private func reject(_ sample: SpeedDisplayObservation?, source: SpeedDisplaySource, now: Double,
                        maximumAge: Double, maximumGPSAccuracy: Double) -> SpeedDisplayRejection? {
        guard let s = sample else { return .missing }
        guard s.source == source, s.scope == scope, s.generation == generation,
              !s.producer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.segment >= 0 else { return .provenance }
        guard s.qualityAccepted else { return .quality }
        guard s.value.isFinite, s.value >= 0 else { return .valueOrUnit }
        guard s.monotonicTime.isFinite, s.monotonicTime >= 0, s.monotonicTime <= now else { return .timestamp }
        guard now - s.monotonicTime <= maximumAge else { return .stale }
        if s.segment < (segments[ProducerKey(source: source, producer: s.producer)] ?? 0) { return .segmentRegression }
        if let watermark = watermarks[source], s.monotonicTime < watermark { return .regression }
        if source == .gps {
            guard let accuracy = s.speedAccuracyMetersPerSecond, accuracy.isFinite,
                  accuracy >= 0, accuracy <= maximumGPSAccuracy else { return .gpsAccuracy }
        }
        return nil
    }
}
