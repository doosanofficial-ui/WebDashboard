import Foundation

public enum DiagnosticAuditError: Error, Equatable, Sendable {
    case invalidTimestamp
    case invalidContext
    case emptyHistory
    case duplicateAttempt(UUID)
    case missingAttempt(UUID)
    case invalidTransition(UUID, from: DiagnosticAuditStage?, to: DiagnosticAuditStage)
    case incompleteHistory(UUID)
    case conflictingOrdinal(UUID, Int)
    case identityMismatch(UUID)
    case timestampOrder(UUID)
    case invalidAuditEvent(UUID)
    case invalidReasonCode(UUID)
    case conflictingTerminal(UUID, existing: DiagnosticAuditOutcome, received: DiagnosticAuditOutcome)
    case conflictingWriteOutcome(UUID)
    case ledgerClosed
    case scopeMismatch
}

public struct DiagnosticAuditTimestamp: Codable, Equatable, Sendable {
    public let epochSeconds: Double
    public let monotonicNanoseconds: UInt64

    public init(epochSeconds: Double, monotonicNanoseconds: UInt64) throws {
        guard epochSeconds.isFinite else { throw DiagnosticAuditError.invalidTimestamp }
        self.epochSeconds = epochSeconds
        self.monotonicNanoseconds = monotonicNanoseconds
    }

    private enum CodingKeys: String, CodingKey {
        case epochSeconds
        case monotonicNanoseconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                epochSeconds: values.decode(Double.self, forKey: .epochSeconds),
                monotonicNanoseconds: values.decode(UInt64.self, forKey: .monotonicNanoseconds)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .epochSeconds, in: values, debugDescription: "Audit timestamp must be finite"
            )
        }
    }
}

/// Each mutable ledger has one owner: an acquisition actor or the recording MainActor.
/// The associated identifier prevents late callbacks from crossing into a new scope.
public enum DiagnosticAuditScope: Codable, Equatable, Sendable {
    case acquisition(connectionID: UUID)
    case recordingWindow(recordingID: UUID)

    public var identifier: UUID {
        switch self {
        case .acquisition(let connectionID): connectionID
        case .recordingWindow(let recordingID): recordingID
        }
    }

    public var isRecordingWindow: Bool {
        if case .recordingWindow = self { return true }
        return false
    }

    fileprivate var label: String {
        switch self {
        case .acquisition: "acquisition"
        case .recordingWindow: "recording-window"
        }
    }
}

public struct DiagnosticAuditContext: Codable, Equatable, Sendable {
    /// Nil is a valid local, unassigned context. It never blocks acquisition.
    public let vehicleContextID: String?
    public let adapterProfileID: String
    public let adapterProfileName: String
    public let transport: String
    public let connectionID: UUID

    public init(
        vehicleContextID: String? = nil,
        adapterProfileID: String,
        adapterProfileName: String,
        transport: String,
        connectionID: UUID
    ) throws {
        guard !adapterProfileID.isEmpty, !adapterProfileName.isEmpty,
              !transport.isEmpty, vehicleContextID?.isEmpty != true else {
            throw DiagnosticAuditError.invalidContext
        }
        self.vehicleContextID = vehicleContextID
        self.adapterProfileID = adapterProfileID
        self.adapterProfileName = adapterProfileName
        self.transport = transport
        self.connectionID = connectionID
    }

    private enum CodingKeys: String, CodingKey {
        case vehicleContextID
        case adapterProfileID
        case adapterProfileName
        case transport
        case connectionID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                vehicleContextID: values.decodeIfPresent(String.self, forKey: .vehicleContextID),
                adapterProfileID: values.decode(String.self, forKey: .adapterProfileID),
                adapterProfileName: values.decode(String.self, forKey: .adapterProfileName),
                transport: values.decode(String.self, forKey: .transport),
                connectionID: values.decode(UUID.self, forKey: .connectionID)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .adapterProfileID, in: values, debugDescription: "Invalid diagnostic audit context"
            )
        }
    }
}

public enum DiagnosticAuditStage: String, Codable, Equatable, Sendable {
    case queued
    case started
    case transportWriteStarted
    case transportWriteCompleted
    case transportWriteFailed
    case terminal
}

