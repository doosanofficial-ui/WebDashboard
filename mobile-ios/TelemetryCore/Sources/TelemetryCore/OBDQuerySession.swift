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

public enum OBDQuerySupport: Equatable, Sendable {
    case unknown
    case supported
    case unsupported
}

/// An immutable observation made in the scheduler actor, immediately after its
/// support cache changes. Watching a query never adds it to the polling list.
public struct OBDQueryObservation: Equatable, Sendable {
    public let outcome: OBDQueryOutcome
    public let ordinal: UInt64
    public let supportByQueryID: [String: OBDQuerySupport]
    public let freshSupportQueryIDs: Set<String>
    public let timestamp: TimeInterval
}

/// Owns one diagnostic transport connection. It never starts passive monitor
/// mode and must not be used concurrently with ELM327Session on the same link.
public actor OBDQuerySession {
    private static let connectionTimeoutNanoseconds: UInt64 = 10_000_000_000

    public private(set) var state: OBDQuerySessionState = .disconnected
    public private(set) var lastError: OBDQuerySessionError?
    public private(set) var lastAuditError: DiagnosticAuditError?

    private let transport: any CANTransport
    private let sourceAdapter: String
    private let sourceTransport: String
    private let auditContext: DiagnosticAuditContext?
    private let onAudit: (@Sendable (DiagnosticAuditEvent) async -> Void)?
    private let onAuditError: (@Sendable (DiagnosticAuditError) async -> Void)?
    private var auditLedger: DiagnosticAuditLedger?
    private struct PendingResponse {
        let id: UUID
        let generation: UUID
        let continuation: CheckedContinuation<String, Error>
    }

    private var generation = UUID()
    private var startupTask: Task<Void, Error>?
    private var startupGeneration: UUID?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownID: UUID?
    private var stopRequested = false
    private var writeTasks: [UUID: Task<Void, Never>] = [:]
    private var readerTask: Task<Void, Never>?
    private var responseWaiter: PendingResponse?
    private var responseBuffer = Data()
    private var sequence: UInt64 = 0

    public init(
        transport: any CANTransport,
        sourceAdapter: String = "elm327",
        sourceTransport: String = "unknown",
        auditContext: DiagnosticAuditContext? = nil,
        onAudit: (@Sendable (DiagnosticAuditEvent) async -> Void)? = nil,
        onAuditError: (@Sendable (DiagnosticAuditError) async -> Void)? = nil
    ) {
        self.transport = transport
        self.sourceAdapter = sourceAdapter
        self.sourceTransport = sourceTransport
        self.auditContext = auditContext
        self.onAudit = onAudit
        self.onAuditError = onAuditError
        if let auditContext, onAudit != nil {
            auditLedger = DiagnosticAuditLedger(scope: .acquisition(connectionID: auditContext.connectionID))
        }
    }

    public func start() async throws {
        guard state == .disconnected, startupTask == nil, shutdownTask == nil,
              auditLedger?.isClosed != true else {
            throw OBDQuerySessionError.invalidState
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        state = .connecting
        lastError = nil
        let pending = Task { try await initialize(generation: currentGeneration) }
        startupTask = pending
        startupGeneration = currentGeneration
        defer {
            if startupGeneration == currentGeneration {
                startupTask = nil
                startupGeneration = nil
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await pending.value
            } onCancel: {
                pending.cancel()
            }
        } catch is CancellationError {
            if generation == currentGeneration {
                await stop()
            } else if startupGeneration == currentGeneration, let shutdownTask {
                await shutdownTask.value
            }
            throw CancellationError()
        } catch let error as OBDQuerySessionError {
            await failStart(error, generation: currentGeneration)
            throw error
        } catch {
            await failStart(.transport, generation: currentGeneration)
            throw OBDQuerySessionError.transport
        }
    }

    // The owned startup task only returns errors. Its caller performs cleanup,
    // so shutdown can await startup without startup awaiting its own shutdown.
    private func initialize(generation: UUID) async throws {
        try await connectWithTimeout()
        try requireActive(generation: generation)
        state = .initializing
        let incoming = await transport.incoming()
        try requireActive(generation: generation)
        readerTask = Task { [weak self] in
            do {
                for try await chunk in incoming {
                    guard !Task.isCancelled else { return }
                    await self?.ingest(chunk, generation: generation)
                }
                await self?.transitionToRecovery(.disconnected, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                await self?.transitionToRecovery(.transport, generation: generation)
            }
        }
        try await issue("AT H1\r", generation: generation)
        // Queries contain service/PID/DID only: ELM327 must insert the PCI
        // byte. H1 preserves raw CAN headers/PCI on received responses.
        try await issue("AT CAF1\r", generation: generation)
        try requireActive(generation: generation)
        state = .ready
    }

    public func stop() async {
        if let shutdownTask {
            stopRequested = true
            await closeAuditConnection()
            await shutdownTask.value
            return
        }
        guard state != .disconnected else { return }
        let closing = beginShutdown(finalState: .disconnected, error: .disconnected)
        await closeAuditConnection()
        await closing.value
    }

    public func query(_ query: OBDQueryDefinition) async throws -> OBDQueryResult {
        guard state == .ready, shutdownTask == nil else { throw OBDQuerySessionError.invalidState }
        let currentGeneration = generation
        let attemptID = UUID()
        state = .querying
        defer {
            if generation == currentGeneration, state == .querying { state = .ready }
        }

        do {
            if let auditContext {
                await appendAudit { try $0.queued(query: query, context: auditContext, at: Self.auditNow(), attemptID: attemptID) }
                try requireActive(generation: currentGeneration)
                await appendAudit { try $0.started(attemptID: attemptID, at: Self.auditNow()) }
                try requireActive(generation: currentGeneration)
            }
            try await issue("AT SH \(formatIdentifier(query.requestCANID, extended: query.isExtended))\r", generation: currentGeneration)
            try await issue("AT CRA \(formatIdentifier(query.responseCANID, extended: query.isExtended))\r", generation: currentGeneration)
            let text = try await exchange(Data(query.requestString.utf8), timeout: query.timeout,
                                          generation: currentGeneration, auditAttemptID: attemptID)
            try requireActive(generation: currentGeneration)
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
            await appendAudit { ledger in
                guard ledger.snapshot().contains(where: { $0.attemptID == attemptID && !$0.isTerminal }) else { return nil }
                return try ledger.succeeded(attemptID: attemptID, responseSequence: response.sequence,
                    responseReceivedAt: DiagnosticAuditTimestamp(epochSeconds: response.receivedAtEpoch,
                        monotonicNanoseconds: response.receivedAtMonotonicNanos), at: Self.auditNow())
            }
            return OBDQueryResult(queryID: query.id, response: response, signals: decoded)
        } catch let error as OBDQuerySessionError {
            if isRecoverableSessionFailure(error) {
                transitionToRecovery(error, generation: currentGeneration)
            }
            await finishAuditAttempt(attemptID, error: error, cancelled: Task.isCancelled)
            throw error
        } catch is CancellationError {
            await finishAuditAttempt(attemptID, error: .disconnected, cancelled: true)
            throw CancellationError()
        } catch {
            transitionToRecovery(.transport, generation: currentGeneration)
            await finishAuditAttempt(attemptID, error: .transport, cancelled: Task.isCancelled)
            throw OBDQuerySessionError.transport
        }
    }

    private func issue(_ command: String, generation: UUID) async throws {
        let response = try await exchange(Data(command.utf8), timeout: 1, generation: generation)
        let normalized = response.uppercased().replacingOccurrences(of: " ", with: "")
        if normalized.contains("BUFFERFULL") { throw OBDQuerySessionError.bufferFull }
        if normalized.contains("?") || !normalized.contains("OK") {
            throw OBDQuerySessionError.unsupportedCommand
        }
    }

    private func exchange(_ data: Data, timeout: Double, generation: UUID,
                          auditAttemptID: UUID? = nil) async throws -> String {
        try requireActive(generation: generation)
        guard responseWaiter == nil else { throw OBDQuerySessionError.invalidState }
        let exchangeID = UUID()
        let timeoutNanoseconds = UInt64(max(0.1, min(timeout, 30)) * 1_000_000_000)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.failPending(.timeout, exchangeID: exchangeID, generation: generation)
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard self.generation == generation, shutdownTask == nil, !Task.isCancelled else {
                    continuation.resume(throwing: OBDQuerySessionError.disconnected)
                    return
                }
                responseWaiter = PendingResponse(id: exchangeID, generation: generation, continuation: continuation)
                let writing = Task { [weak self, transport] in
                    do {
                        guard await self?.canWrite(exchangeID: exchangeID, generation: generation) == true else {
                            throw CancellationError()
                        }
                        try Task.checkCancellation()
                        if let auditAttemptID {
                            await self?.appendAudit { try $0.transportWriteStarted(attemptID: auditAttemptID, at: Self.auditNow()) }
                            // An async sink can admit Stop. Never send after
                            // that suspension without rechecking ownership.
                            guard await self?.canWrite(exchangeID: exchangeID, generation: generation) == true else {
                                throw CancellationError()
                            }
                            try Task.checkCancellation()
                        }
                        try await transport.write(data)
                        if let auditAttemptID {
                            await self?.appendAudit { try $0.transportWriteCompleted(attemptID: auditAttemptID, at: Self.auditNow()) }
                        }
                    } catch is CancellationError {
                        await self?.failPending(.disconnected, exchangeID: exchangeID, generation: generation)
                        await self?.auditWriteFailed(auditAttemptID, code: "cancelled")
                    } catch {
                        await self?.failPending(.transport, exchangeID: exchangeID, generation: generation)
                        await self?.auditWriteFailed(auditAttemptID, code: "transport")
                    }
                    await self?.finishWrite(exchangeID)
                }
                writeTasks[exchangeID] = writing
            }
        }, onCancel: { [weak self] in
            Task { await self?.failPending(.disconnected, exchangeID: exchangeID, generation: generation) }
        })
    }

    private func requireActive(generation: UUID) throws {
        try Task.checkCancellation()
        guard self.generation == generation, shutdownTask == nil, state != .disconnected else {
            throw OBDQuerySessionError.disconnected
        }
    }

    private func canWrite(exchangeID: UUID, generation: UUID) -> Bool {
        self.generation == generation && shutdownTask == nil && responseWaiter?.id == exchangeID
    }

    private func finishWrite(_ exchangeID: UUID) {
        writeTasks.removeValue(forKey: exchangeID)
    }

    private static func auditNow() throws -> DiagnosticAuditTimestamp {
        try DiagnosticAuditTimestamp(epochSeconds: Date().timeIntervalSince1970,
                                     monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    private func appendAudit(_ update: (inout DiagnosticAuditLedger) throws -> DiagnosticAuditEvent?) async {
        guard var ledger = auditLedger else { return }
        do {
            let event = try update(&ledger)
            auditLedger = ledger // publish before any actor reentrancy
            if let event { await onAudit?(event) }
        } catch let error as DiagnosticAuditError {
            lastAuditError = error
            await onAuditError?(error)
        } catch { // The pure ledger and timestamp constructor use only this error type.
            lastAuditError = .invalidTimestamp
            await onAuditError?(.invalidTimestamp)
        }
    }

    private func auditWriteFailed(_ id: UUID?, code: String) async {
        guard let id else { return }
        await appendAudit { ledger in
            guard let attempt = ledger.snapshot().first(where: { $0.attemptID == id }),
                  attempt.currentWriteDisposition == .inFlight else { return nil }
            return try ledger.transportWriteFailed(attemptID: id, reasonCode: code, at: Self.auditNow())
        }
    }

    private func finishAuditAttempt(_ id: UUID, error: OBDQuerySessionError, cancelled: Bool) async {
        await appendAudit { ledger in
            guard ledger.snapshot().contains(where: { $0.attemptID == id && !$0.isTerminal }) else { return nil }
            let code = DiagnosticQueryFailure(queryID: "", error: error).errorCode
            return try cancelled
                ? ledger.cancelled(attemptID: id, reasonCode: code, at: Self.auditNow())
                : ledger.failed(attemptID: id, reasonCode: code, at: Self.auditNow())
        }
    }

    private func closeAuditConnection() async {
        guard let context = auditContext, var ledger = auditLedger, !ledger.isClosed else { return }
        do {
            let events = try ledger.stopConnection(context.connectionID, at: Self.auditNow())
            auditLedger = ledger
            for event in events { await onAudit?(event) }
        } catch let error as DiagnosticAuditError {
            lastAuditError = error
            await onAuditError?(error)
        } catch {
            lastAuditError = .invalidTimestamp
            await onAuditError?(.invalidTimestamp)
        }
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

    private func ingest(_ chunk: Data, generation: UUID) {
        guard self.generation == generation, shutdownTask == nil, state != .disconnected else { return }
        guard chunk.allSatisfy(Self.isELMByte) else {
            transitionToRecovery(.transport, generation: generation)
            return
        }
        responseBuffer.append(chunk)
        guard responseBuffer.count <= 4096 else {
            transitionToRecovery(.bufferFull, generation: generation)
            return
        }
        while let prompt = responseBuffer.firstIndex(of: 62) {
            let response = String(decoding: responseBuffer.prefix(upTo: prompt), as: UTF8.self)
            responseBuffer.removeSubrange(...prompt)
            guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let responseWaiter else { continue }
            self.responseWaiter = nil
            responseWaiter.continuation.resume(returning: response)
        }
    }

    private func failPending(_ error: OBDQuerySessionError, exchangeID: UUID? = nil, generation: UUID? = nil) {
        guard let responseWaiter else { return }
        if let exchangeID, responseWaiter.id != exchangeID { return }
        if let generation, self.generation != generation || responseWaiter.generation != generation { return }
        self.responseWaiter = nil
        responseWaiter.continuation.resume(throwing: error)
    }

    private func failStart(_ error: OBDQuerySessionError, generation: UUID) async {
        guard self.generation == generation else {
            // The reader may already have begun this startup's cleanup. Join
            // it outside the initialization task before returning its error.
            if startupGeneration == generation, let shutdownTask {
                await shutdownTask.value
            }
            return
        }
        lastError = error
        await beginShutdown(finalState: .error, error: error).value
    }

    private func transitionToRecovery(_ error: OBDQuerySessionError, generation: UUID) {
        guard self.generation == generation, state != .disconnected, state != .recovering else { return }
        let finalState: OBDQuerySessionState = state == .initializing || state == .connecting ? .error : .recovering
        lastError = error
        state = .recovering
        _ = beginShutdown(finalState: finalState, error: error)
    }

    /// Owns every close and joins all work that could still use the transport.
    /// A concurrent Stop joins this same task; its return cannot expose a new
    /// connection to a close or write left over from the previous run.
    private func beginShutdown(finalState: OBDQuerySessionState, error: OBDQuerySessionError) -> Task<Void, Never> {
        if let shutdownTask {
            if finalState == .disconnected { stopRequested = true }
            return shutdownTask
        }
        let id = UUID()
        shutdownID = id
        generation = UUID()
        stopRequested = finalState == .disconnected
        let startup = startupTask
        let reader = readerTask
        let writes = Array(writeTasks.values)
        startup?.cancel()
        reader?.cancel()
        for write in writes { write.cancel() }
        failPending(error)
        let drain = Task { [weak self, transport] in
            // Close first so a transport waiting in connect/write can unwind.
            await transport.close()
            _ = await startup?.result
            await reader?.value
            for write in writes { await write.value }
            await self?.finishShutdown(id: id, finalState: finalState)
        }
        shutdownTask = drain
        return drain
    }

    private func finishShutdown(id: UUID, finalState: OBDQuerySessionState) {
        guard shutdownID == id else { return }
        startupTask = nil
        startupGeneration = nil
        readerTask = nil
        writeTasks.removeAll()
        responseBuffer.removeAll(keepingCapacity: false)
        state = stopRequested ? .disconnected : finalState
        stopRequested = false
        shutdownID = nil
        shutdownTask = nil
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
    private struct Target: Hashable {
        let requestCANID: UInt32
        let responseCANID: UInt32
        let isExtended: Bool

        init(_ query: OBDQueryDefinition) {
            requestCANID = query.requestCANID
            responseCANID = query.responseCANID
            isExtended = query.isExtended
        }
    }

    private let session: OBDQuerySession
    private let observedQueries: [OBDQueryDefinition]?
    private let onObservation: (@Sendable (OBDQueryObservation) -> Void)?
    private var watchedQueries: [OBDQueryDefinition] = []
    private var observationOrdinal: UInt64 = 0
    private var task: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private var continuation: AsyncStream<OBDQueryOutcome>.Continuation?
    private var supportedPIDPages: [Target: [UInt8: UInt32]] = [:]
    private var generation = UUID()
    private var isStarting = false

    public init(session: OBDQuerySession,
                observedQueries: [OBDQueryDefinition]? = nil,
                onObservation: (@Sendable (OBDQueryObservation) -> Void)? = nil) {
        self.session = session
        self.observedQueries = observedQueries
        self.onObservation = onObservation
    }

    /// Only a directly observed, same-target Mode 01 page proves support.
    /// Unknown queries retain normal polling/error handling, including queries
    /// before a bitmap in an imported profile. No discovery queries are added.
    public func support(for query: OBDQueryDefinition) -> OBDQuerySupport {
        guard query.service == .mode01, let pid = UInt8(query.command, radix: 16), pid > 0 else {
            return .unknown
        }
        let page = UInt8(((Int(pid) - 1) / 32) * 32)
        guard let mask = supportedPIDPages[Target(query)]?[page] else { return .unknown }
        let bit = UInt32(1) << (32 - (Int(pid) - Int(page)))
        return mask & bit == 0 ? .unsupported : .supported
    }

    public func start(queries: [OBDQueryDefinition]) async throws -> AsyncStream<OBDQueryOutcome> {
        guard !queries.isEmpty, task == nil, shutdown == nil, !isStarting else {
            throw OBDQuerySessionError.invalidState
        }
        let watched = onObservation == nil ? [] : observedQueries ?? queries
        guard Set(watched.map(\.id)).count == watched.count,
              queries.allSatisfy({ query in
                  watched.first(where: { $0.id == query.id }).map { $0 == query } ?? true
              }) else {
            throw OBDQuerySessionError.invalidState
        }
        let currentGeneration = UUID()
        isStarting = true
        defer {
            if generation == currentGeneration { isStarting = false }
        }
        generation = currentGeneration
        supportedPIDPages.removeAll()
        watchedQueries = watched
        observationOrdinal = 0
        try await session.start()
        guard generation == currentGeneration else {
            throw OBDQuerySessionError.disconnected
        }
        let pair = AsyncStream<OBDQueryOutcome>.makeStream()
        continuation = pair.continuation
        task = Task { [weak self, session] in
            var terminate = false
            while !Task.isCancelled && !terminate {
                for query in queries {
                    guard !Task.isCancelled else { break }
                    guard await self?.generation == currentGeneration else { terminate = true; break }
                    // Explicitly configured bitmap queries always remain eligible
                    // for refresh, even when an earlier continuation bit is clear.
                    if Self.bitmapPage(for: query) == nil {
                        if await self?.support(for: query) == .unsupported { continue }
                    }
                    do {
                        let result = try await session.query(query)
                        await self?.yield(.success(result), for: query, generation: currentGeneration)
                    } catch let error as OBDQuerySessionError {
                        await self?.yield(.failure(queryID: query.id, error: error), for: query, generation: currentGeneration)
                        terminate = Self.shouldTerminate(after: error)
                        if terminate { break }
                    } catch is CancellationError {
                        break
                    } catch {
                        await self?.yield(.failure(queryID: query.id, error: .transport), for: query, generation: currentGeneration)
                    }
                    do {
                        try await Task.sleep(nanoseconds: UInt64(query.pollInterval * 1_000_000_000))
                    } catch {
                        break
                    }
                }
            }
            await self?.finishStream(generation: currentGeneration)
        }
        return pair.stream
    }

    public func stop() async {
        if let shutdown { await shutdown.value; return }
        let currentGeneration = UUID()
        generation = currentGeneration
        let pending = task
        pending?.cancel()
        supportedPIDPages.removeAll()
        finishStream()
        let drain = Task { [weak self, session] in
            await session.stop()
            await pending?.value
            await self?.finishStop(generation: currentGeneration)
        }
        shutdown = drain
        await drain.value
    }

    private func finishStop(generation: UUID) {
        guard self.generation == generation else { return }
        task = nil
        isStarting = false
        shutdown = nil
    }

    private func yield(_ outcome: OBDQueryOutcome, for query: OBDQueryDefinition, generation: UUID) {
        guard self.generation == generation else { return }
        var freshSupportQueryIDs = Set<String>()
        if let page = Self.bitmapPage(for: query) {
            let mask: UInt32?
            if case .success(let result) = outcome, result.response.payload.count == 4 {
                mask = result.response.payload.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            } else {
                // Failed or malformed refreshes restore unknown; NO DATA is not
                // evidence that a standard PID or manufacturer DID is unsupported.
                mask = nil
            }
            supportedPIDPages[Target(query), default: [:]][page] = mask
            if mask != nil {
                freshSupportQueryIDs = Set(watchedQueries.compactMap { watched in
                    guard Target(watched) == Target(query), watched.service == .mode01,
                          let pid = UInt8(watched.command, radix: 16), pid > 0,
                          UInt8(((Int(pid) - 1) / 32) * 32) == page else { return nil }
                    return watched.id
                })
            }
        }
        if let onObservation {
            observationOrdinal += 1
            let timestamp: TimeInterval
            if case .success(let result) = outcome { timestamp = result.response.receivedAtEpoch }
            else { timestamp = Date().timeIntervalSince1970 }
            // No suspension between mutation, snapshot and enqueue: consumers
            // cannot accidentally attribute a later bitmap to this result.
            onObservation(OBDQueryObservation(outcome: outcome, ordinal: observationOrdinal,
                supportByQueryID: Dictionary(uniqueKeysWithValues: watchedQueries.map { ($0.id, support(for: $0)) }),
                freshSupportQueryIDs: freshSupportQueryIDs, timestamp: timestamp))
        }
        continuation?.yield(outcome)
    }

    private func finishStream(generation: UUID? = nil) {
        if let generation, self.generation != generation { return }
        continuation?.finish()
        continuation = nil
    }

    private static func bitmapPage(for query: OBDQueryDefinition) -> UInt8? {
        guard query.service == .mode01, let pid = UInt8(query.command, radix: 16),
              pid.isMultiple(of: 32) else { return nil }
        return pid
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
