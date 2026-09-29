import Foundation
import CoreLocation
import Observation
import UIKit
import TelemetryCore

typealias CanFrame = ServerCANFrame
struct CanPoint: Identifiable {
    let id = UUID()
    let time: Date
    let signals: [String: Double]
}

@MainActor @Observable
final class TelemetryModel: NSObject {
    static let shared = TelemetryModel()
    var serverText = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    var connection = "Disconnected"
    var serverRecording: ServerRecordingStatus?
    var locationStatus = "Not collecting"
    var uploadStatus = "Not paired"
    var storageStatus: String?
    var localRecordingStatus = "Preparing local recorder"
    var exportStatus = "No export generated"
    var localRecordingEnabled = false
    var runMode: TelemetryRunMode = .live
    var availableSignalIDs: [String] {
        var ids: [String] = []
        if let profile = adapterProfile {
            ids.append(contentsOf: profile.signals.map(\.id))
            ids.append(contentsOf: profile.diagnosticQueries.flatMap { query in
                query.signals.map(\.id)
            })
        }
        if let frame { ids.append(contentsOf: frame.sig.keys) }
        return Array(Set(ids)).sorted()
    }
    var dashboardProfile: DashboardProfile?
    var adapterProfile: AdapterProfile?
    var adapterStatus = "Adapter disconnected"
    var adapterProfileStatus = "No live adapter profile"
    var bleDiscoveryStatus = "BLE discovery not started"
    var bleDevices: [BLEDiscoveredDevice] = []
    var adapterSignalValue: Double?
    var rawCANText = "-"
    var frame: CanFrame?
    var lastFrameAt: Date?
    var canSource = "Server"
    var localSignalTimeouts: [String: Double] = [:]
    var localSignalReceivedAt: [String: Double] = [:]
    var conditionStates: [String: Bool] = [:]
    var lastLocation: TelemetryEvent?
    var locationTrack: [CLLocationCoordinate2D] = []
    var points: [CanPoint] = []
    var queueDepth = 0
    var collecting = false
    var credentialSaved = CredentialStore.read() != nil
    var clientDrops = 0
    var invalidFrameCount = 0
    var reconnectAttempt = 0
    var serverRTTMilliseconds: Double?
    var serverPingFailures = 0
    var lastMarkAt: Date?
    var recordingElapsedSeconds: Int? {
        guard localRecordingEnabled, let recordingStartedAt else { return nil }
        return Int(max(0, Date().timeIntervalSince(recordingStartedAt)))
    }
    // Core Location delivers delegate events on this manager's main run loop.
    @ObservationIgnored private let locationService: LocationService
    @ObservationIgnored private let demoAdapter: DemoAdapterController
    @ObservationIgnored private let liveAdapter: LiveAdapterController
    @ObservationIgnored private let diagnosticAdapter: DiagnosticAdapterController
    @ObservationIgnored private let bleDiscovery: BLEDiscoveryController
    @ObservationIgnored private let telemetryStore: TelemetryStore
    @ObservationIgnored private var conditionRuntimes: [String: DashboardConditionRuntime] = [:]
    @ObservationIgnored private var outbox: DurableOutbox?
    @ObservationIgnored private var localRecorder: MeasurementRecorder?
    @ObservationIgnored private var completedRecorder: MeasurementRecorder?
    @ObservationIgnored private var recordingWriteQueue: MeasurementWriteQueue?
    @ObservationIgnored private var recordingClosing = false
    @ObservationIgnored private var recordingLifecycle = RecordingLifecycle()
    @ObservationIgnored private var recordingStartedAt: Date?
    @ObservationIgnored private var measurementDBURL: URL?
    @ObservationIgnored private var dashboardURL: URL?
    @ObservationIgnored private var adapterProfileURL: URL?
    @ObservationIgnored var uploader: BackgroundUploader?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var socketLoop: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var frameSequenceTracker = FrameSequenceTracker()
    @ObservationIgnored private var serverBackoff = ReconnectBackoff()
    @ObservationIgnored private var connectionStableSince: Date?
    @ObservationIgnored private var pingMetrics = PingMetrics()
    @ObservationIgnored private var pingLoop: Task<Void, Never>?
    @ObservationIgnored private let clientID: String

