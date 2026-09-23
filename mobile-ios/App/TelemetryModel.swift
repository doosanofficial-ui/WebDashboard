import Foundation
import CoreLocation
import Observation
import UIKit
import TelemetryCore

struct CanFrame: Decodable {
    struct Status: Decodable { let seq: Int; let drop: Int }
    let v: Int
    let t: Double
    let sig: [String: Double]
    let status: Status
}
struct CanPoint: Identifiable {
    let id = UUID()
    let time: Date
    let signals: [String: Double]
}

@MainActor @Observable
final class TelemetryModel: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = TelemetryModel()
    var serverText = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    var connection = "Disconnected"
    var locationStatus = "Not collecting"
    var uploadStatus = "Not paired"
    var storageStatus: String?
    var frame: CanFrame?
    var lastFrameAt: Date?
    var lastLocation: TelemetryEvent?
    var points: [CanPoint] = []
    var queueDepth = 0
    var collecting = false
    var credentialSaved = CredentialStore.read() != nil
    var clientDrops = 0
    var lastMarkAt: Date?
    // Core Location delivers delegate events on this manager's main run loop.
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var outbox: DurableOutbox?
    @ObservationIgnored var uploader: BackgroundUploader?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var socketLoop: Task<Void, Never>?
    @ObservationIgnored private var wantsLocations = false
    @ObservationIgnored private var requestedAlways = false
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private let clientID: String

    private override init() {
        let existing = UserDefaults.standard.string(forKey: "clientID")
        clientID = existing ?? UUID().uuidString.lowercased()
        super.init()
        UserDefaults.standard.set(clientID, forKey: "clientID")
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Telemetry")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let box = try DurableOutbox(path: root.appendingPathComponent("outbox.sqlite3"))
            outbox = box
            uploader = try BackgroundUploader(outbox: box, clientID: clientID,
                directory: root.appendingPathComponent("uploads"))
            uploader?.onStatus = { [weak self] message in
                self?.uploadStatus = message
                Task { await self?.refreshQueueDepth() }
            }
            restoreBackgroundSession()
            Task { await refreshQueueDepth() }
        } catch { storageStatus = "Storage unavailable. Collection is disabled." }
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
                    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                    components.scheme = "wss"; components.path = "/ws"
                    let task = URLSession.shared.webSocketTask(with: components.url!)
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
                            guard data.count <= 256 * 1024,
                                  let frame = try? JSONDecoder().decode(CanFrame.self, from: data), frame.v == 1 else { continue }
                            if let previousSequence, frame.status.seq > previousSequence + 1 {
                                self.clientDrops += frame.status.seq - previousSequence - 1
                            }
                            previousSequence = frame.status.seq
                            self.frame = frame; self.lastFrameAt = Date(); self.connection = "Connected"
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
    }

    func startLocation() {
        guard outbox != nil, storageStatus == nil else { return }
        wantsLocations = true
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationStatus = "Location permission required"
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationStatus = "Allow Always in Settings for locked-screen collection"
            if !requestedAlways { requestedAlways = true; locationManager.requestAlwaysAuthorization() }
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
            collecting = true
            locationStatus = "Waiting for location"
        case .denied, .restricted:
            collecting = false
            locationStatus = "Location permission denied"
        @unknown default:
            locationStatus = "Location authorization unavailable"
        }
    }

    func stopLocation() {
        wantsLocations = false
        locationManager.stopUpdatingLocation()
        collecting = false; locationStatus = "Stopped"
        if let event = try? TelemetryEvent.state("stopped", capturedAt: Date().timeIntervalSince1970) { store(event) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if wantsLocations { startLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard collecting else { return }
        let background = UIApplication.shared.applicationState != .active
        for location in locations where location.horizontalAccuracy >= 0 {
            if let event = try? TelemetryEvent.gps(latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude, speed: location.speed, heading: location.course,
                accuracy: location.horizontalAccuracy, altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                capturedAt: location.timestamp.timeIntervalSince1970, background: background) {
                lastLocation = event
                locationStatus = "Collecting"
                store(event)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationStatus = "Location unavailable; last fix retained"
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
                locationManager.stopUpdatingLocation()
                collecting = false
                storageStatus = "Recording stopped: durable storage failed or queue is full. Existing records retained."
            }
        }
    }

    func mark() {
        if let event = try? TelemetryEvent.mark(note: "", capturedAt: Date().timeIntervalSince1970,
            background: UIApplication.shared.applicationState != .active) {
            store(event)
        }
    }

    func sceneChanged(background: Bool) {
        if collecting, let event = try? TelemetryEvent.state(background ? "background" : "foreground",
            capturedAt: Date().timeIntervalSince1970) { store(event) }
        if !background { Task { await flush(); await refreshQueueDepth() } }
    }

    func flush(force: Bool = false) async {
        guard let endpoint = try? endpoint(), let credential = CredentialStore.read() else { return }
        await uploader?.flush(to: endpoint, credential: credential, force: force)
    }

    func restoreBackgroundSession() {
        uploader?.restoreSession(baseURL: try? endpoint(), credential: CredentialStore.read())
    }

    private func refreshQueueDepth() async { queueDepth = (try? await outbox?.count()) ?? 0 }
}
