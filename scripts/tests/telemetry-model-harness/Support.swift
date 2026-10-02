import Foundation

// External boundaries only. Production coordinator methods are inserted below.
enum TelemetrySetupError: Error { case invalidEndpoint }
enum TestFailure: Error { case queueFull, storage }
enum TelemetrySource { case rawCAN, diagnostic, gps, demo }
enum TelemetryRunMode { case live, demo, replay }
struct TelemetryEvent {
    let type: String
    let capturedAt: Double
    static func gps(latitude: Double, longitude: Double, speed: Double?, heading: Double?,
                    accuracy: Double?, altitude: Double?, capturedAt: Double, background: Bool,
                    source: String, appVersion: String, device: String) throws -> Self {
        Self(type: "GPS", capturedAt: capturedAt)
    }
    static func state(_ state: String, capturedAt: Double, source: String, appVersion: String, device: String) throws -> Self {
        Self(type: "STATE", capturedAt: capturedAt)
    }
    static func mark(note: String, capturedAt: Double, background: Bool, source: String, appVersion: String, device: String) throws -> Self {
        Self(type: "MARK", capturedAt: capturedAt)
    }
}
struct LocationSample {
    let originalTimestamp: Double
    let receivedAtEpoch: Double
    let receivedAtMonotonicNanos: UInt64
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let speed: Double?
    let course: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
}
struct CANFrame {
    var receivedAtEpoch: Double = 100
    var receivedAtMonotonicNanos: UInt64 = 1_000
    var canID: UInt32 = 0x123
    var isExtended = false
    var payload: [UInt8] = [1]
    var sequence: UInt64 = 1
}
struct DecodedSignalSample {
    var signalID: String
    var value: Double
    var rawValue: UInt64 = 0
    var receivedAtEpoch: Double
}
struct OBDResponse {
    let sequence: UInt64
    let receivedAtEpoch: Double
    let responseCANID: UInt32
}
struct OBDQueryResult {
    let response: OBDResponse
    let signals: [DecodedSignalSample]
}
struct SignalDefinition { let id: String }
struct LiveDecodedSignal {
    let definition: SignalDefinition
    let decoded: DecodedSignalSample
    var sample: DecodedSignalSample { decoded }
}
enum MeasurementEvent {
    case system(name: String, timestamp: Double, monotonicNanos: UInt64)
    case location(LocationSample)
    case can(frame: CANFrame)
    case signal(DecodedSignalSample)
    case diagnosticResponse(OBDResponse)
    case diagnosticSignal(DecodedSignalSample)
}
struct ServerCANFrame {
    struct Status { let sequence: Int; let drop: Int }
    let t: Double
    let sig: [String: Double]
    init(version: Int, serverTimestamp: Double, signals: [String: Double], status: Status) throws {
        guard serverTimestamp.isFinite, signals.values.allSatisfy({ $0.isFinite }) else { throw TestFailure.storage }
        t = serverTimestamp
        sig = signals
    }
}
typealias CanFrame = ServerCANFrame
struct CanPoint { let time: Date; let signals: [String: Double] }
struct CLLocationCoordinate2D { let latitude: Double; let longitude: Double }
struct CLLocation {
    let timestamp: Date
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let horizontalAccuracy: Double = 5
    let verticalAccuracy: Double = -1
    let speed: Double = 0
    let course: Double = -1
    let altitude: Double = 0
}
@MainActor final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState: State = .active
}
@MainActor final class LocationService {
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}
@MainActor final class Adapter { func stop() {} }
@MainActor enum CredentialStore {
    static var credential: String?
    static func read() -> String? { credential }
}
actor DurableOutbox {
    var events: [TelemetryEvent] = []
    var attempts = 0
    var shouldFailCount = false
    let capacity: Int
    init(capacity: Int = 10) { self.capacity = capacity }
    init(path: URL) throws {
        if path.path.contains("upload-failure") { throw TestFailure.storage }
        capacity = 10
    }
    func enqueue(_ event: TelemetryEvent) throws {
        attempts += 1
        guard events.count < capacity else { throw TestFailure.queueFull }
        events.append(event)
    }
    func count() throws -> Int {
        if shouldFailCount { throw TestFailure.storage }
        return events.count
    }
    func failCount() { shouldFailCount = true }
}
actor TelemetryStore {
    func ingest(location: LocationSample) {}
    func ingest(frame: CANFrame) {}
    func ingest(signal: DecodedSignalSample) {}
    func ingest(diagnostic: DecodedSignalSample) {}
    func disconnect() {}
}
@MainActor final class BackgroundUploader {
    var onStatus: ((String) -> Void)?
    init(outbox: DurableOutbox, clientID: String, directory: URL) throws {}
}
@MainActor final class Coordinator {
    let clientID = "fixture"
    var uploader: BackgroundUploader?
    func restoreBackgroundSession() {}
    var serverText = ""
    var runMode: TelemetryRunMode = .live
    var storageStatus: String?
    var uploadStatus = "Not paired"
    var queueDepth = 0
    var collecting = true
    var localRecordingEnabled = true
    var locationStatus = "Collecting"
    var lastMarkAt: Date?
    var lastLocation: TelemetryEvent?
    var locationTrack: [CLLocationCoordinate2D] = []
    var outbox: DurableOutbox?
    let locationService = LocationService()
    let telemetryStore = TelemetryStore()
    let demoAdapter = Adapter()
    let liveAdapter = Adapter()
    let diagnosticAdapter = Adapter()
    let eventAppVersion = "fixture"
    let eventDevice = "test host"
    var frame: CanFrame?
    var lastFrameAt: Date?
    var canSource = "Server"
    var adapterStatus = "Disconnected"
    var adapterSignalValue: Double?
    var rawCANText = "-"
    var points: [CanPoint] = []
    var localSignalTimeouts: [String: Double] = [:]
    var localSignalReceivedAt: [String: Double] = [:]
    var conditionRuntimes: [String: Bool] = [:]
    var conditionStates: [String: Bool] = [:]
    var recorded: [MeasurementEvent] = []
    var conditionInputs: [[String: Double]] = []
    var flushes = 0
    // CACHE_FIELD
    func flush(force: Bool = false) async { flushes += 1 }
    func record(_ event: MeasurementEvent) { if localRecordingEnabled { recorded.append(event) } }
    func record(contentsOf events: [MeasurementEvent]) { if localRecordingEnabled { recorded += events } }
    func publishCarPlayProjection() {}
    func updateDashboardConditions(values: [String: Double], rawValues: [String: UInt64] = [:], now: Double) { conditionInputs.append(values) }
    // PRODUCTION_METHODS
}
