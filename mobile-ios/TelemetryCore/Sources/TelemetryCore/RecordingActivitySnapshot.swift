import Foundation

/// A small, display-only projection. Never use this as recording or acquisition state.
public struct RecordingActivitySnapshot: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable { case recording, stopped, interrupted }
    public struct Reading: Codable, Hashable, Sendable {
        public let name: String
        public let unit: String
        public let value: String?
    }
    public struct Input: Sendable {
        public let id: String
        public let name: String
        public let unit: String
        public let value: Double?
        public let receivedAt: Double?
        public let timeout: Double
        public init(id: String, name: String, unit: String, value: Double?, receivedAt: Double?, timeout: Double) {
            self.id = id; self.name = name; self.unit = unit
            self.value = value; self.receivedAt = receivedAt; self.timeout = timeout
        }
    }
    public let phase: Phase
    public let readings: [Reading]
    public let sampledAt: Double
    public let validUntil: Double

    public static func make(selectedIDs: [String], inputs: [Input], startedAt: Double, now: Double) -> Self {
        let safeNow = now.isFinite && now >= 0 ? now : 0
        var deadline = safeNow + 15 // No unbounded assertion that recording is still active.
        var seen = Set<String>()
        let selected = selectedIDs.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(2)
        let readings = selected.map { id -> Reading in
            let input = inputs.first { $0.id == id }
            var formatted: String?
            if let input, let value = input.value, let received = input.receivedAt,
               now.isFinite, now >= 0, startedAt.isFinite, startedAt >= 0, startedAt <= now,
               value.isFinite, received.isFinite, received >= startedAt, received <= now,
               input.timeout.isFinite, input.timeout > 0,
               now - received < input.timeout {
                formatted = String(format: "%.4g", locale: Locale(identifier: "en_US_POSIX"), value)
                deadline = min(deadline, received + min(input.timeout, 15))
            }
            return Reading(name: bounded(input?.name ?? id, length: 32),
                           unit: bounded(input?.unit ?? "", length: 12), value: formatted)
        }
        return Self(phase: .recording, readings: readings, sampledAt: safeNow, validUntil: deadline)
    }

    public static func ended(at now: Double, interrupted: Bool) -> Self {
        let safeNow = now.isFinite && now >= 0 ? now : 0
        return Self(phase: interrupted ? .interrupted : .stopped, readings: [], sampledAt: safeNow, validUntil: safeNow)
    }

    private static func bounded(_ value: String, length: Int) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.lazy.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(length)))
    }
}

/// A REC session gets at most one attempt. Late updates, opt-out and dismissal
/// invalidate its generation; a new session may attempt independently.
public struct RecordingActivityLifecycle: Sendable {
    private var sessionID: String?
    private var generation: UUID?
    public init() {}
    public mutating func begin(sessionID: String, enabled: Bool, foreground: Bool, mode: TelemetryRunMode) -> UUID? {
        guard !sessionID.isEmpty, self.sessionID != sessionID else { return nil }
        self.sessionID = sessionID
        generation = nil
        guard enabled, foreground, mode != .replay else { return nil }
        let token = UUID()
        generation = token
        return token
    }
    public mutating func end() { generation = nil }
    public func isCurrent(_ token: UUID) -> Bool { generation == token }
}
