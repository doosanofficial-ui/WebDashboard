import Foundation

/// UITest-only call observations. These timestamps do not prove Home delivery or OS lifecycle state.
final class HomeStateObservation {
    enum Boundary: String {
        case homeRequested, homeReturned, waitRequested, waitReturned
    }

    private final class Query {
        let label: String
        let requested: TimeInterval
        var returned: TimeInterval?
        var rawValue: String?
        init(label: String, requested: TimeInterval) {
            self.label = label
            self.requested = requested
        }
    }

    private let now: () -> TimeInterval
    private let lock = NSLock()
    private var boundaries: [String: TimeInterval] = [:]
    private var queries: [Query] = []
    private var omitted = 0

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func mark(_ boundary: Boundary) {
        let observed = now()
        lock.lock()
        boundaries[boundary.rawValue] = observed
        lock.unlock()
    }

    /// Executes exactly the original read, preserving its result and the caller's short circuit.
    func readState<State: RawRepresentable>(_ label: String, _ read: () -> State) -> State {
        let query = Query(label: label, requested: now())
        lock.lock()
        if queries.count == 64 {
            queries.removeFirst()
            omitted = min(omitted, Int.max - 1) + 1
        }
        queries.append(query)
        lock.unlock()
        let state = read()
        let returned = now()
        lock.lock()
        query.returned = returned
        query.rawValue = String(describing: state.rawValue)
        lock.unlock()
        return state
    }

    func json() -> String {
        lock.lock()
        let snapshot: [String: Any] = ["schemaVersion": 1, "boundaries": boundaries,
            "stateQueries": queries.map { query -> [String: Any] in
                ["label": query.label, "requestedUptime": query.requested,
                 "returnedUptime": query.returned.map { $0 as Any } ?? NSNull(),
                 "rawValue": query.rawValue.map { $0 as Any } ?? NSNull()]
            }, "omittedStateQueries": omitted,
            "clockScope": "ProcessInfo.systemUptime call observations; null return/value means not observed returned at this snapshot. Not notification delivery or independent OS state."]
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"observationUnavailable\":true}"
        }
        return text
    }
}