public enum DiagnosticAuditOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case recordingWindowClosed
}

/// A successful transport API return is not proof of ECU receipt.
public enum DiagnosticAuditWriteDisposition: String, Codable, Equatable, Sendable {
    case notAttempted
    case inFlight
    case completed
    case indeterminate
}

/// Immutable v1 row. The complete query definition is embedded to preserve source and
/// scheduling provenance for a recording-window copy and later export/replay readers.
public struct DiagnosticAuditEvent: Codable, Equatable, Sendable {
    public let version: Int
    public let scope: DiagnosticAuditScope
    public let attemptID: UUID
    public let ordinal: Int
    public let query: OBDQueryDefinition
    public let context: DiagnosticAuditContext
    public let stage: DiagnosticAuditStage
    public let timestamp: DiagnosticAuditTimestamp
    public let terminalOutcome: DiagnosticAuditOutcome?
    public let writeDispositionAtTermination: DiagnosticAuditWriteDisposition?
    public let reasonCode: String?
    public let reason: String?
    public let responseSequence: UInt64?
    public let responseReceivedAt: DiagnosticAuditTimestamp?

    public var queryID: String { query.id }
    public var requestCANID: UInt32 { query.requestCANID }
    public var responseCANID: UInt32 { query.responseCANID }
    public var isExtended: Bool { query.isExtended }

