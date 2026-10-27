import Foundation

public enum DiagnosticAuditCaptureError: Error, Equatable, Sendable {
    case staleQueuedEvent(UUID)
    case sameTimestampQueueLimitExceeded(UUID)
    case unsupportedSourceOutcome(UUID)
}

/// A bounded projection of acquisition audit rows into one recording window.
/// The caller serializes mutations with its existing recording owner.
public struct DiagnosticAuditCapture: Sendable {
    public let scope: DiagnosticAuditScope
    public let startedAt: DiagnosticAuditTimestamp
    public let completedAttemptHistoryLimit: Int
    public let sameTimestampAttemptLimit: Int

    private var ledger: DiagnosticAuditLedger
    private var sourceEventsByAttemptID: [UUID: [DiagnosticAuditEvent]] = [:]
    private var retiredConnectionByAttemptID: [UUID: UUID] = [:]
    private var retiredAttemptOrder: [UUID] = []
    private var highestQueuedMonotonic: UInt64?
    private var attemptIDsAtHighestQueuedMonotonic: Set<UUID> = []
    private var historyLossWasDetected = false

    public var isClosed: Bool { ledger.isClosed }
    public var droppedAttemptCount: Int { ledger.droppedAttemptCount }
    /// True when the monotonic watermark or same-time bucket gate rejected an eligible queue.
    /// Callers should also persist an incomplete marker for other thrown ingest errors.
    public var hasRejectedSourceEvents: Bool { historyLossWasDetected }
    public var historyWasTruncated: Bool {
        droppedAttemptCount > 0 || historyLossWasDetected
    }

    public init(
        recordingID: UUID,
        startedAt: DiagnosticAuditTimestamp,
        completedAttemptHistoryLimit: Int = 256,
        sameTimestampAttemptLimit: Int = 256
    ) {
        let boundedHistoryLimit = max(0, completedAttemptHistoryLimit)
        scope = .recordingWindow(recordingID: recordingID)
        self.startedAt = startedAt
        self.completedAttemptHistoryLimit = boundedHistoryLimit
        self.sameTimestampAttemptLimit = max(0, sameTimestampAttemptLimit)
        ledger = DiagnosticAuditLedger(
            scope: .recordingWindow(recordingID: recordingID),
            completedAttemptHistoryLimit: boundedHistoryLimit
        )
    }

    /// Copies one already-ordered acquisition row. Unknown late phases are ignored;
    /// only a queued row can establish an attempt in this recording window.
    @discardableResult
    public mutating func ingest(_ acquisitionEvent: DiagnosticAuditEvent) throws -> [DiagnosticAuditEvent] {
        guard !isClosed else { return [] }
        let source = try validatedSourceEvent(acquisitionEvent)
        guard case .acquisition(let connectionID) = source.scope,
              connectionID == source.context.connectionID else {
            throw DiagnosticAuditError.scopeMismatch
        }

        if source.stage == .queued,
           source.timestamp.monotonicNanoseconds < startedAt.monotonicNanoseconds {
            return []
        }

        if let priorSourceEvents = sourceEventsByAttemptID[source.attemptID] {
            if try isExactRetainedDuplicate(source, among: priorSourceEvents) { return [] }
            if source.stage == .queued {
                throw DiagnosticAuditError.duplicateAttempt(source.attemptID)
            }
        } else if source.stage != .queued {
            return []
        }

        if source.stage == .queued {
            try validateQueueAdmission(source, connectionID: connectionID)
        } else {
            guard let priorSourceEvents = sourceEventsByAttemptID[source.attemptID] else {
                return []
            }
            try validateSourceContinuation(source, after: priorSourceEvents)
        }

        let priorSourceEvents = sourceEventsByAttemptID[source.attemptID] ?? []
        let nextSourceEvents = priorSourceEvents + [source]
        _ = try DiagnosticAuditAttempt.reconstruct(events: nextSourceEvents)

        var nextLedger = ledger
        guard let appended = try append(source, to: &nextLedger) else {
            throw DiagnosticAuditError.incompleteHistory(source.attemptID)
        }

        var nextSourceMap = sourceEventsByAttemptID
        nextSourceMap[source.attemptID] = nextSourceEvents
        var nextRetiredMap = retiredConnectionByAttemptID
        var nextRetiredOrder = retiredAttemptOrder
        let retainedIDs = Set(nextLedger.snapshot().map(\.attemptID))
        let evictedIDs = nextSourceMap.keys.filter { !retainedIDs.contains($0) }
        for evictedID in evictedIDs {
            if let lastSourceEvent = nextSourceMap[evictedID]?.last {
                nextRetiredMap[evictedID] = lastSourceEvent.context.connectionID
                nextRetiredOrder.append(evictedID)
            }
            nextSourceMap.removeValue(forKey: evictedID)
        }
        trimRetiredIdentities(&nextRetiredMap, order: &nextRetiredOrder)

        ledger = nextLedger
        sourceEventsByAttemptID = nextSourceMap
        retiredConnectionByAttemptID = nextRetiredMap
        retiredAttemptOrder = nextRetiredOrder
        if source.stage == .queued {
            recordQueueWatermark(source)
        }
        return [appended]
    }

