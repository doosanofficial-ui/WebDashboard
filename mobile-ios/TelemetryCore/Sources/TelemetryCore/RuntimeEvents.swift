import Foundation

public enum AdapterRuntimeEvent: String, Equatable, Sendable {
    case starting = "adapter_starting"
    case monitoring = "adapter_monitoring"
    case reconnecting = "adapter_reconnecting"
    case disconnected = "adapter_disconnected"
    case error = "adapter_error"

    public init(state: String) {
        let value = state.lowercased()
        if value.contains("reconnect") || value.contains("recover") {
            self = .reconnecting
        } else if value.contains("monitoring") {
            self = .monitoring
        } else if value.contains("starting") || value.contains("connecting") {
            self = .starting
        } else if value.contains("disconnect") || value.contains("stopped") {
            self = .disconnected
        } else {
            self = .error
        }
    }
}
