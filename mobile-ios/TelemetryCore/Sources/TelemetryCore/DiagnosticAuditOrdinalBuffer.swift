import Foundation

public enum DiagnosticAuditOrdinalBufferError: Error, Equatable, Sendable {
    case closed
    case staleQueuedEvent(UUID)
    case sameTimestampQueueLimitExceeded(UUID)
    case maximumTrackedAttemptsExceeded(UUID)
    case maximumTrackedConnectionsExceeded(UUID)
    case maximumPendingEventsExceeded(UUID)
}

/// Reorders actor-produced audit events after asynchronous delivery to a recording owner.
/// It stores no ledger state and emits only a contiguous ordinal prefix for each attempt.
public struct DiagnosticAuditOrdinalBuffer: Sendable {
    public let startedAt: DiagnosticAuditTimestamp
    public let maximumTrackedAttempts: Int
    public let maximumPendingEventsPerAttempt: Int

    public private(set) var isClosed = false
    public private(set) var hasRejectedEvents = false
    public private(set) var droppedEventCount = 0
    /// Completed, write-resolved attempts evicted from this bounded reorder buffer.
    /// Their already-emitted rows remain the caller's responsibility and are not lost here.
    public private(set) var droppedAttemptCount = 0

    private var entries: [AttemptKey: Entry] = [:]
    private var attemptOrder: [AttemptKey] = []
    private var excludedAttempts: Set<AttemptKey> = []
    private var excludedAttemptOrder: [AttemptKey] = []
    private var retiredAttempts: Set<AttemptKey> = []
    private var retiredAttemptOrder: [AttemptKey] = []
    private var queueWatermarks: [UUID: QueueWatermark] = [:]

    public var trackedAttemptCount: Int { entries.count }

    public var hasUnresolvedGaps: Bool {
        entries.values.contains { entry in
            guard !entry.pending.isEmpty else { return false }
            if let queuedAt = entry.queuedAt {
                return queuedAt.monotonicNanoseconds >= startedAt.monotonicNanoseconds
            }
            return entry.pending.values.contains {
                $0.timestamp.monotonicNanoseconds >= startedAt.monotonicNanoseconds
            }
        }
    }

    public init(
        startedAt: DiagnosticAuditTimestamp,
        maximumTrackedAttempts: Int = 256,
        maximumPendingEventsPerAttempt: Int = 8
    ) {
        self.startedAt = startedAt
        self.maximumTrackedAttempts = max(0, maximumTrackedAttempts)
        self.maximumPendingEventsPerAttempt = max(0, maximumPendingEventsPerAttempt)
    }

    /// Accepts events for any connection in this recording window. The attempt key includes
    /// the connection generation, so a reused attempt UUID cannot cross connection boundaries.
    @discardableResult
    public mutating func ingest(_ event: DiagnosticAuditEvent) throws -> [DiagnosticAuditEvent] {
        guard !isClosed else { throw DiagnosticAuditOrdinalBufferError.closed }
        do {
            return try ingestOpen(event)
        } catch {
            hasRejectedEvents = true
            droppedEventCount += 1
            throw error
        }
    }

