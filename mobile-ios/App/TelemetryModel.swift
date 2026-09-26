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
    var localRecordingStatus = "Local recorder unavailable"
    var exportStatus = "No export generated"
    var localRecordingEnabled = true
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
    var lastLocation: TelemetryEvent?
    var locationTrack: [CLLocationCoordinate2D] = []
    var points: [CanPoint] = []
    var queueDepth = 0
    var collecting = false
    var credentialSaved = CredentialStore.read() != nil
    var clientDrops = 0
    var lastMarkAt: Date?
    // Core Location delivers delegate events on this manager's main run loop.
    @ObservationIgnored private let locationService: LocationService
    @ObservationIgnored private let demoAdapter: DemoAdapterController
    @ObservationIgnored private let liveAdapter: LiveAdapterController
    @ObservationIgnored private let bleDiscovery: BLEDiscoveryController
    @ObservationIgnored private let telemetryStore: TelemetryStore
    @ObservationIgnored private var outbox: DurableOutbox?
    @ObservationIgnored private var localRecorder: MeasurementRecorder?
    @ObservationIgnored private var completedRecorder: MeasurementRecorder?
    @ObservationIgnored private var measurementDBURL: URL?
    @ObservationIgnored private var dashboardURL: URL?
    @ObservationIgnored private var adapterProfileURL: URL?
    @ObservationIgnored var uploader: BackgroundUploader?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var socketLoop: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private let clientID: String
    @ObservationIgnored private let measurementStartedAt = Date()

    private override init() {
        let existing = UserDefaults.standard.string(forKey: "clientID")
        clientID = existing ?? UUID().uuidString.lowercased()
        locationService = LocationService()
        demoAdapter = DemoAdapterController()
        liveAdapter = LiveAdapterController()
        bleDiscovery = BLEDiscoveryController()
        telemetryStore = TelemetryStore()
        super.init()
        UserDefaults.standard.set(clientID, forKey: "clientID")
        locationService.onStatus = { [weak self] status in self?.locationStatus = status }
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
            measurementDBURL = root.appendingPathComponent("measurements.sqlite3")
            let sessionID = "ios-\(Int(Date().timeIntervalSince1970))-\(clientID)"
            localRecorder = try MeasurementRecorder(
                path: measurementDBURL!,
                sessionID: sessionID,
                startedAt: Date().timeIntervalSince1970
            )
            localRecordingStatus = "Local recorder ready"
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
        disconnect()
        do {
            let base = try endpoint()
            UserDefaults.standard.set(base.absoluteString, forKey: "serverURL")
            let generation = UUID()
            connectionGeneration = generation
            socketLoop = Task { [weak self] in
                guard let self else { return }
                var backoff: UInt64 = 1
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
                    var previousSequence: Int?
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
                                  let frame = try? JSONDecoder().decode(CanFrame.self, from: data), frame.v == 1 else { continue }
                            if let previousSequence, frame.status.seq > previousSequence + 1 {
                                self.clientDrops += frame.status.seq - previousSequence - 1
                            }
                            previousSequence = frame.status.seq
                            self.frame = frame; self.lastFrameAt = Date(); self.connection = "Connected"
                            self.canSource = "Server"
                            backoff = 1
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
                        try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                        backoff = min(15, backoff * 2)
                    }
                }
            }
            Task { await flush() }
        } catch { connection = "Enter a trusted HTTPS server URL" }
    }

    func disconnect() {
        connectionGeneration = UUID()
        socketLoop?.cancel(); socketLoop = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        connection = "Disconnected"
        serverRecording = nil
        publishCarPlayProjection()
    }

    func startDemoAdapter() {
        demoAdapter.start()
    }

    func stopDemoAdapter() {
        demoAdapter.stop()
        Task { await telemetryStore.disconnect() }
        adapterSignalValue = nil
        canSource = "None"
        rawCANText = "-"
        publishCarPlayProjection()
    }

    func startLiveAdapter() {
        guard let adapterProfile else {
            adapterProfileStatus = "No live adapter profile"
            adapterStatus = "Live adapter not configured"
            return
        }
        configureLocalSignalTimeouts(adapterProfile.signals)
        liveAdapter.start(profile: adapterProfile)
    }

    func stopLiveAdapter() {
        liveAdapter.stop()
        Task { await telemetryStore.disconnect() }
        adapterSignalValue = nil
        canSource = "None"
        rawCANText = "-"
        publishCarPlayProjection()
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

    func importAdapterProfile(_ data: Data) {
        do {
            let profile = try JSONDecoder().decode(AdapterProfile.self, from: data)
            adapterProfile = profile
            adapterProfileStatus = "Profile loaded: \(profile.name)"
            configureLocalSignalTimeouts(profile.signals)
            if let adapterProfileURL {
                try data.write(to: adapterProfileURL, options: .atomic)
            }
        } catch {
            adapterProfile = nil
            adapterProfileStatus = "Adapter profile invalid"
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
            receivedAtMonotonicNanos: frame.receivedAtMonotonicNanos
        )
        ingestLocal(frame: frame, samples: [sample])
        applyLocalSignals(frame, values: ["demo.signal": decoded.value], source: "Demo")
        record(.can(frame: frame))
        record(.signal(sample))
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
            source: "Adapter"
        )
        ingestLocal(frame: frame, samples: decoded.map(\.sample))
        // Raw frames remain valuable even when the current signal catalog does
        // not contain a matching definition. Never drop the source measurement
        // solely because signal decoding is unavailable.
        record(.can(frame: frame))
        for item in decoded {
            record(.signal(item.sample))
        }
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
        let timeouts = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0.timeout) })
        localSignalTimeouts = timeouts
        Task { await telemetryStore.configureSignalTimeouts(timeouts) }
    }

    private func applyLocalSignals(_ frame: CANFrame, values: [String: Double], source: String) {
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
        points.append(CanPoint(time: now, signals: values))
        points.removeAll { $0.time < now.addingTimeInterval(-60) }
        if points.count > 600 { points.removeFirst(points.count - 600) }
    }

    private func publishCarPlayProjection() {
        #if canImport(CarPlay)
        let recordingState: String
        if storageStatus != nil {
            recordingState = "failed"
        } else if localRecordingStatus.contains("active") || localRecordingStatus.contains("Writing") {
            recordingState = "recording"
        } else if localRecordingStatus.contains("ready") {
            recordingState = "ready"
        } else {
            recordingState = "idle"
        }
        var values = frame?.sig ?? [:]
        if let adapterSignalValue { values["adapter"] = adapterSignalValue }
        CarPlayProjectionBridge.shared.update(CarPlayProjectionState(
            adapterState: adapterStatus,
            recordingState: recordingState,
            profileName: dashboardProfile?.name ?? "Unselected",
            elapsedSeconds: Int(max(0, Date().timeIntervalSince(measurementStartedAt))),
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
        if let event = try? TelemetryEvent.state("stopped", capturedAt: Date().timeIntervalSince1970) { store(event) }
    }

    private func handleLocations(_ locations: [CLLocation]) {
        guard collecting else { return }
        let background = UIApplication.shared.applicationState != .active
        for location in locations where location.horizontalAccuracy >= 0 {
            if let event = try? TelemetryEvent.gps(latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude, speed: location.speed, heading: location.course,
                accuracy: location.horizontalAccuracy, altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                capturedAt: location.timestamp.timeIntervalSince1970, background: background) {
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
        guard let localRecorder else {
            localRecordingStatus = "Recording off"
            return
        }
        localRecordingStatus = "Writing local measurements"
        Task {
            do {
                try await localRecorder.append(event)
                localRecordingStatus = "Local recorder active"
            } catch {
                localRecordingStatus = "Local recorder failed"
                storageStatus = "Local measurement recording failed; server/GPS queue remains separate."
            }
        }
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

    func updateDashboardWidgetRect(pageID: String, widgetID: String, rect: DashboardRect) {
        guard var profile = dashboardProfile,
              (try? profile.updateWidgetRect(pageID: pageID, widgetID: widgetID, rect: rect)) != nil else { return }
        dashboardProfile = profile
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
            background: UIApplication.shared.applicationState != .active) {
            store(event)
            record(.system(name: "MARK", timestamp: event.capturedAt,
                           monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        }
    }

    func sceneChanged(background: Bool) {
        if collecting, let event = try? TelemetryEvent.state(background ? "background" : "foreground",
            capturedAt: Date().timeIntervalSince1970) {
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
        do {
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
        do {
            let data = try await recorder.exportCSV()
            exportStatus = "CSV export ready: \(data.count) bytes"
            return data
        } catch {
            exportStatus = "CSV export failed"
            return nil
        }
    }

    func finishLocalMeasurement() {
        guard let localRecorder else { return }
        let endedAt = Date().timeIntervalSince1970
        Task {
            do {
                try await localRecorder.append(.system(
                    name: "recording_stopped",
                    timestamp: endedAt,
                    monotonicNanos: DispatchTime.now().uptimeNanoseconds
                ))
                try await localRecorder.finish(endedAt: endedAt)
                self.completedRecorder = localRecorder
                self.localRecorder = nil
                self.localRecordingEnabled = false
                localRecordingStatus = "Local measurement session closed"
            } catch {
                localRecordingStatus = "Local recorder could not close cleanly"
            }
        }
    }

    func startRecording() {
        guard localRecorder == nil, let measurementDBURL else { return }
        do {
            let now = Date().timeIntervalSince1970
            let sessionID = "ios-\(Int(now))-\(clientID)"
            let recorder = try MeasurementRecorder(path: measurementDBURL, sessionID: sessionID, startedAt: now)
            localRecorder = recorder
            completedRecorder = nil
            localRecordingEnabled = true
            localRecordingStatus = "Local recorder ready"
            Task {
                try? await recorder.append(.system(
                    name: "recording_started",
                    timestamp: now,
                    monotonicNanos: DispatchTime.now().uptimeNanoseconds
                ))
            }
            publishCarPlayProjection()
        } catch {
            localRecordingStatus = "Local recorder unavailable"
        }
    }

    func stopRecording() {
        guard let recorder = localRecorder else {
            localRecordingEnabled = false
            localRecordingStatus = "Recording off"
            return
        }
        localRecordingEnabled = false
        localRecordingStatus = "Closing local recording"
        let endedAt = Date().timeIntervalSince1970
        Task {
            do {
                try await recorder.append(.system(
                    name: "recording_stopped",
                    timestamp: endedAt,
                    monotonicNanos: DispatchTime.now().uptimeNanoseconds
                ))
                try await recorder.finish(endedAt: endedAt)
                completedRecorder = recorder
                localRecorder = nil
                localRecordingStatus = "Recording off"
                publishCarPlayProjection()
            } catch {
                localRecordingStatus = "Local recorder close failed"
            }
        }
    }

    func restoreBackgroundSession() {
        uploader?.restoreSession(baseURL: try? endpoint(), credential: CredentialStore.read())
    }

    private func refreshQueueDepth() async { queueDepth = (try? await outbox?.count()) ?? 0 }
}
