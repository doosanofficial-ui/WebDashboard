import SwiftUI
import TelemetryCore

@MainActor
struct RecordedTripSummaryView: View {
    let state: RecordedSummaryState<RecordedTripSummary>
    var body: some View {
        RecordedSummaryCard("Recorded trip summary") {
            RecordedSummaryContent(state) { summary in
                RecordedSummaryScope(session: summary.sessionID, signal: summary.signalID, start: summary.startSeconds, end: summary.endSeconds)
                RecordedSummaryReading(label: "Qualified distance estimate", value: RecordedSummaryFormat.number(summary.distanceKilometers, unit: "km"))
                RecordedSummaryReading(label: "Average speed", value: RecordedSummaryFormat.number(summary.averageSpeedKmh, unit: "km/h"))
                RecordedSummaryReading(label: "Observed maximum speed", value: RecordedSummaryFormat.number(summary.observedMaximumSpeedKmh, unit: "km/h"))
                RecordedSummaryReading(label: "Time at or above threshold", value: RecordedSummaryFormat.number(summary.movingDurationSeconds, unit: "s"))
                RecordedSummaryReading(label: "Speed threshold", value: RecordedSummaryFormat.number(summary.policy.movingThresholdKmh, unit: "km/h"))
                RecordedSummaryReading(label: "Maximum admitted gap", value: RecordedSummaryFormat.number(summary.policy.maxGapSeconds, unit: "s"))
                RecordedCoverageSummaryView(coveredSeconds: summary.coveredDurationSeconds, fraction: summary.coverageFraction)
                RecordedSummaryReading(label: "Excluded intervals", value: String(summary.excludedIntervals.count))
                RecordedSummaryNote("Observed-window estimate · not an odometer or complete trip")
                RecordedSummaryNote("Speed threshold time is not engine-on or idle time")
            }
        }
    }
}

@MainActor
struct RecordedTripReplaySummaryView: View {
    let state: RecordedSummaryState<RecordedTripReplayProjection.Result>
    var body: some View {
        RecordedSummaryCard("Recorded replay coverage") {
            RecordedSummaryContent(state) { result in
                RecordedSummaryReading(label: "Available original rows", value: String(result.evidence.count))
                RecordedSummaryReading(label: "Original rows in selected window", value: String(result.totalSamplesInWindow))
                if result.isWindowTruncated {
                    RecordedSummaryNote("Truncated recorded window · not complete coverage")
                }
                RecordedTripSummaryView(state: .available(result.summary))
            }
        }
    }
}

@MainActor
struct RecordedFuelSummaryView: View {
    let state: RecordedSummaryState<RecordedFuelSummary>
    var body: some View {
        RecordedSummaryCard("Recorded fuel summary") {
            RecordedSummaryContent(state) { summary in
                RecordedSummaryScope(session: summary.sessionID, signal: summary.signalID, start: summary.startSeconds, end: summary.endSeconds)
                RecordedSummaryReading(label: "Qualified fuel estimate", value: RecordedSummaryFormat.number(summary.observedLiters, unit: "L"))
                RecordedSummaryReading(label: "Mean fuel rate", value: RecordedSummaryFormat.number(summary.meanRateLitersPerHour, unit: "L/h"))
                RecordedCoverageSummaryView(coveredSeconds: summary.coveredDurationSeconds, fraction: summary.coverageFraction)
                RecordedSummaryReading(label: "Maximum admitted gap", value: RecordedSummaryFormat.number(summary.policy.maxGapSeconds, unit: "s"))
                RecordedSummaryReading(label: "Excluded intervals", value: String(summary.excludedIntervals.count))
                RecordedSummaryNote("Linear interval estimate · not complete-trip consumption")
                RecordedSummaryNote("Fuel economy unavailable · matched distance coverage not proven")
            }
        }
    }
}

@MainActor
struct RecordedMatchedEconomySummaryView: View {
    let state: RecordedSummaryState<RecordedMatchedFuelEconomy>
    var body: some View {
        RecordedSummaryCard("Recorded matched fuel economy") {
            RecordedSummaryContent(state) { summary in
                RecordedSummaryScope(session: summary.sessionID, signal: summary.speedSignalID, start: summary.startSeconds, end: summary.endSeconds)
                RecordedSummaryReading(label: "Recorded fuel signal", value: RecordedSummaryFormat.identifier(summary.fuelSignalID))
                RecordedSummaryReading(label: "Matched distance", value: RecordedSummaryFormat.number(summary.distanceKilometers, unit: "km"))
                RecordedSummaryReading(label: "Matched fuel", value: RecordedSummaryFormat.number(summary.fuelLiters, unit: "L"))
                RecordedSummaryReading(label: "Matched economy estimate", value: RecordedSummaryFormat.number(summary.litersPer100Kilometers, unit: "L/100 km"))
                if let reason = summary.unavailableReason {
                    switch reason {
                    case .noQualifiedCommonInterval: RecordedSummaryNote("No qualified common interval")
                    case .zeroMatchedDistance: RecordedSummaryNote("Economy unavailable · matched distance is zero")
                    case .unrepresentableRatio: RecordedSummaryNote("Economy unavailable · numeric limit")
                    }
                }
                RecordedCoverageSummaryView(coveredSeconds: summary.coveredDurationSeconds, fraction: summary.coverageFraction)
                RecordedSummaryReading(label: "Excluded speed pairs", value: String(summary.excludedSpeedPairCount))
                RecordedSummaryReading(label: "Excluded fuel pairs", value: String(summary.excludedFuelPairCount))
                RecordedSummaryReading(label: "Numeric rejected common intervals", value: String(summary.numericRejectedCommonIntervalCount))
                RecordedSummaryNote("Partial matched-coverage estimate · linear interpolation within qualified original intervals")
            }
        }
    }
}
