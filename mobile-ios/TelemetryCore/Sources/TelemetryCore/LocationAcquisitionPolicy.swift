import Foundation

public enum LocationPolicyUse: Sendable { case inactive, active, unknown }
public enum LocationPolicyMotion: Sendable { case low, moving, unknown }
public enum LocationPolicyProfile: Sendable { case preserve, lowMotionAdvisory }
public struct LocationPolicyRequirements: Sendable {
    public let recording: LocationPolicyUse
    public let navigation: LocationPolicyUse
    public let critical: LocationPolicyUse
    public init(recording: LocationPolicyUse = .unknown, navigation: LocationPolicyUse = .unknown,
                critical: LocationPolicyUse = .unknown) {
        self.recording = recording; self.navigation = navigation; self.critical = critical
    }
}
/// Caller supplies qualified ORIGINAL paired observations in one verified monotonic clock domain.
/// `low` is not parked, engine-off or driving evidence. No location or motion API is called.
public struct LocationPolicyEvidence: Sendable {
    public let scope: String
    public let generation: Int
    public let producer: String
    public let time: Double
    public let speed: Double
    public let speedAccuracy: Double
    public let horizontalAccuracy: Double
    public let motion: LocationPolicyMotion
    public let confidence: Double
    public let original: Bool
    public let motionTime: Double
    public let qualityAccepted: Bool
    public init(scope: String, generation: Int, producer: String, time: Double, speed: Double,
                speedAccuracy: Double, horizontalAccuracy: Double, motion: LocationPolicyMotion,
                confidence: Double, original: Bool, motionTime: Double, qualityAccepted: Bool) {
        self.scope = scope; self.generation = generation; self.producer = producer; self.time = time
        self.speed = speed; self.speedAccuracy = speedAccuracy; self.horizontalAccuracy = horizontalAccuracy
        self.motion = motion; self.confidence = confidence; self.original = original
        self.motionTime = motionTime; self.qualityAccepted = qualityAccepted
    }
}
/// A short-lived descriptive advisory, never hardware permission or an executable command.
/// Values are conservative product placeholders, NOT Core Location interval guarantees.
public struct LocationPolicyDecision: Sendable {
    public let profile: LocationPolicyProfile
    public let maximumInterval: Double?
    public let distance: Double?
    public let accuracy: Double?
    public let expires: Double?
    fileprivate init(profile: LocationPolicyProfile = .preserve, maximumInterval: Double? = nil,
                     distance: Double? = nil, accuracy: Double? = nil, expires: Double? = nil) {
        self.profile = profile; self.maximumInterval = maximumInterval
        self.distance = distance; self.accuracy = accuracy; self.expires = expires
    }
}
/// Serial-owner pure policy. An instance is tied to a caller-accepted scope/generation/producer.
/// Default is OFF. Call arm only on fresh explicit user consent, not permission grant or reconnect.
public struct LocationAcquisitionPolicy: Sendable {
    private let scope: String
    private let generation: Int
    private let producer: String
    private let valid: Bool
    private var lastNow: Double?
    private var lastSample: Double?
    private var lastMotion: Double?
    private var epoch: UInt64 = 0
    private var armed = false
    private var armedAt: Double = 0
    private var poisoned = false
    private var since: Double?
    private var count = 0
    private var low = false
    public init(scope: String, generation: Int, producer: String) {
        self.scope = scope; self.generation = generation; self.producer = producer
        valid = !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !producer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && generation >= 0
    }
    private mutating func clear() { since = nil; count = 0; low = false }
    public mutating func disarm() { armed = false; clear() }
    private mutating func clock(_ now: Double) -> Bool {
        guard now.isFinite, now >= 0, lastNow.map({ now >= $0 }) ?? true else {
            poisoned = true; disarm(); return false
        }
        lastNow = now; return !poisoned
    }
    @discardableResult public mutating func arm(epoch: UInt64, now: Double, permission: Bool) -> Bool {
        disarm()
        guard clock(now), valid, permission, epoch > self.epoch else { return false }
        self.epoch = epoch; armed = true; armedAt = now; return true
    }
    public mutating func evaluate(now: Double, evidence e: LocationPolicyEvidence?,
                                 requirements r: LocationPolicyRequirements = .init(),
                                 permission: Bool, epoch: UInt64) -> LocationPolicyDecision {
        guard clock(now) else { return .init() }
        if !permission || epoch != self.epoch { disarm() }
        guard armed, valid else { clear(); return .init() }
        guard r.recording == .inactive, r.navigation == .inactive, r.critical == .inactive else {
            clear(); return .init()
        }
        guard let e else { clear(); return .init() }
        let qualified = [e.time, e.speed, e.speedAccuracy, e.horizontalAccuracy, e.confidence, e.motionTime].allSatisfy { $0.isFinite }
            && e.scope == scope && e.generation == generation && e.producer == producer
            && e.original && e.qualityAccepted && e.speed >= 0 && e.speedAccuracy >= 0 && e.speedAccuracy <= 0.5
            && e.horizontalAccuracy >= 0 && e.horizontalAccuracy <= 10
            && e.motion == .low && e.confidence >= 0.9 && e.confidence <= 1
            && e.time >= armedAt && e.time <= now && now - e.time <= 2
            && e.motionTime >= armedAt && e.motionTime <= now && now - e.motionTime <= 2
        guard qualified, lastSample.map({ e.time > $0 }) ?? true,
              lastMotion.map({ e.motionTime > $0 }) ?? true else { clear(); return .init() }
        let gap = lastSample.map { e.time - $0 > 5 } ?? false
        lastSample = e.time; lastMotion = e.motionTime
        if gap { clear() }
        let upper = e.speed + e.speedAccuracy
        guard upper < 1.5 else { clear(); return .init() }
        if !low {
            guard upper <= 0.5 else { clear(); return .init() }
            if since == nil { since = e.time }
            count = min(count + 1, 16)
            if let since, e.time - since >= 30, count >= 16 { low = true }
        }
        if low {
            return .init(profile: .lowMotionAdvisory, maximumInterval: 2, distance: 5, accuracy: 10,
                         expires: min(now + 2, e.time + 2, e.motionTime + 2))
        }
        return .init()
    }
}
