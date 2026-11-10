import Foundation

/// Preparation only. No I/O or recorder ownership is implemented here.
/// All events must be serialized by the adapter. Create with a fresh process UUID.
public struct RecordingTriggerPolicy: Sendable {
    public enum State: String, Sendable { case off, armed, startPending, recording, stopPending, uncertain, manual }
    public enum Action: String, Sendable { case start, stop }
    public enum Reason: String, Sendable { case qualifiedTelemetry, explicitStop, telemetryInactive, permissionRevoked }
    public struct Intent: Equatable, Sendable {
        public let action: Action
        public let reason: Reason
        public let instance: String
        public let source: String
        public let session: String
        public let generation: UInt64
        public let nonce: UInt64
    }
    public let instance: String
    public let source: String
    public let session: String
    public private(set) var state: State = .off
    public private(set) var generation: UInt64 = 0
    public private(set) var permitted: Bool
    public private(set) var connected = false
    private var nonce: UInt64 = 0
    private var pending: Intent?
    private var deadline: Double?
    private var inactivity: Double?
    private var lastSample: Double?
    private var armedAt: Double?
    private var lastTime: Double?

    public init?(instance: String, source: String, session: String, permitted: Bool = false) {
        guard [instance, source, session].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        self.instance = instance; self.source = source; self.session = session; self.permitted = permitted
    }
    private mutating func invalidate() {
        // Exhaustion permanently fences this coordinator; never wrap a token.
        if generation < UInt64.max { generation += 1 }
        if state == .startPending || state == .stopPending { state = .uncertain }
        else if state == .armed { state = .off }
        pending = nil; deadline = nil; inactivity = nil; armedAt = nil
    }
    private mutating func time(_ now: Double) -> Bool {
        guard now.isFinite, now >= 0, lastTime.map({ now >= $0 }) ?? true else { invalidate(); return false }
        lastTime = now
        if pending != nil, let deadline, now >= deadline { invalidate() }
        return true
    }
    public mutating func reconnect(now: Double) {
        guard time(now) else { return }; invalidate(); connected = true
    }
    public mutating func disconnect(now: Double) {
        _ = time(now); invalidate(); connected = false
    }
    @discardableResult public mutating func arm(now: Double, explicit: Bool = false, inactivity: Double? = nil) -> Bool {
        guard time(now), explicit, connected, permitted, state == .off, generation < UInt64.max,
              inactivity.map({ $0.isFinite && $0 > 0 }) ?? true else { return false }
        generation += 1; state = .armed; armedAt = now; self.inactivity = inactivity; lastSample = nil
        return true
    }
    public mutating func disarm(now: Double) { _ = time(now); invalidate() }
    private mutating func intent(_ action: Action, _ reason: Reason, _ now: Double) -> Intent? {
        guard nonce < UInt64.max, generation < UInt64.max else { invalidate(); state = .uncertain; return nil }
        nonce += 1
        let result = Intent(action: action, reason: reason, instance: instance, source: source, session: session, generation: generation, nonce: nonce)
        pending = result; deadline = now + 10; state = action == .start ? .startPending : .stopPending
        return result
    }
    public mutating func telemetry(now: Double, captured: Double, source: String, session: String, generation: UInt64, quality: String, values: [Double], demo: Bool = false) -> Intent? {
        guard time(now), connected, permitted, state == .armed || state == .recording,
              source == self.source, session == self.session, generation == self.generation,
              quality == "qualified", !demo, !values.isEmpty, values.allSatisfy({ $0.isFinite }),
              captured.isFinite, now - captured >= 0, now - captured <= 2,
              let armedAt, captured >= armedAt, lastSample.map({ captured > $0 }) ?? true else { return nil }
        lastSample = captured
        return state == .armed ? intent(.start, .qualifiedTelemetry, now) : nil
    }
    @discardableResult public mutating func ack(_ value: Intent, accepted: Bool, now: Double) -> Bool {
        guard time(now), let pending, value == pending else { return false }
        self.pending = nil; deadline = nil
        if value.action == .start {
            state = accepted ? .recording : .off
            if !accepted { inactivity = nil; armedAt = nil }
        } else {
            state = accepted ? .off : .recording
            inactivity = nil; armedAt = nil
        }
        return true
    }
    public mutating func stop(now: Double, reason: Reason = .explicitStop) -> Intent? {
        guard time(now), state == .recording else { return nil }
        return intent(.stop, reason, now)
    }
    public mutating func tick(now: Double) -> Intent? {
        guard time(now) else { return nil }
        if state == .recording, let inactivity, let lastSample, now - lastSample >= inactivity {
            return stop(now: now, reason: .telemetryInactive)
        }
        return nil
    }
    public mutating func permission(_ allowed: Bool, now: Double) -> Intent? {
        let valid = time(now)
        guard allowed != permitted else { return nil }
        permitted = allowed
        if !allowed { invalidate(); if valid { return stop(now: now, reason: .permissionRevoked) } }
        return nil
    }
    /// Authoritative recorder observation, not a request to claim manual ownership.
    public mutating func manual(_ active: Bool, now: Double) {
        _ = time(now); invalidate()
        if active { state = .manual } else if state == .manual { state = .off }
    }
    /// Only after native executor fences old requests AND confirms actual recorder idle.
    @discardableResult public mutating func confirmIdle(instance: String, generation: UInt64, now: Double) -> Bool {
        guard time(now), instance == self.instance, generation == self.generation, state == .uncertain else { return false }
        state = .off; invalidate(); return true
    }
    /// Revalidate atomically at the executor boundary, alongside actual recorder ownership.
    public mutating func canExecute(_ value: Intent, now: Double) -> Bool {
        guard time(now), let pending, value == pending else { return false }
        if value.action == .start {
            guard connected, permitted, let lastSample else { return false }
            return now - lastSample >= 0 && now - lastSample <= 2
        }
        return state == .stopPending
    }

}
