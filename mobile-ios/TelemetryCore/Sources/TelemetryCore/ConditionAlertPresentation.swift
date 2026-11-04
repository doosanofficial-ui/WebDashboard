/// Pure, bounded presentation state. Not safety monitoring or condition evaluation.
/// Serialize access in the adapter. A new source/session/configuration needs a new instance.
public struct ConditionAlertPresentation {
    public enum Domain: Equatable { case vehicle, synthetic }
    public struct Scope: Equatable {
        public let domain: Domain
        public let source: UInt64
        public let session: UInt64
        public let configuration: UInt64
        public init(domain: Domain, source: UInt64, session: UInt64, configuration: UInt64) {
            self.domain = domain; self.source = source; self.session = session; self.configuration = configuration
        }
    }
    public enum ID: Int, CaseIterable { case condition1 = 1, condition2, condition3, condition4, condition5, condition6, condition7, condition8 }
    public enum Severity: Int { case warning = 0, attention, information }
    public enum Category { case condition, diagnostic, telemetry }
    public enum State { case active, resolved, unknown, stale, disconnected }
    public struct Definition {
        public let id: ID
        public let severity: Severity
        public let category: Category
        public init(id: ID, severity: Severity, category: Category) {
            self.id = id; self.severity = severity; self.category = category
        }
    }
    public struct Change {
        public let id: ID
        public let state: State
        public init(id: ID, state: State) { self.id = id; self.state = state }
    }
    public struct Row {
        public let definition: Definition
        public let state: State
        /// Last explicitly evaluated result; true can coexist with stale/disconnected.
        public let lastConfirmedActive: Bool
    }
    public struct Snapshot {
        public let scope: Scope
        public let version: UInt64
        public let rows: [Row]
        /// Includes hidden rows and retained active evidence during unavailability.
        public let activeEvidenceCount: Int
        public let unavailableCount: Int
    }
    private struct Entry { var state: State = .unknown; var active = false; var visible = true }
    public let scope: Scope
    private let definitions: [Definition]
    private var entries: [ID: Entry]
    private var version: UInt64 = 0

    public init?(scope: Scope, definitions: [Definition]) {
        guard scope.source > 0, scope.session > 0, scope.configuration > 0,
              !definitions.isEmpty, definitions.count <= 8,
              Set(definitions.map(\.id)).count == definitions.count else { return nil }
        self.scope = scope
        self.definitions = definitions.sorted {
            $0.severity.rawValue == $1.severity.rawValue
                ? $0.id.rawValue < $1.id.rawValue : $0.severity.rawValue < $1.severity.rawValue
        }
        self.entries = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, Entry()) })
    }
    /// Delta, not a replacement snapshot. Omission never means resolution.
    /// One strictly increasing sequence across all conditions for this immutable scope.
    /// Validate the whole delta before committing it; rejected input consumes no version.
    @discardableResult
    public mutating func apply(scope: Scope, version: UInt64, changes: [Change]) -> Bool {
        guard scope == self.scope, version > self.version,
              !changes.isEmpty, changes.count <= 8,
              Set(changes.map(\.id)).count == changes.count,
              changes.allSatisfy({ entries[$0.id] != nil }) else { return false }
        for change in changes {
            guard var entry = entries[change.id] else { return false }
            switch change.state {
            case .active: entry.active = true
            case .resolved: entry.active = false
            case .unknown, .stale, .disconnected: break
            }
            entry.state = change.state
            entries[change.id] = entry
        }
        self.version = version
        return true
    }
    /// Presentation preference only; no transport, ECU or evaluation effect.
    @discardableResult
    public mutating func setVisible(_ visible: Bool, for id: ID) -> Bool {
        guard var entry = entries[id] else { return false }
        entry.visible = visible; entries[id] = entry
        return true
    }
    public func snapshot() -> Snapshot {
        let rows: [Row] = definitions.compactMap { definition in
            guard let entry = entries[definition.id], entry.visible, entry.state != .resolved else { return nil }
            return Row(definition: definition, state: entry.state, lastConfirmedActive: entry.active)
        }
        return Snapshot(scope: scope, version: version, rows: rows,
                        activeEvidenceCount: entries.values.filter(\.active).count,
                        unavailableCount: entries.values.filter { $0.state != .active && $0.state != .resolved }.count)
    }
}
