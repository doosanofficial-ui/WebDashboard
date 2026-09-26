import Foundation

public enum CANTransportError: Error, Equatable, Sendable {
    case notConnected
    case writeFailed
}

public protocol CANTransport: Sendable {
    func incoming() async -> AsyncThrowingStream<Data, Error>
    func connect() async throws
    func write(_ data: Data) async throws
    func close() async
}

/// Deterministic transport used by Core tests and replay adapters.
public actor MockCANTransport: CANTransport {
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false
    private var recordedWrites: [String] = []

    public init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    public func incoming() async -> AsyncThrowingStream<Data, Error> {
        stream
    }

    public func connect() async throws {
        connected = true
    }

    public func write(_ data: Data) async throws {
        guard connected else { throw CANTransportError.notConnected }
        recordedWrites.append(String(decoding: data, as: UTF8.self))
    }

    public func close() async {
        connected = false
    }

    public func push(_ data: Data) {
        continuation.yield(data)
    }

    public func finish() {
        continuation.finish()
    }

    public func writes() -> [String] {
        recordedWrites
    }
}
