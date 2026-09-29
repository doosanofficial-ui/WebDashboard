import Foundation

public enum OBDQuerySessionState: Equatable, Sendable {
    case disconnected
    case connecting
    case initializing
    case ready
    case querying
    case recovering
    case error
}

public enum OBDQuerySessionError: Error, Equatable, Sendable {
    case invalidState
    case transport
    case timeout
    case unsupportedCommand
    case bufferFull
    case disconnected
    case response(OBDResponseError)
    case decode(OBDSignalDecodeError)
}

public struct OBDQueryResult: Equatable, Sendable {
    public let queryID: String
    public let response: OBDResponse
    public let signals: [DecodedOBDSignal]

    public init(queryID: String, response: OBDResponse, signals: [DecodedOBDSignal]) {
        self.queryID = queryID
        self.response = response
        self.signals = signals
    }
}

public enum OBDQueryOutcome: Equatable, Sendable {
    case success(OBDQueryResult)
    case failure(queryID: String, error: OBDQuerySessionError)
}

/// Owns one diagnostic transport connection. It never starts passive monitor
/// mode and must not be used concurrently with ELM327Session on the same link.
public actor OBDQuerySession {
    private static let connectionTimeoutNanoseconds: UInt64 = 10_000_000_000

    public private(set) var state: OBDQuerySessionState = .disconnected
    public private(set) var lastError: OBDQuerySessionError?

    private let transport: any CANTransport
    private let sourceAdapter: String
    private let sourceTransport: String
    private var readerTask: Task<Void, Never>?
    private var responseWaiter: CheckedContinuation<String, Error>?
    private var responseBuffer = Data()
    private var sequence: UInt64 = 0

    public init(
        transport: any CANTransport,
        sourceAdapter: String = "elm327",
        sourceTransport: String = "unknown"
    ) {
        self.transport = transport
        self.sourceAdapter = sourceAdapter
        self.sourceTransport = sourceTransport
    }

    public func start() async throws {
        guard state == .disconnected else { throw OBDQuerySessionError.invalidState }
        state = .connecting
        lastError = nil
        do {
            try await connectWithTimeout()
            state = .initializing
            let incoming = await transport.incoming()
            readerTask = Task { [weak self] in
                do {
                    for try await chunk in incoming {
                        await self?.ingest(chunk)
                    }
                    await self?.transitionToRecovery(.disconnected)
                } catch is CancellationError {
                    return
                } catch {
                    await self?.transitionToRecovery(.transport)
                }
            }
            try await issue("AT H1\r")
            try await issue("AT CAF0\r")
            state = .ready
        } catch is CancellationError {
            await stop()
            throw CancellationError()
        } catch let error as OBDQuerySessionError {
            await failStart(error)
            throw error
        } catch {
            await failStart(.transport)
            throw OBDQuerySessionError.transport
        }
    }

    public func stop() async {
        guard state != .disconnected else { return }
        responseWaiter?.resume(throwing: OBDQuerySessionError.disconnected)
        responseWaiter = nil
        readerTask?.cancel()
        readerTask = nil
        await transport.close()
        responseBuffer.removeAll(keepingCapacity: false)
        state = .disconnected
    }

    public func query(_ query: OBDQueryDefinition) async throws -> OBDQueryResult {
        guard state == .ready else { throw OBDQuerySessionError.invalidState }
        state = .querying
        defer {
            if state == .querying { state = .ready }
        }

        do {
            try await issue("AT SH \(formatIdentifier(query.requestCANID, extended: query.isExtended))\r")
            try await issue("AT CRA \(formatIdentifier(query.responseCANID, extended: query.isExtended))\r")
            let text = try await exchange(Data(query.requestString.utf8), timeout: query.timeout)
            let normalized = text.uppercased().replacingOccurrences(of: " ", with: "")
            if normalized.contains("BUFFERFULL") { throw OBDQuerySessionError.bufferFull }
            if normalized == "?" { throw OBDQuerySessionError.unsupportedCommand }
            sequence += 1
            let response: OBDResponse
            do {
                response = try OBDResponseParser.parse(
                    text,
                    for: query,
                    receivedAtEpoch: Date().timeIntervalSince1970,
                    receivedAtMonotonicNanos: DispatchTime.now().uptimeNanoseconds,
                    sequence: sequence,
                    sourceAdapter: sourceAdapter,
                    sourceTransport: sourceTransport
                )
            } catch let error as OBDResponseError {
                throw OBDQuerySessionError.response(error)
            }
            var decoded: [DecodedOBDSignal] = []
            decoded.reserveCapacity(query.signals.count)
            for signal in query.signals {
                do {
                    decoded.append(try OBDSignalDecoder.decode(signal, response: response))
                } catch let error as OBDSignalDecodeError {
                    throw OBDQuerySessionError.decode(error)
                }
            }
            return OBDQueryResult(queryID: query.id, response: response, signals: decoded)
        } catch let error as OBDQuerySessionError {
            if isRecoverableSessionFailure(error) {
                transitionToRecovery(error)
            }
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            transitionToRecovery(.transport)
            throw OBDQuerySessionError.transport
        }
    }

    private func issue(_ command: String) async throws {
        let response = try await exchange(Data(command.utf8), timeout: 1)
        let normalized = response.uppercased().replacingOccurrences(of: " ", with: "")
        if normalized.contains("BUFFERFULL") { throw OBDQuerySessionError.bufferFull }
        if normalized.contains("?") || !normalized.contains("OK") {
            throw OBDQuerySessionError.unsupportedCommand
        }
    }

    private func exchange(_ data: Data, timeout: Double) async throws -> String {
        guard responseWaiter == nil else { throw OBDQuerySessionError.invalidState }
        let timeoutNanoseconds = UInt64(max(0.1, min(timeout, 30)) * 1_000_000_000)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.failPending(.timeout)
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                responseWaiter = continuation
                if Task.isCancelled {
                    responseWaiter = nil
                    continuation.resume(throwing: OBDQuerySessionError.disconnected)
                    return
                }
                Task { [weak self, transport] in
                    do {
                        try await transport.write(data)
                    } catch {
                        await self?.failPending(.transport)
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { await self?.failPending(.disconnected) }
        })
    }

    private func connectWithTimeout() async throws {
        let transport = transport
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await transport.connect() }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.connectionTimeoutNanoseconds)
                throw OBDQuerySessionError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()!
        }
    }

    private func ingest(_ chunk: Data) {
        guard state != .disconnected else { return }
        guard chunk.allSatisfy(Self.isELMByte) else {
            transitionToRecovery(.transport)
            return
        }
        responseBuffer.append(chunk)
        guard responseBuffer.count <= 4096 else {
            transitionToRecovery(.bufferFull)
            return
        }
        while let prompt = responseBuffer.firstIndex(of: 62) {
            let response = String(decoding: responseBuffer.prefix(upTo: prompt), as: UTF8.self)
            responseBuffer.removeSubrange(...prompt)
            guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let responseWaiter else { continue }
            self.responseWaiter = nil
            responseWaiter.resume(returning: response)
        }
    }

    private func failPending(_ error: OBDQuerySessionError) {
        guard let responseWaiter else { return }
        self.responseWaiter = nil
        responseWaiter.resume(throwing: error)
    }

    private func failStart(_ error: OBDQuerySessionError) async {
        lastError = error
        await transport.close()
        readerTask?.cancel()
        readerTask = nil
        responseWaiter = nil
        state = .error
    }

    private func transitionToRecovery(_ error: OBDQuerySessionError) {
        guard state != .disconnected && state != .recovering else { return }
        lastError = error
        state = .recovering
        failPending(error)
        readerTask?.cancel()
        Task { [transport] in await transport.close() }
    }

    private func isRecoverableSessionFailure(_ error: OBDQuerySessionError) -> Bool {
        switch error {
        case .response(.noData), .response(.negativeResponse): return false
        case .response: return true
        case .decode: return false
        case .invalidState: return false
        default: return true
        }
    }

    private static func isELMByte(_ byte: UInt8) -> Bool {
        (32...126).contains(byte) || byte == 9 || byte == 10 || byte == 13
    }

    private func formatIdentifier(_ id: UInt32, extended: Bool) -> String {
        String(format: extended ? "%08X" : "%03X", id)
    }
}

