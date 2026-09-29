import Foundation

public enum SignalQuality: String, Codable, Equatable, Sendable {
    case valid
    case stale
    case invalid
    case disconnected
}

public enum TelemetrySource: String, Codable, Equatable, Sendable {
    case rawCAN = "rawCAN"
    case diagnostic = "diagnostic"
    case gps = "GPS"
    case demo = "demo"
    case replay = "replay"
}

public enum TelemetryRunMode: String, Codable, Equatable, Sendable {
    case live = "LIVE"
    case demo = "DEMO"
    case replay = "REPLAY"
}

public struct DecodedSignalSample: Codable, Equatable, Sendable {
    public let signalID: String
    public let value: Double
    public let rawValue: UInt64
    public let enumName: String?
    public let unit: String
    public let frameSequence: UInt64
    public let receivedAtEpoch: Double
    public let receivedAtMonotonicNanos: UInt64
    public let source: TelemetrySource

    public init(
        signalID: String,
        value: Double,
        rawValue: UInt64,
        enumName: String?,
        unit: String,
        frameSequence: UInt64,
        receivedAtEpoch: Double,
        receivedAtMonotonicNanos: UInt64,
        source: TelemetrySource = .rawCAN
    ) {
        self.signalID = signalID
        self.value = value
        self.rawValue = rawValue
        self.enumName = enumName
        self.unit = unit
        self.frameSequence = frameSequence
        self.receivedAtEpoch = receivedAtEpoch
        self.receivedAtMonotonicNanos = receivedAtMonotonicNanos
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case signalID, value, rawValue, enumName, unit, frameSequence
        case receivedAtEpoch, receivedAtMonotonicNanos, source
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            signalID: try values.decode(String.self, forKey: .signalID),
            value: try values.decode(Double.self, forKey: .value),
            rawValue: try values.decode(UInt64.self, forKey: .rawValue),
            enumName: try values.decodeIfPresent(String.self, forKey: .enumName),
            unit: try values.decode(String.self, forKey: .unit),
            frameSequence: try values.decode(UInt64.self, forKey: .frameSequence),
            receivedAtEpoch: try values.decode(Double.self, forKey: .receivedAtEpoch),
            receivedAtMonotonicNanos: try values.decode(UInt64.self, forKey: .receivedAtMonotonicNanos),
            source: try values.decodeIfPresent(TelemetrySource.self, forKey: .source) ?? .rawCAN
        )
    }
}

public struct LocationSample: Codable, Equatable, Sendable {
    public let originalTimestamp: Double
    public let receivedAtEpoch: Double
    public let receivedAtMonotonicNanos: UInt64
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let speed: Double?
    public let course: Double?
    public let horizontalAccuracy: Double?
    public let verticalAccuracy: Double?
    public let source: TelemetrySource

    public init(
        originalTimestamp: Double,
        receivedAtEpoch: Double,
        receivedAtMonotonicNanos: UInt64,
        latitude: Double,
        longitude: Double,
        altitude: Double?,
        speed: Double?,
        course: Double?,
        horizontalAccuracy: Double?,
        verticalAccuracy: Double?,
        source: TelemetrySource = .gps
    ) {
        self.originalTimestamp = originalTimestamp
        self.receivedAtEpoch = receivedAtEpoch
        self.receivedAtMonotonicNanos = receivedAtMonotonicNanos
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case originalTimestamp, receivedAtEpoch, receivedAtMonotonicNanos
        case latitude, longitude, altitude, speed, course
        case horizontalAccuracy, verticalAccuracy, source
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            originalTimestamp: try values.decode(Double.self, forKey: .originalTimestamp),
            receivedAtEpoch: try values.decode(Double.self, forKey: .receivedAtEpoch),
            receivedAtMonotonicNanos: try values.decode(UInt64.self, forKey: .receivedAtMonotonicNanos),
            latitude: try values.decode(Double.self, forKey: .latitude),
            longitude: try values.decode(Double.self, forKey: .longitude),
            altitude: try values.decodeIfPresent(Double.self, forKey: .altitude),
            speed: try values.decodeIfPresent(Double.self, forKey: .speed),
            course: try values.decodeIfPresent(Double.self, forKey: .course),
            horizontalAccuracy: try values.decodeIfPresent(Double.self, forKey: .horizontalAccuracy),
            verticalAccuracy: try values.decodeIfPresent(Double.self, forKey: .verticalAccuracy),
            source: try values.decodeIfPresent(TelemetrySource.self, forKey: .source) ?? .gps
        )
    }
}

