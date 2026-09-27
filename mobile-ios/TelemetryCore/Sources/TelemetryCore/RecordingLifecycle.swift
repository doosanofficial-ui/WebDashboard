import Foundation

public enum RecordingLifecycleState: String, Codable, Equatable, Sendable {
    case idle
    case recording
    case completed
    case failed
}

/// Small state machine that keeps the operator-visible recording state explicit.
public struct RecordingLifecycle: Equatable, Sendable {
    public private(set) var state: RecordingLifecycleState = .idle

    public init() {}

    @discardableResult
    public mutating func start() -> Bool {
        guard state != .recording else { return false }
        state = .recording
        return true
    }

    @discardableResult
    public mutating func stop() -> Bool {
        guard state == .recording else { return false }
        state = .completed
        return true
    }

    public mutating func fail() {
        state = .failed
    }

    public mutating func reset() {
        state = .idle
    }
}