    private mutating func ingestOpen(_ event: DiagnosticAuditEvent) throws -> [DiagnosticAuditEvent] {
        let source: DiagnosticAuditEvent
        do {
            source = try validatedEvent(event)
        } catch {
            try reject(error)
        }

        guard case .acquisition(let connectionID) = source.scope,
              connectionID == source.context.connectionID else {
            try reject(DiagnosticAuditError.scopeMismatch)
        }
        let key = AttemptKey(connectionID: connectionID, attemptID: source.attemptID)

        if source.stage == .queued,
           source.timestamp.monotonicNanoseconds < startedAt.monotonicNanoseconds {
            try excludePreRecordingAttempt(key, queueEvent: source)
            return []
        }
        if excludedAttempts.contains(key) {
            if source.stage != .queued { return [] }
            try reject(DiagnosticAuditError.duplicateAttempt(source.attemptID))
        }
        if retiredAttempts.contains(key) {
            if source.stage != .queued { return [] }
            try reject(DiagnosticAuditError.duplicateAttempt(source.attemptID))
        }

        if var entry = entries[key] {
            try verifyIdentity(of: source, against: entry)
            if try isExactDuplicate(source, in: entry) { return [] }

            if source.stage == .queued {
                guard entry.queuedAt == nil else {
                    try reject(DiagnosticAuditError.duplicateAttempt(source.attemptID))
                }
                try validateQueueWatermark(source, connectionID: connectionID)
                entry.queuedAt = source.timestamp
                entry.signatures[source.ordinal] = EventSignature(event: source)
                var output: [DiagnosticAuditEvent] = []
                try emitContiguous(source, from: &entry, into: &output)
                try drainPending(from: &entry, into: &output)
                entries[key] = entry
                recordAcceptedQueue(source, connectionID: connectionID)
                return output
            }

            guard entry.queuedAt != nil || source.ordinal > 1 else {
                try reject(DiagnosticAuditError.invalidAuditEvent(source.attemptID))
            }
            return try acceptNonQueued(source, for: key, entry: &entry)
        }

        if source.stage != .queued,
           source.timestamp.monotonicNanoseconds < startedAt.monotonicNanoseconds {
            return []
        }
        if source.stage != .queued {
            var entry = try makeEntry(for: source, queuedAt: nil)
            entries[key] = entry
            attemptOrder.append(key)
            return []
        }

        try validateQueueWatermark(source, connectionID: connectionID)
        var entry = try makeEntry(for: source, queuedAt: source.timestamp)
        entry.signatures[source.ordinal] = EventSignature(event: source)
        var output: [DiagnosticAuditEvent] = []
        try emitContiguous(source, from: &entry, into: &output)
        try drainPending(from: &entry, into: &output)
        entries[key] = entry
        attemptOrder.append(key)
        recordAcceptedQueue(source, connectionID: connectionID)
        return output
    }

    /// Closes this recording-scoped buffer. Inspect `hasUnresolvedGaps` before closing;
    /// closing never fabricates terminal events or alters acquisition state.
    public mutating func close() {
        isClosed = true
    }

    private func validatedEvent(_ event: DiagnosticAuditEvent) throws -> DiagnosticAuditEvent {
        try JSONDecoder().decode(DiagnosticAuditEvent.self, from: JSONEncoder().encode(event))
    }

    private mutating func makeEntry(
        for event: DiagnosticAuditEvent,
        queuedAt: DiagnosticAuditTimestamp?
    ) throws -> Entry {
        var entry = Entry(
            query: event.query,
            context: event.context,
            queuedAt: queuedAt
        )
        if queuedAt == nil {
            try storePending(event, in: &entry)
        }
        try makeRoomForAttempt(event.attemptID)
        return entry
    }

    private mutating func acceptNonQueued(
        _ event: DiagnosticAuditEvent,
        for key: AttemptKey,
        entry: inout Entry
    ) throws -> [DiagnosticAuditEvent] {
        guard let retainedSignature = entry.signatures[event.ordinal] else {
            if event.ordinal < entry.nextOrdinal {
                try reject(DiagnosticAuditError.incompleteHistory(event.attemptID))
            }
            if event.ordinal > entry.nextOrdinal {
                try storePending(event, in: &entry)
                entries[key] = entry
                return []
            }
            entry.signatures[event.ordinal] = EventSignature(event: event)
            var output: [DiagnosticAuditEvent] = []
            try emitContiguous(event, from: &entry, into: &output)
            try drainPending(from: &entry, into: &output)
            entries[key] = entry
            return output
        }

        guard retainedSignature == EventSignature(event: event) else {
            try reject(DiagnosticAuditError.conflictingOrdinal(event.attemptID, event.ordinal))
        }
        return []
    }

    private func verifyIdentity(of event: DiagnosticAuditEvent, against entry: Entry) throws {
        guard event.query == entry.query, event.context == entry.context else {
            throw DiagnosticAuditError.identityMismatch(event.attemptID)
        }
    }