    private var eventAppVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }

    private var eventDevice: String { UIDevice.current.model }

    private override init() {
        let existing = UserDefaults.standard.string(forKey: "clientID")
        clientID = existing ?? UUID().uuidString.lowercased()
        locationService = LocationService()
        demoAdapter = DemoAdapterController()
        liveAdapter = LiveAdapterController()
        diagnosticAdapter = DiagnosticAdapterController()
        bleDiscovery = BLEDiscoveryController()
        telemetryStore = TelemetryStore()
        super.init()
        UserDefaults.standard.set(clientID, forKey: "clientID")
        locationService.onStatus = { [weak self] status in
            guard let self else { return }
            self.locationStatus = status
            let normalized = status.lowercased()
            let eventName: String?
            if normalized.contains("permission denied") {
                eventName = "gps_permission_denied"
            } else if normalized.contains("unavailable") {
                eventName = "gps_unavailable"
            } else {
                eventName = nil
            }
            if let eventName {
                self.record(.system(
                    name: eventName,
                    timestamp: Date().timeIntervalSince1970,
                    monotonicNanos: DispatchTime.now().uptimeNanoseconds
                ))
            }
        }
        locationService.onCollectingChanged = { [weak self] collecting in
            self?.collecting = collecting
        }
        locationService.onLocations = { [weak self] locations in
            self?.handleLocations(locations)
        }
        demoAdapter.onState = { [weak self] state in
            self?.handleAdapterState(state)
        }
        demoAdapter.onFrame = { [weak self] frame, decoded in
            self?.handleDemoFrame(frame, decoded: decoded)
        }
        liveAdapter.onState = { [weak self] state in
            self?.handleAdapterState(state)
        }
        liveAdapter.onFrame = { [weak self] frame, decoded in
            self?.handleLiveFrame(frame, decoded: decoded)
        }
        diagnosticAdapter.onState = { [weak self] state in
            self?.handleAdapterState(state)
        }
        diagnosticAdapter.onResult = { [weak self] result in
            self?.handleDiagnosticResult(result)
        }
        bleDiscovery.onUpdate = { [weak self] devices, status in
            self?.bleDevices = devices
            self?.bleDiscoveryStatus = status
        }
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Telemetry")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            dashboardURL = root.appendingPathComponent("dashboard.json")
            if let dashboardURL, let dashboardData = try? Data(contentsOf: dashboardURL),
               var saved = try? JSONDecoder().decode(DashboardProfile.self, from: dashboardData) {
                if saved.migrateLegacyDefaultGrid() {
                    dashboardProfile = saved
                    persistDashboardProfile()
                } else {
                    dashboardProfile = saved
                }
            } else {
                dashboardProfile = Self.defaultDashboardProfile()
                persistDashboardProfile()
            }
            adapterProfileURL = root.appendingPathComponent("adapter-profile.json")
            if let adapterProfileURL,
               let profileData = try? Data(contentsOf: adapterProfileURL),
               let savedProfile = try? JSONDecoder().decode(AdapterProfile.self, from: profileData) {
                adapterProfile = savedProfile
                adapterProfileStatus = "Profile loaded: \(savedProfile.name)"
            }
            let box = try DurableOutbox(path: root.appendingPathComponent("outbox.sqlite3"))
            outbox = box
            let databaseURL = root.appendingPathComponent("measurements.sqlite3")
            measurementDBURL = databaseURL
            let recovered = try MeasurementRecorder.recoverUnfinishedSessions(
                path: databaseURL, endedAt: Date().timeIntervalSince1970
            )
            if recovered == 0 {
                localRecordingStatus = "Ready to record"
            } else {
                let suffix = recovered == 1 ? "" : "s"
                localRecordingStatus = "Recovered " + String(recovered)
                    + " interrupted session" + suffix
            }
            publishCarPlayProjection()
            uploader = try BackgroundUploader(outbox: box, clientID: clientID,
                directory: root.appendingPathComponent("uploads"))
            uploader?.onStatus = { [weak self] message in
                self?.uploadStatus = message
                Task { await self?.refreshQueueDepth() }
            }
            restoreBackgroundSession()
            Task { await refreshQueueDepth() }
        } catch {
            localRecordingEnabled = false
            storageStatus = "Storage unavailable. Collection is disabled."
        }
    }

    private func endpoint() throws -> URL {
        guard let url = URL(string: serverText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, ["", "/"].contains(url.path) else {
            throw TelemetrySetupError.invalidEndpoint
        }
        return url
    }

    func saveCredential(_ value: String) {
        do {
            guard !value.isEmpty, value.utf8.count <= 512 else { return }
            try CredentialStore.save(value)
            credentialSaved = true
            uploadStatus = "Credential stored in Keychain"
            Task { await flush() }
        } catch { uploadStatus = "Credential could not be stored" }
    }

    func connect() {
        guard prepareAcquisitionMode(.live) else { return }
        demoAdapter.stop()
        liveAdapter.stop()
        diagnosticAdapter.stop()
        disconnect()
        do {
            let base = try endpoint()
            UserDefaults.standard.set(base.absoluteString, forKey: "serverURL")
            frameSequenceTracker.reset()
            clientDrops = 0
            invalidFrameCount = 0
            reconnectAttempt = 0
            serverBackoff.reset()
            pingMetrics.reset()
            serverRTTMilliseconds = nil
            serverPingFailures = 0
            let generation = UUID()
            connectionGeneration = generation
            socketLoop = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled && self.connectionGeneration == generation {
                    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                        self.connection = "Invalid server URL"
                        return
                    }
                    components.scheme = "wss"; components.path = "/ws"
                    guard let socketURL = components.url else {
                        self.connection = "Invalid server URL"
                        return
                    }
                    let task = URLSession.shared.webSocketTask(with: socketURL)
                    self.socket = task
                    self.connection = "Connecting"
                    task.resume()
                    self.connectionStableSince = nil
                    let pinger = self.startServerPingLoop(task: task, generation: generation)
                    self.pingLoop = pinger
                    do {
                        while !Task.isCancelled {
                            let message = try await task.receive()
                            guard self.connectionGeneration == generation else { return }
                            let data: Data
                            switch message {
                            case .data(let value): data = value
                            case .string(let value): data = Data(value.utf8)
                            @unknown default: continue
                            }
                            if let update = RecordingStatusUpdate.decode(data) {
                                self.serverRecording = update.status
                                if update.isControl { continue }
                            }
                            guard data.count <= 256 * 1024,
                                  let frame = try? JSONDecoder().decode(CanFrame.self, from: data),
                                  frame.v == 1 else {
                                self.invalidFrameCount = self.invalidFrameCount == Int.max
                                    ? Int.max : self.invalidFrameCount + 1
                                continue
                            }
                            _ = self.frameSequenceTracker.accept(sequence: frame.status.seq)
                            self.clientDrops = self.frameSequenceTracker.dropCount
                            self.frame = frame; self.lastFrameAt = Date(); self.connection = "Connected"
                            self.canSource = "Server"
                            if let raw = frame.raw {
                                let idWidth = raw.isExtended ? 8 : 3
                                let identifier = String(format: "0x%0*X", idWidth, raw.arbitrationID)
                                let bytes = raw.data.map { String(format: "%02X", $0) }.joined(separator: " ")
                                let fd = raw.isFD ? "  FD DLC\(raw.dlc) \(raw.bitrateSwitch ? "BRS" : "")" : ""
                                self.rawCANText = "\(identifier)  \(bytes)\(fd)"
                            } else {
                                self.rawCANText = "-"
                            }
                            self.updateDashboardConditions(values: frame.sig, now: frame.t)
                            if self.connectionStableSince == nil {
                                self.connectionStableSince = Date()
                            } else if let stableSince = self.connectionStableSince,
                                      Date().timeIntervalSince(stableSince) >= 10 {
                                self.serverBackoff.reset()
                                self.reconnectAttempt = 0
                            }
                            if !frame.sig.isEmpty {
                                self.points.append(CanPoint(time: Date(), signals: frame.sig))
                                self.points.removeAll { $0.time < Date().addingTimeInterval(-60) }
                                if self.points.count > 600 { self.points.removeFirst(self.points.count - 600) }
                            }
                        }
                    } catch {
                        guard !Task.isCancelled && self.connectionGeneration == generation else { return }
                        self.connection = "Reconnecting"
                        self.serverRecording = nil
                        task.cancel(with: .goingAway, reason: nil)
                        self.connectionStableSince = nil
                        self.frameSequenceTracker.reset()
                        self.clientDrops = 0
                        let delay = self.serverBackoff.nextDelaySeconds()
                        self.reconnectAttempt = min(Int.max, self.reconnectAttempt + 1)
                        pinger.cancel()
                        self.pingLoop = nil
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    }
                    pinger.cancel()
                    self.pingLoop = nil
                }
            }
            Task { await flush() }
        } catch { connection = "Enter a trusted HTTPS server URL" }
    }

    func disconnect() {
        connectionGeneration = UUID()
        socketLoop?.cancel(); socketLoop = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        pingLoop?.cancel(); pingLoop = nil
        connectionStableSince = nil
        serverBackoff.reset()
        reconnectAttempt = 0
        pingMetrics.reset()
        serverRTTMilliseconds = nil
        serverPingFailures = 0
        connection = "Disconnected"
        serverRecording = nil
        publishCarPlayProjection()
    }

    private func prepareAcquisitionMode(_ mode: TelemetryRunMode) -> Bool {
        guard !recordingClosing, localRecorder == nil || runMode == mode else {
            adapterStatus = "Stop recording before changing LIVE/DEMO mode"
            return false
        }
        runMode = mode
        return true
    }

    func startDemoAdapter() {
        guard prepareAcquisitionMode(.demo) else { return }
        disconnect()
        liveAdapter.stop()
        diagnosticAdapter.stop()
        runMode = .demo
        demoAdapter.start()
    }

    func stopDemoAdapter() {
        demoAdapter.stop()
        liveAdapter.stop()
        diagnosticAdapter.stop()
        Task { await telemetryStore.disconnect() }
        adapterSignalValue = nil
        canSource = "None"
        rawCANText = "-"
        publishCarPlayProjection()
    }

    func startLiveAdapter() {
        guard prepareAcquisitionMode(.live) else { return }
        disconnect()
        demoAdapter.stop()
        diagnosticAdapter.stop()
        runMode = .live
        guard let adapterProfile else {
            adapterProfileStatus = "No live adapter profile"
            adapterStatus = "Live adapter not configured"
            return
        }
        configureLocalSignalTimeouts(adapterProfile.signals)
        configureDiagnosticSignalTimeouts(adapterProfile.diagnosticQueries)
        if adapterProfile.diagnosticQueries.isEmpty {
            liveAdapter.start(profile: adapterProfile)
        } else {
            liveAdapter.stop()
            diagnosticAdapter.start(profile: adapterProfile)
        }
    }

    func stopLiveAdapter() {
        stopDemoAdapter()
    }

    func scanBLE() { bleDiscovery.start() }

    func stopBLEScan() { bleDiscovery.stop() }

    func inspectBLEDevice(_ id: UUID) { bleDiscovery.inspect(id) }

    func copyBLEObservation() {
        guard let data = bleDiscovery.observationData(),
              let text = String(data: data, encoding: .utf8) else {
            bleDiscoveryStatus = "No BLE observation to copy"
            return
        }
        UIPasteboard.general.string = text
        bleDiscoveryStatus = "BLE observation copied; no write was sent"
    }

    func saveBLEObservation() {
        guard let data = bleDiscovery.observationData(), let adapterProfileURL else {
            bleDiscoveryStatus = "No BLE observation to save"
            return
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let url = adapterProfileURL.deletingLastPathComponent()
            .appendingPathComponent("ble-observation-\(stamp).json")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            bleDiscoveryStatus = "BLE observation saved: \(url.lastPathComponent)"
        } catch {
            bleDiscoveryStatus = "BLE observation could not be saved"
        }
    }

    func createSantaFeDiagnosticProfile(from peripheralID: UUID) {
        do {
            let queries = try SantaFeMX5HybridQueryCatalog.initialQueries()
            let profile = try bleDiscovery.makeDiagnosticProfile(for: peripheralID, queries: queries)
            let data = try JSONEncoder().encode(profile)
            importAdapterProfile(data)
            bleDiscoveryStatus = "Observed GATT profile converted to Santa Fe diagnostic profile"
        } catch BLEObservedProfileError.serviceCountIsAmbiguous {
            bleDiscoveryStatus = "Profile not created: service count is ambiguous"
        } catch BLEObservedProfileError.writeCharacteristicIsAmbiguous {
            bleDiscoveryStatus = "Profile not created: write characteristic is ambiguous"
        } catch BLEObservedProfileError.notifyCharacteristicIsAmbiguous {
            bleDiscoveryStatus = "Profile not created: notify characteristic is ambiguous"
        } catch {
            bleDiscoveryStatus = "Observed GATT profile could not be converted"
        }
    }

    func importAdapterProfile(_ data: Data) {
        do {
            let profile = try JSONDecoder().decode(AdapterProfile.self, from: data)
            adapterProfile = profile
            adapterProfileStatus = "Profile loaded: \(profile.name)"
            configureLocalSignalTimeouts(profile.signals)
            configureDiagnosticSignalTimeouts(profile.diagnosticQueries)
            if let adapterProfileURL {
                try data.write(to: adapterProfileURL, options: .atomic)
            }
        } catch {
            adapterProfile = nil
            adapterProfileStatus = "Adapter profile invalid"
        }
    }

    func replaceAdapterProfileSignals(_ signals: [SignalDefinition]) -> Bool {
        guard let profile = adapterProfile, let adapterProfileURL, !signals.isEmpty else {
            adapterProfileStatus = "Load an adapter profile before editing signals"
            return false
        }
        do {
            let updated = try AdapterProfile(
                id: profile.id,
                name: profile.name,
                transport: profile.transport,
                peripheralID: profile.peripheralID,
                serviceUUID: profile.serviceUUID,
                writeCharacteristicUUID: profile.writeCharacteristicUUID,
                notifyCharacteristicUUID: profile.notifyCharacteristicUUID,
                host: profile.host,
                port: profile.port,
                signals: signals,
                diagnosticQueries: profile.diagnosticQueries
            )
            let data = try JSONEncoder().encode(updated)
            try data.write(to: adapterProfileURL, options: .atomic)
            adapterProfile = updated
            adapterProfileStatus = "Profile saved: \(updated.name), \(signals.count) signals"
            configureLocalSignalTimeouts(signals)
            configureDiagnosticSignalTimeouts(updated.diagnosticQueries)
            return true
        } catch {
            adapterProfileStatus = "Signal catalog invalid"
            return false
        }
    }

    private func handleDemoFrame(_ frame: CANFrame, decoded: DecodedSignal) {
        adapterStatus = "Demo adapter monitoring"
        adapterSignalValue = decoded.value
        rawCANText = String(format: "0x%03X  %@", frame.canID,
                            frame.payload.map { String(format: "%02X", $0) }.joined(separator: " "))
        let sample = DecodedSignalSample(
            signalID: "demo.signal",
            value: decoded.value,
            rawValue: decoded.rawValue,
            enumName: decoded.enumName,
            unit: "demo",
            frameSequence: frame.sequence,
            receivedAtEpoch: frame.receivedAtEpoch,
            receivedAtMonotonicNanos: frame.receivedAtMonotonicNanos,
            source: .demo
        )
        ingestLocal(frame: frame, samples: [sample])
        applyLocalSignals(
            frame,
            values: ["demo.signal": decoded.value],
            rawValues: ["demo.signal": decoded.rawValue],
            source: "Demo"
        )
        record(contentsOf: [.can(frame: frame), .signal(sample)])
        publishCarPlayProjection()
    }

    private func handleAdapterState(_ state: String) {
        adapterStatus = state
        let event = AdapterRuntimeEvent(state: state).rawValue
        record(.system(name: event, timestamp: Date().timeIntervalSince1970,
                       monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        publishCarPlayProjection()
    }

    private func handleLiveFrame(_ frame: CANFrame, decoded: [LiveDecodedSignal]) {
        adapterStatus = "Live adapter monitoring"
        adapterSignalValue = decoded.first?.decoded.value
        let idFormat = frame.isExtended ? "0x%08X  %@" : "0x%03X  %@"
        rawCANText = String(format: idFormat, frame.canID,
                            frame.payload.map { String(format: "%02X", $0) }.joined(separator: " "))
        applyLocalSignals(
            frame,
            values: Dictionary(uniqueKeysWithValues: decoded.map { ($0.definition.id, $0.decoded.value) }),
            rawValues: Dictionary(uniqueKeysWithValues: decoded.map { ($0.definition.id, $0.decoded.rawValue) }),
            source: "Adapter"
        )
        ingestLocal(frame: frame, samples: decoded.map(\.sample))
        // Raw frames remain valuable even when the current signal catalog does
        // not contain a matching definition. Never drop the source measurement
        // solely because signal decoding is unavailable.
        record(contentsOf: [.can(frame: frame)] + decoded.map { .signal($0.sample) })
        publishCarPlayProjection()
    }

    private func handleDiagnosticResult(_ result: OBDQueryResult) {
        adapterStatus = "Diagnostic query monitoring"
        adapterSignalValue = result.signals.first?.value
        let values = Dictionary(uniqueKeysWithValues: result.signals.map { ($0.signalID, $0.value) })
        let rawValues = Dictionary(uniqueKeysWithValues: result.signals.map { ($0.signalID, $0.rawValue) })
        applyLocalDiagnosticSignals(
            values: values,
            rawValues: rawValues,
            source: "Diagnostic",
            sequence: result.response.sequence,
            timestamp: result.response.receivedAtEpoch,
            responseCANID: result.response.responseCANID
        )
        for signal in result.signals {
            localSignalReceivedAt[signal.signalID] = signal.receivedAtEpoch
            Task { await telemetryStore.ingest(diagnostic: signal) }
        }
        record(contentsOf: [.diagnosticResponse(result.response)] + result.signals.map {
            .diagnosticSignal($0)
        })
        publishCarPlayProjection()
    }

    private func ingestLocal(frame: CANFrame, samples: [DecodedSignalSample]) {
        for sample in samples {
            localSignalReceivedAt[sample.signalID] = sample.receivedAtEpoch
        }
        Task {
            await telemetryStore.ingest(frame: frame)
            for sample in samples { await telemetryStore.ingest(signal: sample) }
        }
    }

    private func configureLocalSignalTimeouts(_ definitions: [SignalDefinition]) {
        let timeouts = definitions.reduce(into: [String: Double]()) { result, definition in
            result[definition.id] = definition.timeout
        }
        localSignalTimeouts = timeouts
        Task { await telemetryStore.configureSignalTimeouts(timeouts) }
    }

    private func configureDiagnosticSignalTimeouts(_ queries: [OBDQueryDefinition]) {
        let timeouts = queries.reduce(into: [String: Double]()) { result, query in
            for signal in query.signals { result[signal.id] = signal.timeout }
        }
        localSignalTimeouts.merge(timeouts) { _, diagnostic in diagnostic }
        Task { await telemetryStore.configureSignalTimeouts(localSignalTimeouts) }
    }

    private func applyLocalSignals(
        _ frame: CANFrame,
        values: [String: Double],
        rawValues: [String: UInt64] = [:],
        source: String
    ) {
        guard !values.isEmpty,
              frame.sequence <= UInt64(Int.max),
              let snapshot = try? ServerCANFrame(
                version: 1,
                serverTimestamp: frame.receivedAtEpoch,
                signals: values,
                status: .init(sequence: Int(frame.sequence), drop: 0)
              ) else { return }
        let now = Date()
        self.frame = snapshot
        lastFrameAt = now
        canSource = source
        updateDashboardConditions(values: values, rawValues: rawValues, now: frame.receivedAtEpoch)
        points.append(CanPoint(time: now, signals: values))
        points.removeAll { $0.time < now.addingTimeInterval(-60) }
        if points.count > 600 { points.removeFirst(points.count - 600) }
    }

    private func applyLocalDiagnosticSignals(
        values: [String: Double],
        rawValues: [String: UInt64],
        source: String,
        sequence: UInt64,
        timestamp: Double,
        responseCANID: UInt32
    ) {
        guard !values.isEmpty, sequence <= UInt64(Int.max),
              let snapshot = try? ServerCANFrame(
                version: 1,
                serverTimestamp: timestamp,
                signals: values,
                status: .init(sequence: Int(sequence), drop: 0)
              ) else { return }
        let now = Date()
        frame = snapshot
        lastFrameAt = now
        canSource = source
        let width = responseCANID > 0x7FF ? 8 : 3
        rawCANText = "DIAGNOSTIC RESPONSE 0x\(String(format: "%0*X", width, responseCANID))  (not passive CAN)"
        updateDashboardConditions(values: values, rawValues: rawValues, now: timestamp)
        points.append(CanPoint(time: now, signals: values))
        points.removeAll { $0.time < now.addingTimeInterval(-60) }
        if points.count > 600 { points.removeFirst(points.count - 600) }
    }

    private func updateDashboardConditions(
        values: [String: Double],
        rawValues: [String: UInt64] = [:],
        now: Double
    ) {
        guard let pages = dashboardProfile?.pages else { return }
        for widget in pages.flatMap(\.widgets) {
            guard let condition = widget.configuration.condition,
                  let signalID = widget.signalID,
                  let value = values[signalID] else { continue }
            var runtime = conditionRuntimes[widget.id] ?? DashboardConditionRuntime()
            let active = runtime.update(
                condition: condition,
                value: value,
                rawValue: rawValues[signalID],
                stale: false,
                now: now
            )
            conditionRuntimes[widget.id] = runtime
            conditionStates[widget.id] = active
        }
    }

    private func publishCarPlayProjection() {
        #if canImport(CarPlay)
        let recordingState: String = storageStatus != nil
            ? "failed"
            : recordingLifecycle.state.rawValue
        var values = frame?.sig ?? [:]
        if let adapterSignalValue { values["adapter"] = adapterSignalValue }
        CarPlayProjectionBridge.shared.update(CarPlayProjectionState(
            adapterState: adapterStatus,
            recordingState: recordingState,
            profileName: dashboardProfile?.name ?? "Unselected",
            elapsedSeconds: recordingStartedAt.map {
                Int(max(0, Date().timeIntervalSince($0)))
            } ?? 0,
            primaryValues: values
        ))
        #endif
    }

    func startLocation() {
        guard outbox != nil, storageStatus == nil else { return }
        locationService.start()
        record(.system(name: "gps_started", timestamp: Date().timeIntervalSince1970,
                       monotonicNanos: DispatchTime.now().uptimeNanoseconds))
    }

    func stopLocation() {
        locationService.stop()
        collecting = false
        locationStatus = "Stopped"
        record(.system(name: "gps_stopped", timestamp: Date().timeIntervalSince1970,
                       monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        if let event = try? TelemetryEvent.state("stopped", capturedAt: Date().timeIntervalSince1970,
            source: "ios-native", appVersion: eventAppVersion, device: eventDevice) { store(event) }
    }

    private func handleLocations(_ locations: [CLLocation]) {
        guard collecting else { return }
        let background = UIApplication.shared.applicationState != .active
        for location in locations where location.horizontalAccuracy >= 0 {
            if let event = try? TelemetryEvent.gps(latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude, speed: location.speed, heading: location.course,
                accuracy: location.horizontalAccuracy, altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                capturedAt: location.timestamp.timeIntervalSince1970, background: background,
                source: "ios-native", appVersion: eventAppVersion, device: eventDevice) {
                lastLocation = event
                locationStatus = "Collecting"
                locationTrack.append(location.coordinate)
                if locationTrack.count > 1_000 {
                    locationTrack = Array(locationTrack.suffix(1_000))
                }
                store(event)
                let sample = LocationSample(
                    originalTimestamp: location.timestamp.timeIntervalSince1970,
                    receivedAtEpoch: Date().timeIntervalSince1970,
                    receivedAtMonotonicNanos: DispatchTime.now().uptimeNanoseconds,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                    speed: location.speed >= 0 ? location.speed : nil,
                    course: location.course >= 0 ? location.course : nil,
                    horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                    verticalAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil
                )
                Task { await telemetryStore.ingest(location: sample) }
                record(.location(sample))
            }
        }
    }

    private func store(_ event: TelemetryEvent) {
        guard let outbox else { return }
        Task {
            do {
                try await outbox.enqueue(event)
                if event.type == "MARK" { lastMarkAt = Date(timeIntervalSince1970: event.capturedAt) }
                await refreshQueueDepth()
                await flush()
            } catch {
                locationService.stop()
                collecting = false
                storageStatus = "Recording stopped: durable storage failed or queue is full. Existing records retained."
            }
        }
    }

    private func record(_ event: MeasurementEvent) {
        record(contentsOf: [event])
    }

    private func record(contentsOf events: [MeasurementEvent]) {
        guard localRecordingEnabled, let writer = recordingWriteQueue else { return }
        do {
            // Admission happens now, not inside a later Task. Stop closes this
            // same queue synchronously, then drains all accepted submissions.
            let pending = try writer.enqueue(contentsOf: events)
            localRecordingStatus = "Writing local measurements"
            Task { [weak self] in
                do {
                    try await pending.value
                    guard let self, self.recordingWriteQueue === writer,
                          self.localRecordingEnabled else { return }
                    self.localRecordingStatus = "Local recorder active"
                } catch {
                    self?.handleRecordingFailure(writer: writer)
                }
            }
        } catch {
            handleRecordingFailure(writer: writer)
        }
    }

    private func handleRecordingFailure(writer: MeasurementWriteQueue) {
        guard recordingWriteQueue === writer else { return }
        localRecordingEnabled = false
        recordingLifecycle.fail()
        localRecordingStatus = "Local recording failed; preserving accepted measurements"
        // An errored queue is drained and closed with recording_failed, never
        // a success marker. It must not poison a later session's UI callbacks.
        stopRecording()
    }

    func duplicateDashboardWidget(pageID: String, widgetID: String) {
        guard var profile = dashboardProfile else { return }
        let newID = "\(widgetID)-\(UUID().uuidString.prefix(6).lowercased())"
        guard (try? profile.duplicateWidget(pageID: pageID, widgetID: widgetID, newID: newID)) != nil else { return }
        dashboardProfile = profile
        persistDashboardProfile()
    }

    func deleteDashboardWidget(pageID: String, widgetID: String) {
        guard var profile = dashboardProfile,
              profile.deleteWidget(pageID: pageID, widgetID: widgetID) else { return }
        dashboardProfile = profile
        conditionRuntimes.removeValue(forKey: widgetID)
        conditionStates.removeValue(forKey: widgetID)
        persistDashboardProfile()
    }

    func addDashboardWidget(pageID: String, type: DashboardWidgetType) {
        guard var profile = dashboardProfile,
              let page = profile.pages.first(where: { $0.id == pageID }) else { return }
        let id = "widget-\(type.rawValue)-\(UUID().uuidString.prefix(8).lowercased())"
        let maxRow = page.widgets.map { $0.rect.y + $0.rect.height }.max() ?? 0
        let dimensions: (width: Int, height: Int) = type == .map
            ? (6, 3)
            : (type == .timeSeries ? (3, 2) : (2, 1))
        let signalID: String? = [
            .numericGauge, .circularGauge, .semiCircularGauge,
            .horizontalBar, .verticalBar, .led, .timeSeries
        ].contains(type) ? "ws_fl" : nil
        let unit = signalID == nil ? "" : "km/h"
        let configuration = DashboardWidgetConfiguration(
            label: Self.widgetLabel(type),
            unit: unit,
            decimals: 1,
            minimum: signalID == nil ? nil : 0,
            maximum: signalID == nil ? nil : 240,
            warningThreshold: nil,
            criticalThreshold: nil
        )
        let widget = DashboardWidgetDefinition(
            id: id,
            type: type,
            signalID: signalID,
            rect: DashboardRect(x: 0, y: maxRow, width: dimensions.width, height: dimensions.height),
            zIndex: (page.widgets.map(\.zIndex).max() ?? 0) + 1,
            configuration: configuration
        )
        guard (try? profile.addWidget(widget, toPage: pageID)) != nil else { return }
        dashboardProfile = profile
        persistDashboardProfile()
    }

    func snapDashboard(pageID: String, grid: Int = 8) {
        guard var profile = dashboardProfile else { return }
        profile.snapToGrid(pageID: pageID, grid: grid)
        dashboardProfile = profile
        persistDashboardProfile()
    }

    func alignDashboardWidget(
        pageID: String,
        widgetID: String,
        alignment: DashboardAlignment,
        columns: Int
    ) {
        guard var profile = dashboardProfile,
              (try? profile.alignWidget(
                pageID: pageID,
                widgetID: widgetID,
                alignment: alignment,
                columns: columns
              )) != nil else { return }
        dashboardProfile = profile
        persistDashboardProfile()
    }

    func updateDashboardWidgetRect(pageID: String, widgetID: String, rect: DashboardRect) {
        guard var profile = dashboardProfile,
              (try? profile.updateWidgetRect(pageID: pageID, widgetID: widgetID, rect: rect)) != nil else { return }
        dashboardProfile = profile
        persistDashboardProfile()
    }

    func updateDashboardWidgetBinding(
        pageID: String,
        widgetID: String,
        signalID: String?,
        configuration: DashboardWidgetConfiguration
    ) {
        guard var profile = dashboardProfile,
              (try? profile.updateWidgetBinding(
                pageID: pageID,
                widgetID: widgetID,
                signalID: signalID,
                configuration: configuration
              )) != nil else { return }
        dashboardProfile = profile
        conditionRuntimes.removeValue(forKey: widgetID)
        conditionStates.removeValue(forKey: widgetID)
        persistDashboardProfile()
    }

    func bringDashboardWidgetToFront(pageID: String, widgetID: String) {
        guard var profile = dashboardProfile,
              (try? profile.bringWidgetToFront(pageID: pageID, widgetID: widgetID)) != nil else { return }
        dashboardProfile = profile
        persistDashboardProfile()
    }

    func addDashboardPage() {
        guard var profile = dashboardProfile else { return }
        let id = "page-" + UUID().uuidString.prefix(8).lowercased()
        let page = DashboardPage(id: id, name: "Page " + String(profile.pages.count + 1),
                                 orientation: .landscape, widgets: [])
        guard (try? profile.addPage(page)) != nil else { return }
        dashboardProfile = profile
        persistDashboardProfile()
    }

    func deleteDashboardPage(pageID: String) {
        guard var profile = dashboardProfile,
              (try? profile.deletePage(id: pageID)) != nil else { return }
        dashboardProfile = profile
        persistDashboardProfile()
    }

    func setDashboardOrientation(pageID: String, orientation: DashboardOrientation) {
        guard var profile = dashboardProfile,
              (try? profile.setPageOrientation(pageID: pageID, orientation: orientation)) != nil else { return }
        dashboardProfile = profile
        persistDashboardProfile()
    }

    private func persistDashboardProfile() {
        guard let dashboardProfile, let dashboardURL,
              let data = try? JSONEncoder().encode(dashboardProfile) else { return }
        do {
            try data.write(to: dashboardURL, options: .atomic)
        } catch {
            storageStatus = "Dashboard profile could not be saved"
        }
    }

    private static func defaultDashboardProfile() -> DashboardProfile? {
        func widget(_ id: String, _ label: String, _ signalID: String, _ unit: String,
                    x: Int, y: Int) -> DashboardWidgetDefinition {
            DashboardWidgetDefinition(
                id: id,
                type: .numericGauge,
                signalID: signalID,
                rect: DashboardRect(x: x, y: y, width: 2, height: 1),
                zIndex: y * 3 + x / 2,
                configuration: DashboardWidgetConfiguration(
                    label: label, unit: unit, decimals: 1,
                    minimum: nil, maximum: nil, warningThreshold: nil, criticalThreshold: nil
                )
            )
        }
        return try? DashboardProfile(
            id: "vehicle-a-normal",
            name: "Vehicle A Normal",
            pages: [DashboardPage(
                id: "main", name: "Main", orientation: .landscape,
                widgets: [
                    widget("ws-fl", "Speed", "ws_fl", "km/h", x: 0, y: 0),
                    widget("ws-fr", "FR", "ws_fr", "km/h", x: 2, y: 0),
                    widget("ws-rl", "RL", "ws_rl", "km/h", x: 4, y: 0),
                    widget("ws-rr", "RR", "ws_rr", "km/h", x: 0, y: 1),
                    widget("yaw", "Yaw", "yaw", "deg/s", x: 2, y: 1),
                    widget("ay", "Ay", "ay", "m/s2", x: 4, y: 1),
                    DashboardWidgetDefinition(
                        id: "gps-map",
                        type: .map,
                        signalID: nil,
                        rect: DashboardRect(x: 0, y: 2, width: 6, height: 3),
                        zIndex: 10,
                        configuration: DashboardWidgetConfiguration(
                            label: "Route Track", unit: "", decimals: 1,
                            minimum: nil, maximum: nil, warningThreshold: nil, criticalThreshold: nil
                        )
                    )
                ]
            )]
        )
    }

    private static func widgetLabel(_ type: DashboardWidgetType) -> String {
        switch type {
        case .numericGauge: return "Numeric Gauge"
        case .circularGauge: return "Circular Gauge"
        case .semiCircularGauge: return "Semi Gauge"
        case .horizontalBar: return "Horizontal Bar"
        case .verticalBar: return "Vertical Bar"
        case .led: return "LED Indicator"
        case .statusIcon: return "Status"
        case .rawCANHex: return "Raw CAN"
        case .bitView: return "Bit View"
        case .timeSeries: return "Time Series"
        case .gps: return "GPS Info"
        case .map: return "Route Track"
        }
    }

    func mark() {
        if let event = try? TelemetryEvent.mark(note: "", capturedAt: Date().timeIntervalSince1970,
            background: UIApplication.shared.applicationState != .active, source: "ios-native",
            appVersion: eventAppVersion, device: eventDevice) {
            store(event)
            record(.system(name: "MARK", timestamp: event.capturedAt,
                           monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        }
    }

    func sceneChanged(background: Bool) {
        if collecting, let event = try? TelemetryEvent.state(background ? "background" : "foreground",
            capturedAt: Date().timeIntervalSince1970, source: "ios-native",
            appVersion: eventAppVersion, device: eventDevice) {
            store(event)
            record(.system(name: background ? "background" : "foreground",
                           timestamp: event.capturedAt,
                           monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        }
        if !background { Task { await flush(); await refreshQueueDepth() } }
    }

    func flush(force: Bool = false) async {
        guard let endpoint = try? endpoint(), let credential = CredentialStore.read() else { return }
        await uploader?.flush(to: endpoint, credential: credential, force: force)
    }

    func exportMeasurementJSON() async -> Data? {
        guard let recorder = localRecorder ?? completedRecorder else {
            exportStatus = "Local recorder unavailable"
            return nil
        }
        let writer = recordingWriteQueue
        do {
            try await writer?.drain()
            let data = try await recorder.exportSessionJSON()
            exportStatus = "Export ready: \(data.count) bytes"
            return data
        } catch {
            exportStatus = "Measurement export failed"
            return nil
        }
    }

    func exportMeasurementCSV() async -> Data? {
        guard let recorder = localRecorder ?? completedRecorder else {
            exportStatus = "Local recorder unavailable"
            return nil
        }
        let writer = recordingWriteQueue
        do {
            try await writer?.drain()
            let data = try await recorder.exportCSV()
            exportStatus = "CSV export ready: \(data.count) bytes"
            return data
        } catch {
            exportStatus = "CSV export failed"
            return nil
        }
    }

    func finishLocalMeasurement() {
        stopRecording()
    }

    func startRecording() {
        guard localRecorder == nil, !recordingClosing, let measurementDBURL,
              recordingLifecycle.start() else { return }
        do {
            let now = Date().timeIntervalSince1970
            // A second Start in the same wall-clock second is a new session.
            let sessionID = "ios-\(Int(now))-\(UUID().uuidString.lowercased())"
            let recorder = try MeasurementRecorder(
                path: measurementDBURL,
                sessionID: sessionID,
                startedAt: now,
                mode: runMode
            )
            let writer = try MeasurementWriteQueue(recorder: recorder)
            localRecorder = recorder
            recordingWriteQueue = writer
            completedRecorder = nil
            localRecordingEnabled = true
            recordingStartedAt = Date(timeIntervalSince1970: now)
            localRecordingStatus = "Local recorder ready"
            record(.system(name: "recording_started", timestamp: now,
                           monotonicNanos: DispatchTime.now().uptimeNanoseconds))
            publishCarPlayProjection()
        } catch {
            localRecordingEnabled = false
            recordingLifecycle.fail()
            localRecordingStatus = "Local recorder unavailable"
        }
    }

    func stopRecording() {
        guard !recordingClosing else { return }
        guard let recorder = localRecorder, let writer = recordingWriteQueue else {
            localRecordingEnabled = false
            return
        }
        localRecordingEnabled = false
        recordingClosing = true
        localRecordingStatus = "Closing local recording"
        let pending = writer.finish(endedAt: Date().timeIntervalSince1970,
                                    monotonicNanos: DispatchTime.now().uptimeNanoseconds)
        Task { [weak self] in
            let result = await pending.result
            guard let self, self.recordingWriteQueue === writer else { return }
            self.completedRecorder = recorder
            self.localRecorder = nil
            self.recordingWriteQueue = nil
            self.recordingClosing = false
            self.recordingStartedAt = nil
            switch result {
            case .success:
                self.localRecordingStatus = "Recording off"
                self.recordingLifecycle.stop()
            case .failure:
                self.localRecordingStatus = "Recording failed; retained data is available for export"
                self.recordingLifecycle.fail()
            }
            self.publishCarPlayProjection()
        }
    }

    func restoreBackgroundSession() {
        uploader?.restoreSession(baseURL: try? endpoint(), credential: CredentialStore.read())
    }

    private func refreshQueueDepth() async {
        guard let outbox else { return }
        do {
            queueDepth = try await outbox.count()
        } catch {
            // Keep the last known count; zero would falsely imply a drained queue.
            storageStatus = "Durable upload queue unavailable"
            uploadStatus = "Durable queue unavailable"
        }
    }

    private func startServerPingLoop(
        task: URLSessionWebSocketTask,
        generation: UUID
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return
                }
                guard let self, self.connectionGeneration == generation else { return }
                let startedAt = Date()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    task.sendPing { error in
                        Task { @MainActor [weak self] in
                            guard let self, self.connectionGeneration == generation else {
                                continuation.resume()
                                return
                            }
                            if error == nil {
                                self.pingMetrics.recordSuccess(
                                    rttMilliseconds: Date().timeIntervalSince(startedAt) * 1_000
                                )
                            } else {
                                self.pingMetrics.recordFailure()
                            }
                            self.serverRTTMilliseconds = self.pingMetrics.lastRTTMilliseconds
                            self.serverPingFailures = self.pingMetrics.consecutiveFailures
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }
}