    fileprivate init(
        scope: DiagnosticAuditScope,
        attemptID: UUID,
        ordinal: Int,
        query: OBDQueryDefinition,
        context: DiagnosticAuditContext,
        stage: DiagnosticAuditStage,
        timestamp: DiagnosticAuditTimestamp,
        terminalOutcome: DiagnosticAuditOutcome? = nil,
        writeDispositionAtTermination: DiagnosticAuditWriteDisposition? = nil,
        reasonCode: String? = nil,
        reason: String? = nil,
        responseSequence: UInt64? = nil,
        responseReceivedAt: DiagnosticAuditTimestamp? = nil
    ) {
        version = 1
        self.scope = scope
        self.attemptID = attemptID
        self.ordinal = ordinal
        self.query = query
        self.context = context
        self.stage = stage
        self.timestamp = timestamp
        self.terminalOutcome = terminalOutcome
        self.writeDispositionAtTermination = writeDispositionAtTermination
        self.reasonCode = reasonCode
        self.reason = reason
        self.responseSequence = responseSequence
        self.responseReceivedAt = responseReceivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case scope
        case attemptID
        case ordinal
        case query
        case context
        case stage
        case timestamp
        case terminalOutcome
        case writeDispositionAtTermination
        case reasonCode
        case reason
        case responseSequence
        case responseReceivedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        let scope = try values.decode(DiagnosticAuditScope.self, forKey: .scope)
        let attemptID = try values.decode(UUID.self, forKey: .attemptID)
        let ordinal = try values.decode(Int.self, forKey: .ordinal)
        let query = try values.decode(OBDQueryDefinition.self, forKey: .query)
        let context = try values.decode(DiagnosticAuditContext.self, forKey: .context)
        let stage = try values.decode(DiagnosticAuditStage.self, forKey: .stage)
        let timestamp = try values.decode(DiagnosticAuditTimestamp.self, forKey: .timestamp)
        let terminalOutcome = try values.decodeIfPresent(DiagnosticAuditOutcome.self, forKey: .terminalOutcome)
        let writeDisposition = try values.decodeIfPresent(
            DiagnosticAuditWriteDisposition.self, forKey: .writeDispositionAtTermination
        )
        let reasonCode = try values.decodeIfPresent(String.self, forKey: .reasonCode)
        let reason = try values.decodeIfPresent(String.self, forKey: .reason)
        let responseSequence = try values.decodeIfPresent(UInt64.self, forKey: .responseSequence)
        let responseReceivedAt = try values.decodeIfPresent(
            DiagnosticAuditTimestamp.self, forKey: .responseReceivedAt
        )

        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: values, debugDescription: "Unsupported diagnostic audit version"
            )
        }
        guard (1...32).contains(ordinal), (stage == .queued ? ordinal == 1 : ordinal > 1) else {
            throw DecodingError.dataCorruptedError(
                forKey: .ordinal, in: values, debugDescription: "Invalid diagnostic audit ordinal"
            )
        }
        self.init(
            scope: scope, attemptID: attemptID, ordinal: ordinal, query: query,
            context: context, stage: stage, timestamp: timestamp,
            terminalOutcome: terminalOutcome, writeDispositionAtTermination: writeDisposition,
            reasonCode: reasonCode, reason: reason,
            responseSequence: responseSequence, responseReceivedAt: responseReceivedAt
        )
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .stage, in: values, debugDescription: "Inconsistent diagnostic audit event fields"
            )
        }
    }

    fileprivate func validate() throws {
        guard version == 1, (1...32).contains(ordinal),
              (stage == .queued ? ordinal == 1 : ordinal > 1) else {
            throw DiagnosticAuditError.invalidAuditEvent(attemptID)
        }
        if let responseReceivedAt,
           responseReceivedAt.monotonicNanoseconds > timestamp.monotonicNanoseconds {
            throw DiagnosticAuditError.timestampOrder(attemptID)
        }
        if stage == .transportWriteFailed || terminalOutcome == .failed || terminalOutcome == .cancelled {
            guard reasonCode.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true else {
                throw DiagnosticAuditError.invalidReasonCode(attemptID)
            }
        }
        guard Self.isConsistent(
            scope: scope, context: context, stage: stage, timestamp: timestamp,
            terminalOutcome: terminalOutcome, writeDisposition: writeDispositionAtTermination,
            reasonCode: reasonCode, reason: reason,
            responseSequence: responseSequence, responseReceivedAt: responseReceivedAt
        ) else {
            throw DiagnosticAuditError.invalidAuditEvent(attemptID)
        }
    }

    private static func isConsistent(
        scope: DiagnosticAuditScope,
        context: DiagnosticAuditContext,
        stage: DiagnosticAuditStage,
        timestamp: DiagnosticAuditTimestamp,
        terminalOutcome: DiagnosticAuditOutcome?,
        writeDisposition: DiagnosticAuditWriteDisposition?,
        reasonCode: String?,
        reason: String?,
        responseSequence: UInt64?,
        responseReceivedAt: DiagnosticAuditTimestamp?
    ) -> Bool {
        if case .acquisition(let connectionID) = scope, connectionID != context.connectionID {
            return false
        }
        guard (terminalOutcome != nil) == (stage == .terminal),
              (writeDisposition != nil) == (stage == .terminal),
              (responseSequence != nil) == (responseReceivedAt != nil) else {
            return false
        }
        if let responseReceivedAt,
           responseReceivedAt.monotonicNanoseconds > timestamp.monotonicNanoseconds {
            return false
        }
        let hasResponse = responseSequence != nil
        let hasReasonCode = reasonCode.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        switch stage {
        case .queued, .started, .transportWriteStarted, .transportWriteCompleted:
            return terminalOutcome == nil && writeDisposition == nil
                && reasonCode == nil && reason == nil && !hasResponse
        case .transportWriteFailed:
            return terminalOutcome == nil && writeDisposition == nil
                && hasReasonCode && !hasResponse
        case .terminal:
            guard let terminalOutcome, let writeDisposition else { return false }
            switch terminalOutcome {
            case .succeeded:
                return writeDisposition != .notAttempted && hasResponse
                    && reasonCode == nil && reason == nil
            case .failed, .cancelled:
                return hasReasonCode && !hasResponse
            case .recordingWindowClosed:
                return scope.isRecordingWindow && reasonCode == "recording_window_closed"
                    && reason == nil && !hasResponse
            }
        }
    }
}

public struct DiagnosticAuditSystemPayload: Codable, Equatable, Sendable {
    public static let name = "diagnostic_audit_v1"

    public let name: String
    public let diagnosticAudit: DiagnosticAuditEvent

    public init(event: DiagnosticAuditEvent) {
        name = Self.name
        diagnosticAudit = event
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case diagnosticAudit
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try values.decode(String.self, forKey: .name)
        guard decodedName == Self.name else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: values, debugDescription: "Unexpected diagnostic audit event name"
            )
        }
        name = decodedName
        diagnosticAudit = try values.decode(DiagnosticAuditEvent.self, forKey: .diagnosticAudit)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(diagnosticAudit, forKey: .diagnosticAudit)
    }
}