    private func isExactDuplicate(_ event: DiagnosticAuditEvent, in entry: Entry) throws -> Bool {
        guard let retainedSignature = entry.signatures[event.ordinal] else { return false }
        guard retainedSignature == EventSignature(event: event) else {
            throw DiagnosticAuditError.conflictingOrdinal(event.attemptID, event.ordinal)
        }
        return true
    }

    private mutating func storePending(_ event: DiagnosticAuditEvent, in entry: inout Entry) throws {
        if let previous = entry.signatures[event.ordinal] {
            guard previous == EventSignature(event: event) else {
                try reject(DiagnosticAuditError.conflictingOrdinal(event.attemptID, event.ordinal))
            }
            return
        }
        guard entry.pending.count < maximumPendingEventsPerAttempt else {
            try reject(DiagnosticAuditOrdinalBufferError.maximumPendingEventsExceeded(event.attemptID))
        }
        entry.signatures[event.ordinal] = EventSignature(event: event)
        entry.pending[event.ordinal] = event
    }

    private mutating func emitContiguous(
        _ event: DiagnosticAuditEvent,
        from entry: inout Entry,
        into output: inout [DiagnosticAuditEvent]
    ) throws {
        guard event.ordinal == entry.nextOrdinal else {
            try reject(DiagnosticAuditError.incompleteHistory(event.attemptID))
        }
        if let previous = entry.lastEmittedMonotonic,
           event.timestamp.monotonicNanoseconds < previous {
            try reject(DiagnosticAuditError.timestampOrder(event.attemptID))
        }
        output.append(event)
        entry.lastEmittedMonotonic = event.timestamp.monotonicNanoseconds
        entry.nextOrdinal += 1
        if event.stage == .terminal {
            entry.terminalWasEmitted = true
            entry.terminalWriteResolved = event.writeDispositionAtTermination != .inFlight
        } else if entry.terminalWasEmitted,
                  event.stage == .transportWriteCompleted || event.stage == .transportWriteFailed {
            entry.terminalWriteResolved = true
        }
    }

    private mutating func drainPending(
        from entry: inout Entry,
        into output: inout [DiagnosticAuditEvent]
    ) throws {
        while let next = entry.pending.removeValue(forKey: entry.nextOrdinal) {
            try emitContiguous(next, from: &entry, into: &output)
        }
    }

    private mutating func validateQueueWatermark(
        _ event: DiagnosticAuditEvent,
        connectionID: UUID
    ) throws {
        guard let watermark = queueWatermarks[connectionID] else {
            guard queueWatermarks.count < maximumTrackedAttempts else {
                try reject(DiagnosticAuditOrdinalBufferError.maximumTrackedConnectionsExceeded(connectionID))
            }
            return
        }
        let monotonic = event.timestamp.monotonicNanoseconds
        guard monotonic >= watermark.monotonicNanoseconds else {
            try reject(DiagnosticAuditOrdinalBufferError.staleQueuedEvent(event.attemptID))
        }
        if monotonic == watermark.monotonicNanoseconds {
            guard !watermark.attemptIDs.contains(event.attemptID) else {
                try reject(DiagnosticAuditError.duplicateAttempt(event.attemptID))
            }
            guard watermark.attemptIDs.count < maximumTrackedAttempts else {
                try reject(DiagnosticAuditOrdinalBufferError.sameTimestampQueueLimitExceeded(event.attemptID))
            }
        }
    }

    private mutating func recordAcceptedQueue(_ event: DiagnosticAuditEvent, connectionID: UUID) {
        let monotonic = event.timestamp.monotonicNanoseconds
        if let watermark = queueWatermarks[connectionID],
           watermark.monotonicNanoseconds == monotonic {
            queueWatermarks[connectionID]?.attemptIDs.insert(event.attemptID)
        } else {
            queueWatermarks[connectionID] = QueueWatermark(
                monotonicNanoseconds: monotonic,
                attemptIDs: [event.attemptID]
            )
        }
    }

