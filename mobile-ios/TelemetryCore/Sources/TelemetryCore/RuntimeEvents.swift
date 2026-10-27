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

/// Query identity remains opaque data inside the existing SYSTEM event name.
/// Display wording does not define the stable recording error code.
public struct DiagnosticQueryFailure: Equatable, Sendable {
    public let queryID: String
    public let errorCode: String
    public var recordingName: String { "diagnostic_query_failed:\(queryID):\(errorCode)" }

    public init(queryID: String, error: OBDQuerySessionError) {
        self.queryID = queryID
        switch error {
        case .invalidState: errorCode = "invalid_state"
        case .transport: errorCode = "transport"
        case .timeout: errorCode = "timeout"
        case .unsupportedCommand: errorCode = "unsupported_command"
        case .bufferFull: errorCode = "buffer_full"
        case .disconnected: errorCode = "disconnected"
        case .response(.noData): errorCode = "no_data"
        case .response(.bufferFull): errorCode = "buffer_full"
        case .response(.negativeResponse(let code)): errorCode = String(format: "negative_response_%02X", code)
        case .response: errorCode = "malformed_response"
        case .decode(.payloadTooShort): errorCode = "payload_too_short"
        case .decode(.valueOutOfRange): errorCode = "value_out_of_range"
        }
    }
}
