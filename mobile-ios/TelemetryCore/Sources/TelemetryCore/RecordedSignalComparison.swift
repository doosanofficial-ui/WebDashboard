import Foundation

/// A bounded display of existing recorded histories, without resampling or acquisition.
public struct RecordedSignalComparison: Sendable {
    public struct Selection: Equatable, Sendable {
        public private(set) var sessionID: String?
        public private(set) var availableSignalIDs: [String] = []
        public private(set) var secondarySignalID: String?
        private var comparisonPrimarySignalID: String?

        public init() {}

        /// Keep discovered identities when a backward seek predates a signal.
        /// Only a session change (or stop) clears the user's comparison.
        public mutating func observe(sessionID: String?, signalIDs: [String]) {
            if self.sessionID != sessionID || sessionID == nil {
                self.sessionID = sessionID
                availableSignalIDs = []
                secondarySignalID = nil
                comparisonPrimarySignalID = nil
            }
            guard sessionID != nil else { return }
            availableSignalIDs = RecordedSignalComparison.uniqueSignalIDs(availableSignalIDs + signalIDs)
        }

        public mutating func selectSecondary(_ id: String?, primarySignalID: String?) {
            guard let id, let primarySignalID, id != primarySignalID,
                  availableSignalIDs.contains(primarySignalID), availableSignalIDs.contains(id) else {
                secondarySignalID = nil
                comparisonPrimarySignalID = nil
                return
            }
            secondarySignalID = id
            comparisonPrimarySignalID = primarySignalID
        }

        public func signalIDs(primarySignalID: String?) -> [String] {
            guard let primarySignalID = primarySignalID ?? comparisonPrimarySignalID,
                  availableSignalIDs.contains(primarySignalID) else { return [] }
            let secondary = secondarySignalID.flatMap { availableSignalIDs.contains($0) ? $0 : nil }
            return RecordedSignalComparison.normalizedSignalIDs([primarySignalID, secondary].compactMap { $0 })
        }
    }

    public struct Series: Identifiable, Sendable {
        public var id: String { signalID }
        public let signalID: String
        public let history: MeasurementReplay.SignalHistory?
        public let cursorState: LatestSignalState?
        public let cursorFreshness: MeasurementReplay.SignalFreshness?
        public var units: [String] { Array(Set(history?.samples.map(\.unit) ?? [])).sorted() }
    }

    public let position: Double
    public let series: [Series]

    public static func normalizedSignalIDs(_ ids: [String]) -> [String] { Array(uniqueSignalIDs(ids).prefix(2)) }

    private static func uniqueSignalIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
    }

    /// The caller supplies the controller's accepted position and snapshot together.
    /// Histories come from its existing timeline, never a second replay engine.
    public init(sessionID: String, signalIDs: [String], at position: Double,
                snapshot: MeasurementReplay.Snapshot,
                historyProvider: (String) throws -> MeasurementReplay.SignalHistory?) throws {
        guard !sessionID.isEmpty, position.isFinite, position >= 0 else { throw MeasurementReplayError.invalidExport }
        self.position = position
        var windowStart: Double?
        series = try Self.normalizedSignalIDs(signalIDs).map { id in
            let history = try historyProvider(id)
            if let history {
                guard history.startSeconds.isFinite, history.endSeconds == position,
                      history.startSeconds >= 0, history.startSeconds <= position,
                      history.samples.count <= 600, history.totalSamplesInWindow >= history.samples.count,
                      windowStart.map({ $0 == history.startSeconds }) ?? true,
                      history.samples.allSatisfy({ $0.elapsedSeconds.isFinite && $0.value.isFinite &&
                          $0.elapsedSeconds >= history.startSeconds && $0.elapsedSeconds <= position }) else {
                    throw MeasurementReplayError.invalidExport
                }
                guard history.samples.allSatisfy({ $0.measurement.sessionID == sessionID }) else {
                    throw MeasurementReplayError.sessionMismatch
                }
                windowStart = history.startSeconds
            }
            let state = snapshot.signals.first { $0.signalID == id }
            return Series(signalID: id, history: history, cursorState: state,
                cursorFreshness: state == nil ? nil : (snapshot.signalFreshness[id] ?? .unknown))
        }
    }
}