    private mutating func makeRoomForAttempt(_ attemptID: UUID) throws {
        while entries.count >= maximumTrackedAttempts {
            guard let evictableKey = attemptOrder.first(where: { key in
                guard let entry = entries[key] else { return false }
                return entry.terminalWasEmitted && entry.terminalWriteResolved && entry.pending.isEmpty
            }) else {
                try reject(DiagnosticAuditOrdinalBufferError.maximumTrackedAttemptsExceeded(attemptID))
            }
            entries.removeValue(forKey: evictableKey)
            attemptOrder.removeAll { $0 == evictableKey }
            droppedAttemptCount += 1
            rememberRetiredAttempt(evictableKey)
        }
    }

    private mutating func excludePreRecordingAttempt(
        _ key: AttemptKey,
        queueEvent: DiagnosticAuditEvent
    ) throws {
        if let existing = entries[key] {
            try verifyIdentity(of: queueEvent, against: existing)
            guard existing.queuedAt == nil else {
                try reject(DiagnosticAuditError.conflictingOrdinal(queueEvent.attemptID, queueEvent.ordinal))
            }
            entries.removeValue(forKey: key)
            attemptOrder.removeAll { $0 == key }
        }
        rememberExcludedAttempt(key)
    }

    private mutating func rememberExcludedAttempt(_ key: AttemptKey) {
        guard !excludedAttempts.contains(key) else { return }
        let limit = max(1, maximumTrackedAttempts)
        if excludedAttemptOrder.count >= limit,
           let oldest = excludedAttemptOrder.first {
            excludedAttemptOrder.removeFirst()
            excludedAttempts.remove(oldest)
        }
        excludedAttempts.insert(key)
        excludedAttemptOrder.append(key)
    }

    private mutating func rememberRetiredAttempt(_ key: AttemptKey) {
        guard !retiredAttempts.contains(key) else { return }
        let limit = max(1, maximumTrackedAttempts)
        if retiredAttemptOrder.count >= limit,
           let oldest = retiredAttemptOrder.first {
            retiredAttemptOrder.removeFirst()
            retiredAttempts.remove(oldest)
        }
        retiredAttempts.insert(key)
        retiredAttemptOrder.append(key)
    }

    private func reject(_ error: Error) throws -> Never {
        throw error
    }

    private struct AttemptKey: Hashable, Sendable {
        let connectionID: UUID
        let attemptID: UUID
    }

    private struct QueueWatermark: Sendable {
        let monotonicNanoseconds: UInt64
        var attemptIDs: Set<UUID>
    }

    private struct Entry: Sendable {
        let query: OBDQueryDefinition
        let context: DiagnosticAuditContext
        var queuedAt: DiagnosticAuditTimestamp?
        var nextOrdinal = 1
        var pending: [Int: DiagnosticAuditEvent] = [:]
        var signatures: [Int: EventSignature] = [:]
        var lastEmittedMonotonic: UInt64?
        var terminalWasEmitted = false
        var terminalWriteResolved = false
    }

    /// Query/context are stored once per attempt. These signatures retain just the fields
    /// that can vary by ordinal, allowing exact-duplicate checks without copying query data.
    private struct EventSignature: Equatable, Sendable {
        let ordinal: Int
        let stage: DiagnosticAuditStage
        let timestamp: DiagnosticAuditTimestamp
        let terminalOutcome: DiagnosticAuditOutcome?
        let writeDispositionAtTermination: DiagnosticAuditWriteDisposition?
        let reasonCode: String?
        let reason: String?
        let responseSequence: UInt64?
        let responseReceivedAt: DiagnosticAuditTimestamp?

        init(event: DiagnosticAuditEvent) {
            ordinal = event.ordinal
            stage = event.stage
            timestamp = event.timestamp
            terminalOutcome = event.terminalOutcome
            writeDispositionAtTermination = event.writeDispositionAtTermination
            reasonCode = event.reasonCode
            reason = event.reason
            responseSequence = event.responseSequence
            responseReceivedAt = event.responseReceivedAt
        }
    }
}
