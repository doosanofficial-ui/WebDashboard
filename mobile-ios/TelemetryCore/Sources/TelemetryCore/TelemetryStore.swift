import Foundation

public enum SignalQuality: String, Codable, Equatable, Sendable {
    case valid
    case stale
    case invalid
    case disconnected
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

    public init(
        signalID: String,
        value: Double,
        rawValue: UInt64,
        enumName: String?,
        unit: String,
        frameSequence: UInt64,
        receivedAtEpoch: Double,
        receivedAtMonotonicNanos: UInt64
    ) {
        self.signalID = signalID
        self.value = value
        self.rawValue = rawValue
        self.enumName = enumName
        self.unit = unit
        self.frameSequence = frameSequence
        self.receivedAtEpoch = receivedAtEpoch
        self.receivedAtMonotonicNanos = receivedAtMonotonicNanos
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
        verticalAccuracy: Double?
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

    public init(
        signalID: String,
        value: Double?,
        rawValue: UInt64?,
        enumName: String?,
        unit: String,
        quality: SignalQuality,
        frameSequence: UInt64?,
        receivedAtEpoch: Double,
        receivedAtMonotonicNanos: UInt64
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
    }
}

public enum MeasurementEvent: Equatable, Sendable {
    case can(frame: CANFrame)
    case signal(DecodedSignalSample)
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
            receivedAtMonotonicNanos: sample.receivedAtMonotonicNanos
        )
        disconnected = false
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
            receivedAtMonotonicNanos: receivedAtMonotonicNanos
        )
    }
}
