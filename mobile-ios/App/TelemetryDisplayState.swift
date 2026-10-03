import Foundation
import TelemetryCore

/// Presentation only: never changes measurements, quality or timeout policies.
enum TelemetryDisplayState {
    static func modeTitle(_ mode: TelemetryRunMode, recordingMode: TelemetryRunMode?) -> String {
        switch mode {
        case .live: return "LIVE · vehicle data"
        case .demo: return "DEMO · synthetic CAN data"
        case .replay:
            if recordingMode == .demo { return "REPLAY · DEMO recording" }
            if recordingMode == .live { return "REPLAY · vehicle recording" }
            return "REPLAY · saved recording"
        }
    }

    static func signalLabel(_ value: Double?, liveFresh: Bool, isReplay: Bool = false,
                            replayQuality: SignalQuality? = nil) -> String {
        guard let value else { return "NO SAMPLE" }
        guard value.isFinite else { return "INVALID" }
        if isReplay || replayQuality != nil {
            return (replayQuality?.rawValue.uppercased() ?? "UNKNOWN") + " RECORDED"
        }
        return liveFresh ? "VALID" : "STALE"
    }

    static func freshnessLabel(_ freshness: MeasurementReplay.SignalFreshness?) -> String {
        "FRESHNESS " + (freshness?.rawValue.uppercased() ?? "UNKNOWN")
    }

    static func matchesStaleFilter(_ value: Double?, liveFresh: Bool, isReplay: Bool,
                                   replayFreshness: MeasurementReplay.SignalFreshness?) -> Bool {
        guard let value, value.isFinite else { return false }
        return isReplay ? replayFreshness == .stale : !liveFresh
    }

    static func gpsLabel(hasSample: Bool, isReplay: Bool, age: Double?) -> String {
        guard hasSample else { return isReplay ? "NO RECORDED FIX" : "NO FIX" }
        if isReplay { return "RECORDED FIX" }
        guard let age, age.isFinite, age >= 0 else { return "AGE UNKNOWN" }
        return age <= 4 ? "FRESH FIX" : "STALE FIX"
    }
    static func conditionLabel(isReplay: Bool, evaluatedActive: Bool?, fresh: Bool) -> String {
        if isReplay || evaluatedActive == nil { return "NOT EVALUATED" }
        if !fresh { return "STALE" }
        return evaluatedActive == true ? "ACTIVE" : "CLEAR"
    }

}