public struct DiagnosticAuditAttempt: Equatable, Sendable, Identifiable {
    public let scope: DiagnosticAuditScope
    public let attemptID: UUID
    public let query: OBDQueryDefinition
    public let context: DiagnosticAuditContext
    public private(set) var events: [DiagnosticAuditEvent]

    public var id: String {
        "\(scope.label):\(scope.identifier.uuidString):\(attemptID.uuidString)"
    }

    public var terminalEvent: DiagnosticAuditEvent? {
        events.first { $0.stage == .terminal }
    }

    public var isTerminal: Bool { terminalEvent != nil }

    public var completedTransportWriteCount: Int {
        events.filter { $0.stage == .transportWriteCompleted }.count
    }

    public var currentWriteDisposition: DiagnosticAuditWriteDisposition {
        if events.contains(where: { $0.stage == .transportWriteCompleted }) { return .completed }
        if events.contains(where: { $0.stage == .transportWriteFailed }) { return .indeterminate }
        if events.contains(where: { $0.stage == .transportWriteStarted }) { return .inFlight }
        return .notAttempted
    }

    /// Rebuilds one attempt from rows already ordered by the persisted source sequence.
    /// Missing leading rows or gaps are reported; no queued or terminal event is invented.
    public static func reconstruct(events sourceEvents: [DiagnosticAuditEvent]) throws -> Self {
        guard let firstSourceEvent = sourceEvents.first else { throw DiagnosticAuditError.emptyHistory }
        let attemptID = firstSourceEvent.attemptID
        var eventByOrdinal: [Int: DiagnosticAuditEvent] = [:]
        var orderedEvents: [DiagnosticAuditEvent] = []

        for event in sourceEvents {
            guard event.attemptID == attemptID, event.scope == firstSourceEvent.scope,
                  event.query == firstSourceEvent.query, event.context == firstSourceEvent.context else {
                throw DiagnosticAuditError.identityMismatch(attemptID)
            }
            if let previous = eventByOrdinal[event.ordinal] {
                guard previous == event else {
                    throw DiagnosticAuditError.conflictingOrdinal(attemptID, event.ordinal)
                }
                continue
            }
            eventByOrdinal[event.ordinal] = event
            orderedEvents.append(event)
        }

        guard let first = orderedEvents.first, first.ordinal == 1, first.stage == .queued else {
            throw DiagnosticAuditError.incompleteHistory(attemptID)
        }
        var attempt = Self(firstEvent: first)
        for event in orderedEvents.dropFirst() {
            guard event.ordinal == attempt.events.count + 1 else {
                throw DiagnosticAuditError.incompleteHistory(attemptID)
            }
            guard let previous = attempt.events.last,
                  event.timestamp.monotonicNanoseconds >= previous.timestamp.monotonicNanoseconds else {
                throw DiagnosticAuditError.timestampOrder(attemptID)
            }
            try Self.validate(event, after: attempt)
            attempt.append(event)
        }
        return attempt
    }

