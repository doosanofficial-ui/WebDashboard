import CoreLocation

@MainActor
final class LocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    var onLocations: (([CLLocation]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onCollectingChanged: ((Bool) -> Void)?

    private let manager = CLLocationManager()
    private var wantsStart = false
    private var requestedAlways = false
    private var collecting = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var isCollecting: Bool { collecting }

    func start() {
        wantsStart = true
        switch manager.authorizationStatus {
        case .notDetermined:
            publish("Location permission required")
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Foreground collection must work even when the operator declines
            // Always authorization. A later screen-lock test can still be
            // upgraded to Always without sacrificing the primary GPS path.
            manager.startUpdatingLocation()
            collecting = true
            onCollectingChanged?(true)
            publish("Collecting in foreground; Always permission enables lock-screen capture")
            if !requestedAlways {
                requestedAlways = true
                manager.requestAlwaysAuthorization()
            }
        case .authorizedAlways:
            manager.startUpdatingLocation()
            collecting = true
            onCollectingChanged?(true)
            publish("Waiting for location")
        case .denied, .restricted:
            wantsStart = false
            collecting = false
            onCollectingChanged?(false)
            publish("Location permission denied")
        @unknown default:
            publish("Location authorization unavailable")
        }
    }

    func stop() {
        wantsStart = false
        manager.stopUpdatingLocation()
        collecting = false
        onCollectingChanged?(false)
        publish("Stopped")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if wantsStart { start() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        onLocations?(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        publish("Location unavailable; last fix retained")
    }

    private func publish(_ value: String) {
        onStatus?(value)
    }
}