public struct LatestSignalState: Equatable, Sendable {
    public let signalID: String
    public let value: Double?
    public let rawValue: UInt64?
    public let enumName: String?
    public let unit: String
    public let quality: SignalQuality
    public let frameSequence: UInt64?
    public let receivedAtEpoch: Double
    public let receivedAtMonotonicNanos: UInt64
    public let source: TelemetrySource

    public init(
        signalID: String,
        value: Double?,
        rawValue: UInt64?,
        enumName: String?,
        unit: String,
        quality: SignalQuality,
        frameSequence: UInt64?,
        receivedAtEpoch: Double,
        receivedAtMonotonicNanos: UInt64,
        source: TelemetrySource = .rawCAN
    ) {
        self.signalID = signalID
        self.value = value
        self.rawValue = rawValue
        self.enumName = enumName
        self.unit = unit
        self.quality = quality
        self.frameSequence = frameSequence
        self.receivedAtEpoch = receivedAtEpoch
        self.receivedAtMonotonicNanos = receivedAtMonotonicNanos
        self.source = source
    }
}

public enum MeasurementEvent: Equatable, Sendable {
    case can(frame: CANFrame)
    case signal(DecodedSignalSample)
    case diagnosticResponse(OBDResponse)
    case diagnosticSignal(DecodedOBDSignal)
    case location(LocationSample)
    case system(name: String, timestamp: Double, monotonicNanos: UInt64)
}

public actor TelemetryStore {
    private var signalTimeouts: [String: Double]
    private var signals: [String: LatestSignalState] = [:]
    private var lastFrame: CANFrame?
    private var lastLocation: LocationSample?
    private var disconnected = false

    public init(signalTimeouts: [String: Double] = [:]) {
        self.signalTimeouts = signalTimeouts
    }

    public func configureSignalTimeouts(_ timeouts: [String: Double]) {
        signalTimeouts = timeouts.filter { $0.value.isFinite && $0.value > 0 }
    }

    public func ingest(frame: CANFrame) {
        lastFrame = frame
        disconnected = false
    }

    public func ingest(signal sample: DecodedSignalSample) {
        let quality: SignalQuality = sample.value.isFinite ? .valid : .invalid
        signals[sample.signalID] = LatestSignalState(
            signalID: sample.signalID,
            value: sample.value.isFinite ? sample.value : nil,
            rawValue: sample.rawValue,
            enumName: sample.enumName,
            unit: sample.unit,
            quality: quality,
            frameSequence: sample.frameSequence,
            receivedAtEpoch: sample.receivedAtEpoch,
            receivedAtMonotonicNanos: sample.receivedAtMonotonicNanos,
            source: sample.source
        )
        disconnected = false
    }

    public func ingest(diagnostic signal: DecodedOBDSignal) {
        ingest(signal: DecodedSignalSample(
            signalID: signal.signalID,
            value: signal.value,
            rawValue: signal.rawValue,
            enumName: signal.enumName,
            unit: signal.unit,
            frameSequence: signal.sequence,
            receivedAtEpoch: signal.receivedAtEpoch,
            receivedAtMonotonicNanos: signal.receivedAtMonotonicNanos,
            source: .diagnostic
        ))
    }

    public func ingest(location: LocationSample) {
        lastLocation = location
    }

    public func signalState(for signalID: String, now: Double) -> LatestSignalState? {
        guard let state = signals[signalID] else { return nil }
        if disconnected {
            return state.withQuality(.disconnected)
        }
        guard state.quality == .valid, let timeout = signalTimeouts[signalID], now.isFinite else {
            return state
        }
        if now >= state.receivedAtEpoch && now - state.receivedAtEpoch > timeout {
            return state.withQuality(.stale)
        }
        return state
    }

    public func latestFrame() -> CANFrame? { lastFrame }

    public func latestLocation() -> LocationSample? { lastLocation }

    public func disconnect() {
        disconnected = true
    }
}

private extension LatestSignalState {
    func withQuality(_ quality: SignalQuality) -> LatestSignalState {
        LatestSignalState(
            signalID: signalID,
            value: value,
            rawValue: rawValue,
            enumName: enumName,
            unit: unit,
            quality: quality,
            frameSequence: frameSequence,
            receivedAtEpoch: receivedAtEpoch,
            receivedAtMonotonicNanos: receivedAtMonotonicNanos,
            source: source
        )
    }
}