    /// Closes only this recording copy. It does not affect the acquisition ledger.
    @discardableResult
    public mutating func close(at timestamp: DiagnosticAuditTimestamp) throws -> [DiagnosticAuditEvent] {
        guard !isClosed else { return [] }
        var nextLedger = ledger
        let appended = try nextLedger.closeRecordingWindow(at: timestamp)
        ledger = nextLedger
        sourceEventsByAttemptID.removeAll(keepingCapacity: false)
        return appended
    }

    public func snapshot() -> [DiagnosticAuditAttempt] {
        ledger.snapshot()
    }

    private func isExactRetainedDuplicate(
        _ event: DiagnosticAuditEvent,
        among priorEvents: [DiagnosticAuditEvent]
    ) throws -> Bool {
        guard let first = priorEvents.first else {
            throw DiagnosticAuditError.incompleteHistory(event.attemptID)
        }
        guard event.scope == first.scope,
              event.attemptID == first.attemptID,
              event.query == first.query,
              event.context == first.context else {
            throw DiagnosticAuditError.identityMismatch(event.attemptID)
        }
        guard let retained = priorEvents.first(where: { $0.ordinal == event.ordinal }) else {
            return false
        }
        guard retained == event else {
            throw DiagnosticAuditError.conflictingOrdinal(event.attemptID, event.ordinal)
        }
        return true
    }

    private mutating func validateQueueAdmission(
        _ event: DiagnosticAuditEvent,
        connectionID: UUID
    ) throws {
        if let existing = sourceEventsByAttemptID[event.attemptID]?.first {
            guard existing.context.connectionID == connectionID else {
                throw DiagnosticAuditError.identityMismatch(event.attemptID)
            }
            throw DiagnosticAuditError.duplicateAttempt(event.attemptID)
        }
        if let retiredConnection = retiredConnectionByAttemptID[event.attemptID] {
            guard retiredConnection == connectionID else {
                throw DiagnosticAuditError.identityMismatch(event.attemptID)
            }
            throw DiagnosticAuditError.duplicateAttempt(event.attemptID)
        }

        let monotonic = event.timestamp.monotonicNanoseconds
        if let highestQueuedMonotonic {
            guard monotonic >= highestQueuedMonotonic else {
                historyLossWasDetected = true
                throw DiagnosticAuditCaptureError.staleQueuedEvent(event.attemptID)
            }
            if monotonic == highestQueuedMonotonic {
                guard !attemptIDsAtHighestQueuedMonotonic.contains(event.attemptID) else {
                    throw DiagnosticAuditError.duplicateAttempt(event.attemptID)
                }
                guard attemptIDsAtHighestQueuedMonotonic.count < sameTimestampAttemptLimit else {
                    historyLossWasDetected = true
                    throw DiagnosticAuditCaptureError.sameTimestampQueueLimitExceeded(event.attemptID)
                }
            }
        } else if sameTimestampAttemptLimit == 0 {
            historyLossWasDetected = true
            throw DiagnosticAuditCaptureError.sameTimestampQueueLimitExceeded(event.attemptID)
        }
    }

