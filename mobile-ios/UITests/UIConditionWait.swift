import Foundation

/// UITest-only observation. Query time is charged to one monotonic deadline.
enum UIConditionWait {
    static func until(timeout: TimeInterval,
                      now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                      pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                      condition: () -> Bool) -> Bool {
        guard timeout.isFinite, timeout >= 0 else { return false }
        let deadline = now() + timeout
        // Evaluate immediately: a scheduled XCTest predicate can spend its first
        // second waiting before starting an already-expensive AX observation.
        while now() <= deadline {
            let satisfied = condition()
            let observedAt = now()
            guard observedAt <= deadline else { return false }
            if satisfied { return true }
            let remaining = deadline - observedAt
            guard remaining > 0 else { return false }
            // At most11fast observations per5-second wait keep the three
            // export iterations within their existing256-boundary trace.
            pause(min(0.5, remaining))
        }
        return false
    }
}
