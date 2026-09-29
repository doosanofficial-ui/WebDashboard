import Foundation

/// Orders recording submissions at the main-actor call boundary, before they
/// become asynchronous tasks. SQLite remains on MeasurementRecorder's actor.
/// The queue is independent of Dashboard visibility and has bounded admission.
@MainActor
public final class MeasurementWriteQueue {
    public enum State: Equatable, Sendable {
        case accepting, closing, closed, failed
    }

    public private(set) var state: State = .accepting
    public private(set) var pendingEventCount = 0
    private let recorder: MeasurementRecorder
    private let maximumPendingEvents: Int
    private var tail: Task<Void, Error>?
    private var closeTask: Task<Void, Error>?
    private var firstFailure: Error?

    public init(recorder: MeasurementRecorder, maximumPendingEvents: Int = 4096) throws {
        guard maximumPendingEvents > 0 else { throw TelemetryError.invalidBatch }
        self.recorder = recorder
        self.maximumPendingEvents = maximumPendingEvents
    }

    @discardableResult
    public func enqueue(_ event: MeasurementEvent) throws -> Task<Void, Error> {
        try enqueue(contentsOf: [event])
    }

    @discardableResult
    public func enqueue(contentsOf events: [MeasurementEvent]) throws -> Task<Void, Error> {
        guard state == .accepting else { throw firstFailure ?? TelemetryError.eventConflict }
        guard !events.isEmpty else { throw TelemetryError.invalidBatch }
        guard events.count <= maximumPendingEvents - pendingEventCount else {
            rememberFailure(TelemetryError.queueFull)
            throw TelemetryError.queueFull
        }
        let previous = tail
        pendingEventCount += events.count
        let task = Task { @MainActor [self] in
            defer { pendingEventCount -= events.count }
            do {
                try await previous?.value
                try Task.checkCancellation()
                try await recorder.append(contentsOf: events)
            } catch {
                rememberFailure(error)
                throw error
            }
        }
        tail = task
        return task
    }

    /// Waits for submissions already accepted at this call boundary. If Stop
    /// is pending, export also waits for its terminal marker and metadata.
    public func drain() async throws {
        let boundary = closeTask ?? tail
        try await boundary?.value
        if let firstFailure { throw firstFailure }
    }

    /// Closes admission synchronously, drains accepted writes, and commits one
    /// terminal boundary. Even after a failed write the file is retained and a
    /// failure marker is attempted; callers never receive a false clean close.
    @discardableResult
    public func finish(endedAt: Double, monotonicNanos: UInt64) -> Task<Void, Error> {
        if let closeTask { return closeTask }
        if firstFailure == nil { state = .closing }
        let previous = tail
        let task = Task { @MainActor [self] in
            if let previous {
                if case .failure(let error) = await previous.result { rememberFailure(error) }
            }
            do {
                let name = firstFailure == nil ? "recording_stopped" : "recording_failed"
                try await recorder.finish(endedAt: endedAt, terminalEvent: .system(
                    name: name, timestamp: endedAt, monotonicNanos: monotonicNanos
                ))
            } catch {
                rememberFailure(error)
            }
            if let firstFailure { throw firstFailure }
            state = .closed
        }
        closeTask = task
        return task
    }

    private func rememberFailure(_ error: Error) {
        if firstFailure == nil { firstFailure = error }
        state = .failed
    }
}
