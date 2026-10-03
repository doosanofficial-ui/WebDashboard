import Foundation

/// Cancel-only handles deliberately expose no response, body file, credentials,
/// retry, acknowledgement, or task creation/resume API.
protocol LegacyBackgroundCancellationTask: AnyObject {
    func cancel()
}
protocol LegacyBackgroundCancellationSession: AnyObject {
    func allTasks(_ completion: @escaping ([LegacyBackgroundCancellationTask]) -> Void)
    func invalidateAndCancel()
}

/// One migration attempt per launch, shared by launch and background-event entry.
/// Completion means cancellation was requested, not proof of transport finality.
final class LocalOnlyBackgroundTaskCancellation {
    private enum Phase { case idle, enumerating, cancelling, completed }
    private let identifier: String
    private let makeSession: (String) -> LegacyBackgroundCancellationSession
    private let lock = NSLock()
    private var phase = Phase.idle
    private var completions: [() -> Void] = []

    init(identifier: String, makeSession: @escaping (String) -> LegacyBackgroundCancellationSession) {
        self.identifier = identifier
        self.makeSession = makeSession
    }

    func cancelLegacyTasks(identifier requested: String, completion: @escaping () -> Void) {
        guard requested == identifier else { completion(); return }
        lock.lock()
        if phase == .completed {
            lock.unlock()
            completion()
            return
        }
        completions.append(completion)
        guard phase == .idle else { lock.unlock(); return }
        phase = .enumerating
        lock.unlock()

        let session = makeSession(identifier)
        session.allTasks { [self] tasks in
            lock.lock()
            guard phase == .enumerating else { lock.unlock(); return }
            phase = .cancelling
            lock.unlock()
            // Never invoke task/session/client code under our bookkeeping lock.
            for task in tasks { task.cancel() }
            // Also cancels tasks not present in the enumeration snapshot.
            session.invalidateAndCancel()
            lock.lock()
            phase = .completed
            let callbacks = completions
            completions.removeAll()
            lock.unlock()
            for callback in callbacks { callback() }
        }
    }
}
