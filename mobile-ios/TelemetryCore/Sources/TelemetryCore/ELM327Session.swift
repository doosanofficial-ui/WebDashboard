import Foundation

public enum ELM327SessionError: Error, Equatable, Sendable {
    case transport
    case timeout
    case unsupportedCommand
    case bufferFull
    case malformedFrame
    case disconnected
    case invalidState
}

public enum ELM327State: Equatable, Sendable {
    case disconnected
    case connecting
    case initializing
    case ready
    case monitoring
    case recovering
}

public enum ELM327Command: String, CaseIterable, Sendable {
    case headersOn = "AT H1\r"
    case autoFormattingOff = "AT CAF0\r"
    case silentMonitoringOn = "AT CSM1\r"
    case monitorAll = "AT MA\r"
    case stopMonitoring = " "

    public var data: Data { Data(rawValue.utf8) }
    public var waitsForPrompt: Bool { self != .monitorAll && self != .stopMonitoring }
}

public actor ELM327Session {
    private static let connectionTimeoutNanoseconds: UInt64 = 10_000_000_000

    public private(set) var state: ELM327State = .disconnected
    public private(set) var lastError: ELM327SessionError?

    private let transport: any CANTransport
    private let sourceAdapter: String
    private let sourceTransport: String
    private let frameStream: AsyncStream<CANFrame>
    private let frameContinuation: AsyncStream<CANFrame>.Continuation
    private var readerTask: Task<Void, Never>?
    private var responseWaiter: CheckedContinuation<String, Error>?
    private var responseBuffer = Data()
    private var monitorBuffer = Data()
    private var sequence: UInt64 = 0

    public init(
        transport: any CANTransport,
        sourceAdapter: String = "elm327",
        sourceTransport: String = "unknown"
    ) {
        self.transport = transport
        self.sourceAdapter = sourceAdapter
        self.sourceTransport = sourceTransport
        let pair = AsyncStream<CANFrame>.makeStream()
        frameStream = pair.stream
        frameContinuation = pair.continuation
    }

    public func frames() -> AsyncStream<CANFrame> {
        frameStream
    }

    public func start() async throws {
        guard state == .disconnected else { throw ELM327SessionError.invalidState }
        lastError = nil
        state = .connecting
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
                } catch {
                    await self?.transitionToRecovery(.transport)
                }
            }
            try await issue(.headersOn)
            try await issue(.autoFormattingOff)
            try await issue(.silentMonitoringOn)
            state = .ready
            try await transport.write(ELM327Command.monitorAll.data)
            state = .monitoring
        } catch is CancellationError {
            await transport.close()
            state = .disconnected
            frameContinuation.finish()
            throw CancellationError()
        } catch let error as ELM327SessionError {
            transitionToRecovery(error)
            throw error
        } catch {
            transitionToRecovery(.transport)
            throw ELM327SessionError.transport
        }
    }

    public func stop() async {
        guard state != .disconnected else { return }
        if state == .monitoring {
            try? await transport.write(ELM327Command.stopMonitoring.data)
        }
        readerTask?.cancel()
        readerTask = nil
        responseWaiter?.resume(throwing: ELM327SessionError.disconnected)
        responseWaiter = nil
        await transport.close()
        state = .disconnected
        frameContinuation.finish()
    }

    private func issue(_ command: ELM327Command) async throws {
        guard command.waitsForPrompt else {
            try await transport.write(command.data)
            return
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.failPendingResponse(.timeout)
        }
        defer { timeoutTask.cancel() }
        let response: String = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                responseWaiter = continuation
                if Task.isCancelled {
                    responseWaiter = nil
                    continuation.resume(throwing: ELM327SessionError.disconnected)
                    return
                }
                Task { [weak self, transport] in
                    do {
                        try await transport.write(command.data)
                    } catch {
                        await self?.failPendingResponse(.transport)
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { await self?.failPendingResponse(.disconnected) }
        })
        let normalized = response.uppercased().replacingOccurrences(of: " ", with: "")
        if normalized.contains("BUFFERFULL") {
            throw ELM327SessionError.bufferFull
        }
        if normalized.contains("?") || !normalized.contains("OK") {
            throw ELM327SessionError.unsupportedCommand
        }
    }

    private func failPendingResponse(_ error: ELM327SessionError) {
        guard let responseWaiter else { return }
        self.responseWaiter = nil
        responseWaiter.resume(throwing: error)
    }

    private func connectWithTimeout() async throws {
        let transport = transport
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await transport.connect()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.connectionTimeoutNanoseconds)
                throw ELM327SessionError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()!
        }
    }

    private func ingest(_ chunk: Data) {
        guard state != .recovering && state != .disconnected else { return }
        if state == .monitoring {
            monitorBuffer.append(chunk)
            guard monitorBuffer.count <= 4096 else {
                transitionToRecovery(.malformedFrame)
                return
            }
            while let terminator = monitorBuffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let line = monitorBuffer.prefix(upTo: terminator)
                monitorBuffer.removeSubrange(...terminator)
                while let first = monitorBuffer.first, first == 10 || first == 13 {
                    monitorBuffer.removeFirst()
                }
                let text = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                handleMonitorLine(text)
            }
            return
        }

        responseBuffer.append(chunk)
        guard responseBuffer.count <= 4096 else {
            transitionToRecovery(.malformedFrame)
            return
        }
        guard let prompt = responseBuffer.firstIndex(of: 62) else { return }
        let response = String(decoding: responseBuffer.prefix(upTo: prompt), as: UTF8.self)
        responseBuffer.removeSubrange(...prompt)
        guard let responseWaiter else { return }
        self.responseWaiter = nil
        responseWaiter.resume(returning: response)
    }

    private func handleMonitorLine(_ line: String) {
        let normalized = line.uppercased().replacingOccurrences(of: " ", with: "")
        switch normalized {
        case "BUFFERFULL":
            transitionToRecovery(.bufferFull)
        case "?":
            transitionToRecovery(.unsupportedCommand)
        case "STOPPED", "CANERROR", "BUSERROR":
            transitionToRecovery(.transport)
        default:
            do {
                let frame = try parseFrame(line)
                frameContinuation.yield(frame)
            } catch {
                transitionToRecovery(.malformedFrame)
            }
        }
    }

    private func parseFrame(_ line: String) throws -> CANFrame {
        let tokens = line.split { $0 == " " || $0 == "\t" }
        guard let header = tokens.first,
              (header.count == 3 || header.count == 8),
              let canID = UInt32(header, radix: 16) else {
            throw ELM327SessionError.malformedFrame
        }
        let isExtended = header.count == 8
        let payloadTokens = tokens.dropFirst()
        guard !payloadTokens.isEmpty, payloadTokens.count <= 8 else {
            throw ELM327SessionError.malformedFrame
        }
        var payload: [UInt8] = []
        payload.reserveCapacity(payloadTokens.count)
        for token in payloadTokens {
            guard token.count == 2, let byte = UInt8(token, radix: 16) else {
                throw ELM327SessionError.malformedFrame
            }
            payload.append(byte)
        }
        sequence += 1
        return try CANFrame(
            receivedAtEpoch: Date().timeIntervalSince1970,
            receivedAtMonotonicNanos: DispatchTime.now().uptimeNanoseconds,
            canID: canID,
            isExtended: isExtended,
            dlc: payload.count,
            payload: payload,
            sourceAdapter: sourceAdapter,
            sourceTransport: sourceTransport,
            sequence: sequence
        )
    }

    private func transitionToRecovery(_ error: ELM327SessionError) {
        guard state != .disconnected && state != .recovering else { return }
        lastError = error
        state = .recovering
        responseWaiter?.resume(throwing: error)
        responseWaiter = nil
        readerTask?.cancel()
        Task { [transport] in await transport.close() }
    }
}
