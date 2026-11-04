import Foundation

/// Pure decision only. Does not observe the clock, persist settings, or schedule work.
public enum AppearanceSchedulePolicy {
    public enum Phase: String, Equatable, Sendable { case light, dark }
    public enum Mode: Equatable, Sendable {
        case system
        case manual(Phase)
        case scheduled(dayMinute: Int, nightMinute: Int)
    }
    public enum Reason: String, Equatable, Sendable {
        case system, manual, scheduled, invalidSchedule, invalidClock
    }
    public struct Decision: Equatable, Sendable {
        public let phase: Phase
        /// Opaque caller-owned identifier. Resolve/validate against the existing theme catalog.
        public let themeID: String
        public let reason: Reason
        /// First future differing sampled UTC minute, not a guaranteed callback or timer.
        public let nextBoundaryEpochMinute: Int?
    }
    public static let minimumEpochMinute = 15_778_080
    public static let exclusiveMaximumEpochMinute = 68_374_080

    /// Integer epoch minutes give explicit minute resolution. Clock conversion belongs to caller.
    /// Gregorian local wall time is evaluated in the supplied zone at every sampled instant.
    /// Default nil mappings preserve existing selection (including its separate overrides).
    public static func decide(
        selectedThemeID: String,
        systemPhase: Phase,
        mode: Mode = .system,
        epochMinute: Int? = nil,
        timeZoneIdentifier: String = "UTC",
        lightThemeID: String? = nil,
        darkThemeID: String? = nil
    ) -> Decision {
        func output(_ phase: Phase, _ reason: Reason, _ next: Int? = nil) -> Decision {
            let mapped = phase == .light ? lightThemeID : darkThemeID
            return Decision(phase: phase, themeID: mapped ?? selectedThemeID,
                            reason: reason, nextBoundaryEpochMinute: next)
        }
        func fallback(_ reason: Reason) -> Decision {
            Decision(phase: systemPhase, themeID: selectedThemeID,
                     reason: reason, nextBoundaryEpochMinute: nil)
        }
        switch mode {
        case .system: return output(systemPhase, .system)
        case .manual(let phase): return output(phase, .manual)
        case .scheduled(let day, let night):
            guard (0..<1440).contains(day), (0..<1440).contains(night), day != night else {
                return fallback(.invalidSchedule)
            }
            guard let now = epochMinute,
                  (minimumEpochMinute..<exclusiveMaximumEpochMinute).contains(now),
                  let zone = TimeZone(identifier: timeZoneIdentifier) else {
                return fallback(.invalidClock)
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            func phase(at minute: Int) -> Phase {
                let date = Date(timeIntervalSince1970: Double(minute) * 60)
                let wallMinute = calendar.component(.hour, from: date) * 60
                    + calendar.component(.minute, from: date)
                let isLight = day < night
                    ? day <= wallMinute && wallMinute < night
                    : wallMinute >= day || wallMinute < night
                return isLight ? .light : .dark
            }
            let current = phase(at: now)
            let end = min(now + 4321, exclusiveMaximumEpochMinute)
            if now + 1 < end {
                for future in (now + 1)..<end {
                    if phase(at: future) != current {
                        return output(current, .scheduled, future)
                    }
                }
            }
            return output(current, .scheduled)
        }
    }
}