    private static func validate(_ event: DiagnosticAuditEvent, after attempt: Self) throws {
        let attemptID = attempt.attemptID
        let previousStage = attempt.events.last?.stage
        if attempt.events.contains(where: { $0.stage == event.stage }) {
            throw DiagnosticAuditError.invalidTransition(attemptID, from: previousStage, to: event.stage)
        }

        switch event.stage {
        case .queued:
            throw DiagnosticAuditError.invalidTransition(attemptID, from: previousStage, to: .queued)
        case .started:
            guard previousStage == .queued else {
                throw DiagnosticAuditError.invalidTransition(attemptID, from: previousStage, to: .started)
            }
        case .transportWriteStarted:
            guard previousStage == .started else {
                throw DiagnosticAuditError.invalidTransition(attemptID, from: previousStage, to: .transportWriteStarted)
            }
        case .transportWriteCompleted, .transportWriteFailed:
            guard attempt.events.contains(where: { $0.stage == .transportWriteStarted }) else {
                throw DiagnosticAuditError.invalidTransition(attemptID, from: previousStage, to: event.stage)
            }
            let hasWriteResult = attempt.events.contains { $0.stage == .transportWriteCompleted || $0.stage == .transportWriteFailed }
            guard !hasWriteResult else { throw DiagnosticAuditError.conflictingWriteOutcome(attemptID) }
            if let terminal = attempt.terminalEvent {
                guard terminal.writeDispositionAtTermination == .inFlight else {
                    throw DiagnosticAuditError.conflictingWriteOutcome(attemptID)
                }
            } else if previousStage != .transportWriteStarted {
                throw DiagnosticAuditError.invalidTransition(attemptID, from: previousStage, to: event.stage)
            }
        case .terminal:
            guard attempt.terminalEvent == nil,
                  event.writeDispositionAtTermination == attempt.currentWriteDisposition else {
                throw DiagnosticAuditError.invalidTransition(attemptID, from: previousStage, to: .terminal)
            }
            if event.terminalOutcome == .succeeded,
               !attempt.events.contains(where: { $0.stage == .transportWriteStarted }) {
                throw DiagnosticAuditError.invalidTransition(attemptID, from: previousStage, to: .terminal)
            }
            if event.terminalOutcome == .recordingWindowClosed, !attempt.scope.isRecordingWindow {
                throw DiagnosticAuditError.scopeMismatch
            }
        }
    }

    fileprivate init(firstEvent: DiagnosticAuditEvent) {
        scope = firstEvent.scope
        attemptID = firstEvent.attemptID
        query = firstEvent.query
        context = firstEvent.context
        events = [firstEvent]
    }

    fileprivate mutating func append(_ event: DiagnosticAuditEvent) {
        events.append(event)
    }
}

/// Pure ordered reducer. Callers serialize mutations using their existing actor or actor-isolated owner.
public struct DiagnosticAuditLedger: Sendable {
    public let scope: DiagnosticAuditScope
    public let completedAttemptHistoryLimit: Int
    public private(set) var isClosed = false
    public private(set) var droppedAttemptCount = 0
    private var attemptOrder: [UUID] = []
    private var attemptsByID: [UUID: DiagnosticAuditAttempt] = [:]

    public init(scope: DiagnosticAuditScope, completedAttemptHistoryLimit: Int = 256) {
        self.scope = scope
        self.completedAttemptHistoryLimit = max(0, completedAttemptHistoryLimit)
    }

    public func snapshot() -> [DiagnosticAuditAttempt] {
        attemptOrder.compactMap { attemptsByID[$0] }
    }

    @discardableResult
    public mutating func queued(
        query: OBDQueryDefinition,
        context: DiagnosticAuditContext,
        at timestamp: DiagnosticAuditTimestamp,
        attemptID: UUID = UUID()
    ) throws -> DiagnosticAuditEvent {
        guard !isClosed else { throw DiagnosticAuditError.ledgerClosed }
        try validate(context: context)
        guard attemptsByID[attemptID] == nil else { throw DiagnosticAuditError.duplicateAttempt(attemptID) }
        let event = makeEvent(
            attemptID: attemptID, ordinal: 1, query: query, context: context,
            stage: .queued, at: timestamp
        )
        try event.validate()
        attemptsByID[attemptID] = DiagnosticAuditAttempt(firstEvent: event)
        attemptOrder.append(attemptID)
        return event
    }

    @discardableResult
    public mutating func started(
        attemptID: UUID, at timestamp: DiagnosticAuditTimestamp
    ) throws -> DiagnosticAuditEvent? {
        try appendStage(attemptID: attemptID, stage: .started, at: timestamp)
    }

    @discardableResult
    public mutating func transportWriteStarted(
        attemptID: UUID, at timestamp: DiagnosticAuditTimestamp
    ) throws -> DiagnosticAuditEvent? {
        try appendStage(attemptID: attemptID, stage: .transportWriteStarted, at: timestamp)
    }

