/// A deterministic due-time planner for one request/response transport.
/// Each array slot remains distinct, including repeated query definitions.
/// Ticks are monotonic nanoseconds; wall-clock changes cannot reorder requests.
struct OBDPollingSchedule {
    struct Selection: Equatable {
        let queryIndex: Int
        let delayNanoseconds: UInt64
    }

    private let intervals: [UInt64]
    private var deadlines: [UInt64]

    init(intervals: [UInt64], now: UInt64) {
        precondition(!intervals.isEmpty && intervals.allSatisfy { $0 > 0 })
        self.intervals = intervals
        self.deadlines = Array(repeating: now, count: intervals.count)
    }

    func next(at now: UInt64) -> Selection {
        var selected = 0
        for index in deadlines.indices.dropFirst() {
            if deadlines[index] < deadlines[selected] { selected = index }
        }
        let deadline = deadlines[selected]
        return Selection(queryIndex: selected,
                         delayNanoseconds: deadline > now ? deadline - now : 0)
    }

    mutating func complete(_ index: Int, at now: UInt64) {
        // Start the next interval after completion, not an expired old deadline.
        // Slow replies therefore cannot build up a burst of catch-up requests.
        let (deadline, overflow) = now.addingReportingOverflow(intervals[index])
        deadlines[index] = overflow ? UInt64.max : deadline
    }
}
