import Foundation
import Network
import TelemetryCore

enum WiFiTransportError: Error, Equatable {
    case invalidPort
    case connectionFailed
    case notConnected
}

/// TCP transport for an observed Wi-Fi ELM profile or a future local bridge.
@MainActor
final class WiFiTransport: CANTransport {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "local.webdashboard.wifi-transport")
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var closed = false

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw WiFiTransportError.invalidPort
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    }

    func incoming() async -> AsyncThrowingStream<Data, Error> { stream }

    func connect() async throws {
        if isReady { return }
        closed = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handle(state) }
            }
            connection.start(queue: queue)
        }
    }

    func write(_ data: Data) async throws {
        guard isReady, !closed else { throw WiFiTransportError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func close() async {
        closed = true
        isReady = false
        connection.cancel()
        connectContinuation?.resume(throwing: WiFiTransportError.connectionFailed)
        connectContinuation = nil
        continuation.finish()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            connectContinuation?.resume()
            connectContinuation = nil
            receive()
        case .failed, .cancelled:
            isReady = false
            let error = WiFiTransportError.connectionFailed
            connectContinuation?.resume(throwing: error)
            connectContinuation = nil
            if !closed { continuation.finish(throwing: error) }
        default:
            break
        }
    }

    private func receive() {
        guard isReady, !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.continuation.finish(throwing: error)
                    return
                }
                if let data, !data.isEmpty { self.continuation.yield(data) }
                if isComplete { self.continuation.finish() }
                else { self.receive() }
            }
        }
    }
}
