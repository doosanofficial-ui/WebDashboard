import Foundation

/// Pure presentation suggestions. No networking, GPS inference, UI, speech or audio-session effects.
/// Provider trust is a caller precondition, not established by the `verified` flag itself.
public struct GuidancePresentation {
    public struct Policy {
        public let maximumAge: Double
        public let cooldown: Double
        public let focusDuration: Double
        public let nearDistance: Double
        public init?(maximumAge: Double = 5, cooldown: Double = 5,
                     focusDuration: Double = 8, nearDistance: Double = 150) {
            guard [maximumAge, cooldown, focusDuration, nearDistance].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            self.maximumAge = maximumAge; self.cooldown = cooldown
            self.focusDuration = focusDuration; self.nearDistance = nearDistance
        }
    }
    public enum Stage { case approach, atTurn, completed }
    public enum Direction: String { case left, right, straight, uTurn }
    public struct Progress {
        public let session: String
        public let generation: UInt64
        public let route: String
        public let maneuver: String
        public let sequence: Int
        public let observedAt: Double
        public let verified: Bool
        public let distanceMeters: Double
        public let confidence: Double
        public let stage: Stage
        public let direction: Direction
        public init(session: String, generation: UInt64, route: String, maneuver: String,
                    sequence: Int, observedAt: Double, verified: Bool, distanceMeters: Double,
                    confidence: Double, stage: Stage, direction: Direction) {
            self.session = session; self.generation = generation; self.route = route
            self.maneuver = maneuver; self.sequence = sequence; self.observedAt = observedAt
            self.verified = verified; self.distanceMeters = distanceMeters; self.confidence = confidence
            self.stage = stage; self.direction = direction
        }
    }
    public enum Suggestion: Equatable {
        case focusMap(maneuver: String, expiresAt: Double)
        case restoreLayout
        /// Numeric argument remains meters; localization owns pluralization, units and spoken rendering.
        case prompt(localizationKey: String, distanceMeters: Double)
    }
    private struct Binding: Equatable { let session: String; let generation: UInt64; let route: String }
    private struct PromptKey: Hashable { let maneuver: String; let stage: Int }
    private let policy: Policy
    private var voice = false
    private var layout = false
    private var clock: Double = 0
    private var generation: UInt64 = 0
    private var active: Binding?
    private var focus: (maneuver: String, expiresAt: Double)?
    private var sequence = -1
    private var observed: Double = -1
    private var lastPrompt: Double?
    private var seen: Set<PromptKey> = []
    private var focused: Set<String> = []
    private var completed: Set<String> = []
    private var turns: Set<String> = []
    public init(policy: Policy) { self.policy = policy }
    private static func validID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        return (1...128).contains(bytes.count) && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private mutating func restore() -> [Suggestion] {
        guard focus != nil else { return [] }
        focus = nil; return [.restoreLayout]
    }
    public mutating func configure(voice: Bool, layout: Bool) -> [Suggestion] {
        self.voice = voice; self.layout = layout
        return layout ? [] : restore()
    }
    /// Use for stop, cancel, suspend, reroute invalidation, session loss and provider failure.
    public mutating func stop() -> [Suggestion] { active = nil; return restore() }
    /// Only call after exact authenticated lifecycle `start`; generation is strictly increasing
    /// across the lifetime of this object, including session changes. Old generations cannot restart.
    public mutating func activate(session: String, generation: UInt64, route: String, now: Double) -> [Suggestion] {
        guard now.isFinite, now >= clock, generation > self.generation,
              Self.validID(session), Self.validID(route) else { return [] }
        let result = restore(); clock = now; self.generation = generation
        active = Binding(session: session, generation: generation, route: route)
        sequence = -1; observed = -1; lastPrompt = nil; seen = []; focused = []; completed = []; turns = []
        return result
    }
    /// Caller must schedule ticks and honor focus expiry even without new progress.
    public mutating func tick(now: Double) -> [Suggestion] {
        guard now.isFinite, now >= clock else { return restore() }
        clock = now
        if let focus, now >= focus.expiresAt || now - observed > policy.maximumAge { return restore() }
        return []
    }
    public mutating func update(_ p: Progress, now: Double) -> [Suggestion] {
        guard now.isFinite, now >= clock else { return restore() }
        clock = now
        guard active == Binding(session: p.session, generation: p.generation, route: p.route),
              p.verified, Self.validID(p.maneuver), p.sequence >= 0, p.sequence > sequence,
              p.observedAt.isFinite, p.observedAt >= 0, p.observedAt >= observed,
              p.observedAt <= now, now - p.observedAt <= policy.maximumAge,
              p.distanceMeters.isFinite, p.distanceMeters >= 0,
              p.confidence.isFinite, (0.9...1).contains(p.confidence) else { return restore() }
        sequence = p.sequence; observed = p.observedAt
        var result: [Suggestion] = []
        if let focus, focus.maneuver != p.maneuver || now >= focus.expiresAt { result += restore() }
        if p.stage == .approach, turns.contains(p.maneuver) { return result + restore() }
        if p.stage == .atTurn {
            if turns.count >= 256, !turns.contains(p.maneuver) { return result + restore() }
            turns.insert(p.maneuver)
        }
        if p.stage == .completed {
            if completed.count < 256 { completed.insert(p.maneuver) } else { active = nil }
            return result + restore()
        }
        if completed.contains(p.maneuver) || p.distanceMeters > policy.nearDistance { return result + restore() }
        if layout, !focused.contains(p.maneuver), focused.count < 256, (now + policy.focusDuration).isFinite {
            focus = (p.maneuver, now + policy.focusDuration); focused.insert(p.maneuver)
            result.append(.focusMap(maneuver: p.maneuver, expiresAt: now + policy.focusDuration))
        }
        let key = PromptKey(maneuver: p.maneuver, stage: p.stage == .atTurn ? 1 : 0)
        if voice, !seen.contains(key), seen.count < 256,
           lastPrompt.map({ now - $0 >= policy.cooldown }) ?? true {
            seen.insert(key); lastPrompt = now
            let stage = p.stage == .atTurn ? "now" : "approach"
            result.append(.prompt(localizationKey: "guidance.turn.\(stage).\(p.direction.rawValue)", distanceMeters: p.distanceMeters))
        }
        return result
    }
}