    private func validateSourceContinuation(
        _ event: DiagnosticAuditEvent,
        after priorEvents: [DiagnosticAuditEvent]
    ) throws {
        guard let previous = priorEvents.last else {
            throw DiagnosticAuditError.incompleteHistory(event.attemptID)
        }
        guard event.scope == previous.scope,
              event.attemptID == previous.attemptID,
              event.query == previous.query,
              event.context == previous.context else {
            throw DiagnosticAuditError.identityMismatch(event.attemptID)
        }
        let expectedOrdinal = previous.ordinal + 1
        guard event.ordinal == expectedOrdinal else {
            if event.ordinal <= previous.ordinal {
                throw DiagnosticAuditError.conflictingOrdinal(event.attemptID, event.ordinal)
            }
            throw DiagnosticAuditError.incompleteHistory(event.attemptID)
        }
    }

    private mutating func recordQueueWatermark(_ event: DiagnosticAuditEvent) {
        let monotonic = event.timestamp.monotonicNanoseconds
        if highestQueuedMonotonic != monotonic {
            highestQueuedMonotonic = monotonic
            attemptIDsAtHighestQueuedMonotonic = [event.attemptID]
        } else {
            attemptIDsAtHighestQueuedMonotonic.insert(event.attemptID)
        }
    }

    private func trimRetiredIdentities(
        _ identities: inout [UUID: UUID],
        order: inout [UUID]
    ) {
        let limit = max(1, completedAttemptHistoryLimit)
        while order.count > limit {
            identities.removeValue(forKey: order.removeFirst())
        }
    }

    private func validatedSourceEvent(_ event: DiagnosticAuditEvent) throws -> DiagnosticAuditEvent {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        return try decoder.decode(DiagnosticAuditEvent.self, from: encoder.encode(event))
    }

    private func append(
        _ source: DiagnosticAuditEvent,
        to ledger: inout DiagnosticAuditLedger
    ) throws -> DiagnosticAuditEvent? {
        switch source.stage {
        case .queued:
            return try ledger.queued(
                query: source.query, context: source.context,
                at: source.timestamp, attemptID: source.attemptID
            )
        case .started:
            return try ledger.started(attemptID: source.attemptID, at: source.timestamp)
        case .transportWriteStarted:
            return try ledger.transportWriteStarted(attemptID: source.attemptID, at: source.timestamp)
        case .transportWriteCompleted:
            return try ledger.transportWriteCompleted(attemptID: source.attemptID, at: source.timestamp)
        case .transportWriteFailed:
            guard let reasonCode = source.reasonCode else {
                throw DiagnosticAuditError.invalidReasonCode(source.attemptID)
            }
            return try ledger.transportWriteFailed(
                attemptID: source.attemptID, reasonCode: reasonCode,
                reason: source.reason, at: source.timestamp
            )
        case .terminal:
            guard let outcome = source.terminalOutcome else {
                throw DiagnosticAuditError.invalidAuditEvent(source.attemptID)
            }
            switch outcome {
            case .succeeded:
                guard let responseSequence = source.responseSequence,
                      let responseReceivedAt = source.responseReceivedAt else {
                    throw DiagnosticAuditError.invalidAuditEvent(source.attemptID)
                }
                return try ledger.succeeded(
                    attemptID: source.attemptID, responseSequence: responseSequence,
                    responseReceivedAt: responseReceivedAt, at: source.timestamp
                )
            case .failed:
                guard let reasonCode = source.reasonCode else {
                    throw DiagnosticAuditError.invalidReasonCode(source.attemptID)
                }
                return try ledger.failed(
                    attemptID: source.attemptID, reasonCode: reasonCode,
                    reason: source.reason, at: source.timestamp
                )
            case .cancelled:
                guard let reasonCode = source.reasonCode else {
                    throw DiagnosticAuditError.invalidReasonCode(source.attemptID)
                }
                return try ledger.cancelled(
                    attemptID: source.attemptID, reasonCode: reasonCode,
                    reason: source.reason, at: source.timestamp
                )
            case .recordingWindowClosed:
                throw DiagnosticAuditCaptureError.unsupportedSourceOutcome(source.attemptID)
            }
        }
    }
}

