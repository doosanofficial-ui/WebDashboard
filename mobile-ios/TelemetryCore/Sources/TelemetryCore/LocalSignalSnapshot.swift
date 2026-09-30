import Foundation

public enum LocalSignalSnapshotError: Error, Equatable, Sendable {
    case invalidUpdate
    case tooManySignals
}

/// Latest values for display, not a measurement stream. A different signal's
/// arrival never changes an existing signal's original receive timestamp.
/// Recorder and chart consumers must continue using the unmerged input events.
public struct LocalSignalSnapshot: Equatable, Sendable {
    public private(set) var values: [String: Double] = [:]
    public private(set) var receivedAtEpoch: [String: Double] = [:]
    public private(set) var source: String?

    public init() {}

    public mutating func merge(_ update: [String: Double], receivedAt: Double, source: String) throws {
        guard receivedAt.isFinite, !source.isEmpty, !update.isEmpty,
              update.allSatisfy({ key, value in
                  !key.isEmpty && key.utf8.count <= 128 && !key.contains("\0") && value.isFinite
              }) else { throw LocalSignalSnapshotError.invalidUpdate }
        // Follow callback order, not wall-clock order: device clock adjustments
        // must not cause a new measurement to be discarded or retimestamped.
        var nextValues = self.source == source ? values : [:]
        var nextTimes = self.source == source ? receivedAtEpoch : [:]
        nextValues.merge(update) { _, new in new }
        // Match the existing ServerCANFrame snapshot contract. Reject the
        // update atomically instead of silently evicting an unrelated signal.
        guard nextValues.count <= 256 else { throw LocalSignalSnapshotError.tooManySignals }
        for key in update.keys { nextTimes[key] = receivedAt }
        values = nextValues
        receivedAtEpoch = nextTimes
        self.source = source
    }

    public mutating func reset() {
        values.removeAll()
        receivedAtEpoch.removeAll()
        source = nil
    }
}