/// Polls definitions sequentially on a single diagnostic session. Failure of
/// one optional manufacturer query is emitted as data and does not stop the
/// remaining candidates.
public actor OBDQueryScheduler {
    private let session: OBDQuerySession
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<OBDQueryOutcome>.Continuation?

    public init(session: OBDQuerySession) {
        self.session = session
    }

    public func start(queries: [OBDQueryDefinition]) async throws -> AsyncStream<OBDQueryOutcome> {
        guard !queries.isEmpty, task == nil else { throw OBDQuerySessionError.invalidState }
        try await session.start()
        let pair = AsyncStream<OBDQueryOutcome>.makeStream()
        continuation = pair.continuation
        task = Task { [weak self, session] in
            var terminate = false
            while !Task.isCancelled && !terminate {
                for query in queries {
                    guard !Task.isCancelled else { break }
                    do {
                        let result = try await session.query(query)
                        await self?.yield(.success(result))
                    } catch let error as OBDQuerySessionError {
                        await self?.yield(.failure(queryID: query.id, error: error))
                        terminate = Self.shouldTerminate(after: error)
                        if terminate { break }
                    } catch is CancellationError {
                        break
                    } catch {
                        await self?.yield(.failure(queryID: query.id, error: .transport))
                    }
                    do {
                        try await Task.sleep(nanoseconds: UInt64(query.pollInterval * 1_000_000_000))
                    } catch {
                        break
                    }
                }
            }
            await self?.finishStream()
        }
        return pair.stream
    }

    public func stop() async {
        task?.cancel()
        task = nil
        finishStream()
        await session.stop()
    }

    private func yield(_ outcome: OBDQueryOutcome) {
        continuation?.yield(outcome)
    }

    private func finishStream() {
        continuation?.finish()
        continuation = nil
    }

    private static func shouldTerminate(after error: OBDQuerySessionError) -> Bool {
        switch error {
        case .response(.noData), .response(.negativeResponse), .decode:
            return false
        default:
            return true
        }
    }
}