public enum DiagnosticAuditReplayStatus: String, Equatable, Sendable {
    case available
    case truncated
    case unavailable
}

/// Strict, read-only projection of audit envelopes found in ordered SYSTEM payloads.
public struct DiagnosticAuditReplayProjection: Equatable, Sendable {
    public let attempts: [DiagnosticAuditAttempt]
    public let status: DiagnosticAuditReplayStatus
    /// Number of malformed rows or attempt groups that could not be reconstructed.
    public let unavailableAttemptCount: Int
    /// Number of known groups whose leading queued row is absent from a capped prefix.
    public let truncatedAttemptCount: Int
    public let historyWasCapped: Bool
    /// True when a persisted `diagnostic_audit_incomplete` marker records capture-side loss.
    public let captureWasIncomplete: Bool

    public static func project(
        systemPayloadJSON: [String],
        historyWasCapped: Bool = false
    ) -> Self {
        var orderedKeys: [AttemptKey] = []
        var eventsByKey: [AttemptKey: [DiagnosticAuditEvent]] = [:]
        var unavailableCount = 0
        var captureWasIncomplete = false
        var recordingFailed = false

        let decoder = JSONDecoder()
        for payloadJSON in systemPayloadJSON {
            guard let data = payloadJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else {
                unavailableCount += 1
                continue
            }

            let name = dictionary["name"] as? String
            if name == "recording_failed" {
                recordingFailed = true
            } else if name == "diagnostic_audit_incomplete" {
                captureWasIncomplete = true
            } else if name == DiagnosticAuditSystemPayload.name {
                do {
                    let payload = try decoder.decode(DiagnosticAuditSystemPayload.self, from: data)
                    let key = AttemptKey(scope: payload.diagnosticAudit.scope, attemptID: payload.diagnosticAudit.attemptID)
                    if eventsByKey[key] == nil { orderedKeys.append(key) }
                    eventsByKey[key, default: []].append(payload.diagnosticAudit)
                } catch {
                    unavailableCount += 1
                }
            } else if name?.hasPrefix("diagnostic_audit") == true || dictionary["diagnosticAudit"] != nil {
                unavailableCount += 1
            }
        }

        var attempts: [DiagnosticAuditAttempt] = []
        var truncatedCount = 0
        for key in orderedKeys {
            guard let events = eventsByKey[key], let first = events.first else { continue }
            guard first.ordinal == 1, first.stage == .queued else {
                if historyWasCapped {
                    truncatedCount += 1
                } else {
                    unavailableCount += 1
                }
                continue
            }
            do {
                attempts.append(try DiagnosticAuditAttempt.reconstruct(events: events))
            } catch {
                unavailableCount += 1
            }
        }

        let status: DiagnosticAuditReplayStatus
        if unavailableCount > 0 || captureWasIncomplete || recordingFailed {
            status = .unavailable
        } else if historyWasCapped || truncatedCount > 0 {
            status = .truncated
        } else {
            status = .available
        }
        return Self(
            attempts: attempts,
            status: status,
            unavailableAttemptCount: unavailableCount,
            truncatedAttemptCount: truncatedCount,
            historyWasCapped: historyWasCapped,
            captureWasIncomplete: captureWasIncomplete
        )
    }

    private struct AttemptKey: Hashable {
        let scopeKind: Int
        let scopeID: UUID
        let attemptID: UUID

        init(scope: DiagnosticAuditScope, attemptID: UUID) {
            switch scope {
            case .acquisition(let connectionID):
                scopeKind = 0
                scopeID = connectionID
            case .recordingWindow(let recordingID):
                scopeKind = 1
                scopeID = recordingID
            }
            self.attemptID = attemptID
        }
    }
}