    /// This stage records only that the transport write API returned successfully.
    /// It does not assert that CAN was observed or that the ECU accepted the request.
    @discardableResult
    public mutating func transportWriteCompleted(
        attemptID: UUID, at timestamp: DiagnosticAuditTimestamp
    ) throws -> DiagnosticAuditEvent? {
        guard let attempt = attemptsByID[attemptID] else { throw DiagnosticAuditError.missingAttempt(attemptID) }
        if attempt.events.contains(where: { $0.stage == .transportWriteCompleted }) { return nil }
        if attempt.events.contains(where: { $0.stage == .transportWriteFailed }) {
            throw DiagnosticAuditError.conflictingWriteOutcome(attemptID)
        }
        guard attempt.events.contains(where: { $0.stage == .transportWriteStarted }) else {
            throw invalidTransition(attemptID, attempt, to: .transportWriteCompleted)
        }
        return try appendEvent(attemptID: attemptID, stage: .transportWriteCompleted, at: timestamp)
    }

    /// A thrown write may have delivered some bytes; it is evidence of an error,
    /// not evidence that the request was unsent.
    @discardableResult
    public mutating func transportWriteFailed(
        attemptID: UUID,
        reasonCode: String,
        reason: String? = nil,
        at timestamp: DiagnosticAuditTimestamp
    ) throws -> DiagnosticAuditEvent? {
        guard let attempt = attemptsByID[attemptID] else { throw DiagnosticAuditError.missingAttempt(attemptID) }
        if let previous = attempt.events.last(where: { $0.stage == .transportWriteFailed }) {
            guard previous.reasonCode == reasonCode, previous.reason == reason else {
                throw DiagnosticAuditError.conflictingWriteOutcome(attemptID)
            }
            return nil
        }
        if attempt.events.contains(where: { $0.stage == .transportWriteCompleted }) {
            throw DiagnosticAuditError.conflictingWriteOutcome(attemptID)
        }
        guard attempt.events.contains(where: { $0.stage == .transportWriteStarted }), !reasonCode.isEmpty else {
            throw invalidTransition(attemptID, attempt, to: .transportWriteFailed)
        }
        return try appendEvent(
            attemptID: attemptID, stage: .transportWriteFailed, at: timestamp,
            reasonCode: reasonCode, reason: reason
        )
    }

    @discardableResult
    public mutating func succeeded(
        attemptID: UUID,
        responseSequence: UInt64,
        responseReceivedAt: DiagnosticAuditTimestamp,
        at timestamp: DiagnosticAuditTimestamp
    ) throws -> DiagnosticAuditEvent? {
        try terminalize(
            attemptID: attemptID, outcome: .succeeded, reasonCode: nil, reason: nil,
            responseSequence: responseSequence, responseReceivedAt: responseReceivedAt, at: timestamp
        )
    }

    @discardableResult
    public mutating func failed(
        attemptID: UUID,
        reasonCode: String,
        reason: String? = nil,
        at timestamp: DiagnosticAuditTimestamp
    ) throws -> DiagnosticAuditEvent? {
        try terminalize(
            attemptID: attemptID, outcome: .failed, reasonCode: reasonCode, reason: reason,
            responseSequence: nil, responseReceivedAt: nil, at: timestamp
        )
    }

    @discardableResult
    public mutating func cancelled(
        attemptID: UUID,
        reasonCode: String,
        reason: String? = nil,
        at timestamp: DiagnosticAuditTimestamp
    ) throws -> DiagnosticAuditEvent? {
        try terminalize(
            attemptID: attemptID, outcome: .cancelled, reasonCode: reasonCode, reason: reason,
            responseSequence: nil, responseReceivedAt: nil, at: timestamp
        )
    }

    /// Ends the recording copy only. The acquisition ledger has its own scope and remains live.
    public mutating func closeRecordingWindow(
        at timestamp: DiagnosticAuditTimestamp
    ) throws -> [DiagnosticAuditEvent] {
        guard scope.isRecordingWindow else { throw DiagnosticAuditError.scopeMismatch }
        guard !isClosed else { return [] }
        var terminalEvents: [DiagnosticAuditEvent] = []
        let queuedAttemptIDs = attemptOrder
        for attemptID in queuedAttemptIDs {
            guard let attempt = attemptsByID[attemptID], !attempt.isTerminal else { continue }
            if let event = try terminalize(
                attemptID: attemptID, outcome: .recordingWindowClosed,
                reasonCode: "recording_window_closed", reason: nil,
                responseSequence: nil, responseReceivedAt: nil, at: timestamp
            ) {
                terminalEvents.append(event)
            }
        }
        isClosed = true
        return terminalEvents
    }

