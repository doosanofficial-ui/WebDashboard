// Current iPhone product is local CAN/diagnostics, GPS and recording.
// Keep legacy configuration and queued data on disk without activating delivery.
enum TelemetryProductScope {
    static let allowsRemoteDelivery = false
}
