import Foundation

/// Tracks forward-only server sequence progress without treating delayed or
/// duplicated frames as new drops.
public struct FrameSequenceTracker: Equatable, Sendable {
    public private(set) var lastSequence: Int?
    public private(set) var receivedCount = 0
    public private(set) var dropCount = 0

    public init() {}

    @discardableResult
    public mutating func accept(sequence: Int) -> Int {
        guard sequence >= 0 else { return 0 }
        receivedCount = receivedCount == Int.max ? Int.max : receivedCount + 1
        guard let lastSequence else {
            self.lastSequence = sequence
            return 0
        }
        guard sequence > lastSequence else { return 0 }
        let gap = sequence - lastSequence - 1
        self.lastSequence = sequence
        if gap > 0 {
            dropCount = Int.max - dropCount < gap ? Int.max : dropCount + gap
        }
        return max(0, gap)
    }

    public mutating func reset() {
        lastSequence = nil
        receivedCount = 0
        dropCount = 0
    }
}

/// Deterministic exponential backoff for reconnect loops.
public struct ReconnectBackoff: Equatable, Sendable {
    private let initialSeconds: UInt64
    private let maximumSeconds: UInt64
    private var nextSeconds: UInt64

    public init(initialSeconds: UInt64 = 1, maximumSeconds: UInt64 = 30) {
        let initial = max(1, initialSeconds)
        let maximum = max(initial, maximumSeconds)
        self.initialSeconds = initial
        self.maximumSeconds = maximum
        self.nextSeconds = initial
    }

    public mutating func nextDelaySeconds() -> UInt64 {
        let delay = nextSeconds
        if nextSeconds >= maximumSeconds || nextSeconds > maximumSeconds / 2 {
            nextSeconds = maximumSeconds
        } else {
            nextSeconds *= 2
        }
        return delay
    }

    public mutating func reset() {
        nextSeconds = initialSeconds
    }
}

/// Minimal WebSocket health state for an operator-visible connection indicator.
public struct PingMetrics: Equatable, Sendable {
    public private(set) var lastRTTMilliseconds: Double?
    public private(set) var consecutiveFailures = 0

    public init() {}

    public mutating func recordSuccess(rttMilliseconds: Double) {
        guard rttMilliseconds.isFinite, rttMilliseconds >= 0 else {
            recordFailure()
            return
        }
        lastRTTMilliseconds = rttMilliseconds
        consecutiveFailures = 0
    }

    public mutating func recordFailure() {
        consecutiveFailures = consecutiveFailures == Int.max
            ? Int.max : consecutiveFailures + 1
    }

    public mutating func reset() {
        lastRTTMilliseconds = nil
        consecutiveFailures = 0
    }
}