    /// Closes matching attempts on connection stop. A recording-window ledger may continue
    /// across reconnects; an acquisition ledger is bound to one connection generation.
    public mutating func stopConnection(
        _ connectionID: UUID,
        at timestamp: DiagnosticAuditTimestamp,
        reason: String = "Adapter connection stopped"
    ) throws -> [DiagnosticAuditEvent] {
        try closeConnection(
            connectionID, outcome: .cancelled, code: "connection_stopped", reason: reason,
            at: timestamp
        )
    }

    public mutating func connectionLost(
        _ connectionID: UUID,
        at timestamp: DiagnosticAuditTimestamp,
        reason: String = "Adapter connection lost"
    ) throws -> [DiagnosticAuditEvent] {
        try closeConnection(
            connectionID, outcome: .failed, code: "connection_lost", reason: reason,
            at: timestamp
        )
    }

    private mutating func closeConnection(
        _ connectionID: UUID,
        outcome: DiagnosticAuditOutcome,
        code: String,
        reason: String,
        at timestamp: DiagnosticAuditTimestamp
    ) throws -> [DiagnosticAuditEvent] {
        if case .acquisition(let scopedConnectionID) = scope, scopedConnectionID != connectionID {
            throw DiagnosticAuditError.scopeMismatch
        }
        var terminalEvents: [DiagnosticAuditEvent] = []
        let queuedAttemptIDs = attemptOrder
        for attemptID in queuedAttemptIDs {
            guard let attempt = attemptsByID[attemptID],
                  attempt.context.connectionID == connectionID, !attempt.isTerminal else { continue }
            if let event = try terminalize(
                attemptID: attemptID, outcome: outcome, reasonCode: code, reason: reason,
                responseSequence: nil, responseReceivedAt: nil, at: timestamp
            ) {
                terminalEvents.append(event)
            }
        }
        if case .acquisition = scope { isClosed = true }
        return terminalEvents
    }

    private mutating func appendStage(
        attemptID: UUID,
        stage: DiagnosticAuditStage,
        at timestamp: DiagnosticAuditTimestamp
    ) throws -> DiagnosticAuditEvent? {
        guard let attempt = attemptsByID[attemptID] else { throw DiagnosticAuditError.missingAttempt(attemptID) }
        if attempt.isTerminal {
            if stage == .started && attempt.events.contains(where: { $0.stage == stage }) { return nil }
            if stage == .transportWriteStarted && attempt.events.contains(where: { $0.stage == stage }) { return nil }
            throw invalidTransition(attemptID, attempt, to: stage)
        }
        if attempt.events.contains(where: { $0.stage == stage }) { return nil }
        guard attempt.events.last?.stage == .queued || (stage == .transportWriteStarted && attempt.events.last?.stage == .started) else {
            throw invalidTransition(attemptID, attempt, to: stage)
        }
        if stage == .started, attempt.events.last?.stage != .queued {
            throw invalidTransition(attemptID, attempt, to: stage)
        }
        if stage == .transportWriteStarted, attempt.events.last?.stage != .started {
            throw invalidTransition(attemptID, attempt, to: stage)
        }
        return try appendEvent(attemptID: attemptID, stage: stage, at: timestamp)
    }

    private mutating func terminalize(
        attemptID: UUID,
        outcome: DiagnosticAuditOutcome,
        reasonCode: String?,
        reason: String?,
        responseSequence: UInt64?,
        responseReceivedAt: DiagnosticAuditTimestamp?,
        at timestamp: DiagnosticAuditTimestamp
    ) throws -> DiagnosticAuditEvent? {
        guard let attempt = attemptsByID[attemptID] else { throw DiagnosticAuditError.missingAttempt(attemptID) }
        if let existing = attempt.terminalEvent {
            let sameResult = existing.terminalOutcome == outcome
                && existing.reasonCode == reasonCode
                && existing.reason == reason
                && existing.responseSequence == responseSequence
                && existing.responseReceivedAt == responseReceivedAt
            if sameResult { return nil }
            throw DiagnosticAuditError.conflictingTerminal(
                attemptID, existing: existing.terminalOutcome ?? .failed, received: outcome
            )
        }
        if outcome == .succeeded,
           !attempt.events.contains(where: { $0.stage == .transportWriteStarted }) {
            throw invalidTransition(attemptID, attempt, to: .terminal)
        }
        if (outcome == .failed || outcome == .cancelled), reasonCode?.isEmpty != false {
            throw invalidTransition(attemptID, attempt, to: .terminal)
        }
        if outcome == .recordingWindowClosed, !scope.isRecordingWindow {
            throw DiagnosticAuditError.scopeMismatch
        }
        return try appendEvent(
            attemptID: attemptID, stage: .terminal, at: timestamp,
            outcome: outcome, writeDisposition: attempt.currentWriteDisposition,
            reasonCode: reasonCode, reason: reason,
            responseSequence: responseSequence, responseReceivedAt: responseReceivedAt
        )
    }

