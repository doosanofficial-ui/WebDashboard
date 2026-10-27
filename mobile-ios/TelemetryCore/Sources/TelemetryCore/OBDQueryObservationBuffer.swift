import Foundation

/// Bounded companion to the existing outcome stream. Metadata loss makes this
/// connection's capability projection unavailable; it never changes polling.
public final class OBDQueryObservationBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var values: [OBDQueryObservation] = []
    private var unavailable = false
    private var lastOrdinal: UInt64 = 0

    public init(capacity: Int = 512) { self.capacity = max(1, capacity) }

    public func append(_ observation: OBDQueryObservation) {
        lock.lock(); defer { lock.unlock() }
        guard !unavailable else { return }
        guard values.count < capacity, observation.ordinal == lastOrdinal + 1 else {
            values.removeAll(); unavailable = true; return
        }
        lastOrdinal = observation.ordinal
        values.append(observation)
    }

    public func take(for outcome: OBDQueryOutcome) -> OBDQueryObservation? {
        lock.lock(); defer { lock.unlock() }
        guard !unavailable, let first = values.first, first.outcome == outcome else {
            values.removeAll(); unavailable = true; return nil
        }
        values.removeFirst()
        return first
    }

    public var isUnavailable: Bool {
        lock.lock(); defer { lock.unlock() }; return unavailable
    }
}