    private func invalidTransition(
        _ attemptID: UUID, _ attempt: DiagnosticAuditAttempt, to stage: DiagnosticAuditStage
    ) -> DiagnosticAuditError {
        .invalidTransition(attemptID, from: attempt.events.last?.stage, to: stage)
    }

    private func validate(context: DiagnosticAuditContext) throws {
        if case .acquisition(let connectionID) = scope,
           context.connectionID != connectionID {
            throw DiagnosticAuditError.scopeMismatch
        }
    }

    private func makeEvent(
        attemptID: UUID,
        ordinal: Int,
        query: OBDQueryDefinition,
        context: DiagnosticAuditContext,
        stage: DiagnosticAuditStage,
        at timestamp: DiagnosticAuditTimestamp,
        outcome: DiagnosticAuditOutcome? = nil,
        writeDisposition: DiagnosticAuditWriteDisposition? = nil,
        reasonCode: String? = nil,
        reason: String? = nil,
        responseSequence: UInt64? = nil,
        responseReceivedAt: DiagnosticAuditTimestamp? = nil
    ) -> DiagnosticAuditEvent {
        DiagnosticAuditEvent(
            scope: scope, attemptID: attemptID, ordinal: ordinal, query: query,
            context: context, stage: stage, timestamp: timestamp,
            terminalOutcome: outcome, writeDispositionAtTermination: writeDisposition,
            reasonCode: reasonCode, reason: reason, responseSequence: responseSequence,
            responseReceivedAt: responseReceivedAt
        )
    }

    private mutating func appendEvent(
        attemptID: UUID,
        stage: DiagnosticAuditStage,
        at timestamp: DiagnosticAuditTimestamp,
        outcome: DiagnosticAuditOutcome? = nil,
        writeDisposition: DiagnosticAuditWriteDisposition? = nil,
        reasonCode: String? = nil,
        reason: String? = nil,
        responseSequence: UInt64? = nil,
        responseReceivedAt: DiagnosticAuditTimestamp? = nil
    ) throws -> DiagnosticAuditEvent {
        var attempt = attemptsByID[attemptID]!
        if let previous = attempt.events.last,
           timestamp.monotonicNanoseconds < previous.timestamp.monotonicNanoseconds {
            throw DiagnosticAuditError.timestampOrder(attemptID)
        }
        let event = makeEvent(
            attemptID: attemptID, ordinal: attempt.events.count + 1,
            query: attempt.query, context: attempt.context, stage: stage, at: timestamp,
            outcome: outcome, writeDisposition: writeDisposition,
            reasonCode: reasonCode, reason: reason,
            responseSequence: responseSequence, responseReceivedAt: responseReceivedAt
        )
        try event.validate()
        attempt.append(event)
        attemptsByID[attemptID] = attempt
        pruneCompletedHistory()
        return event
    }

    private mutating func pruneCompletedHistory() {
        let resolvedAttempts = attemptOrder.filter { attemptID in
            guard let attempt = attemptsByID[attemptID], attempt.isTerminal else { return false }
            return attempt.currentWriteDisposition != .inFlight
        }
        let excessCount = max(0, resolvedAttempts.count - completedAttemptHistoryLimit)
        guard excessCount > 0 else { return }
        for attemptID in resolvedAttempts.prefix(excessCount) {
            attemptsByID.removeValue(forKey: attemptID)
            attemptOrder.removeAll { $0 == attemptID }
            droppedAttemptCount += 1
        }
    }
}
