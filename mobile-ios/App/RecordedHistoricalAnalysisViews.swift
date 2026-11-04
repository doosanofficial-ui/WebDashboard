import SwiftUI
import TelemetryCore

@MainActor
struct RecordedWeeklyComparisonView: View {
    let state: RecordedSummaryState<WeeklyTripComparison>
    var body: some View {
        RecordedSummaryCard("Recorded weekly comparison") {
            RecordedSummaryContent(state) { comparison in
                RecordedSummaryReading(label: "Recorded source signal", value: RecordedSummaryFormat.identifier(comparison.selected.signalID))
                RecordedSummaryReading(label: "Original source unit", value: comparison.selected.sourceUnit.rawValue)
                RecordedSummaryReading(label: "Policy revision", value: RecordedSummaryFormat.identifier(comparison.selected.policyRevision))
                RecordedSummaryReading(label: "Verified time zone", value: RecordedSummaryFormat.identifier(comparison.weeks.timeZoneIdentifier))
                RecordedSummaryReading(label: "Verified calendar", value: RecordedSummaryFormat.identifier(comparison.weeks.calendarIdentifier))
                RecordedSummaryReading(label: "First weekday", value: String(comparison.weeks.firstWeekday))
                RecordedSummaryReading(label: "Minimum days in first week", value: String(comparison.weeks.minimumDaysInFirstWeek))
                RecordedWeeklyPeriodView(title: "Prior recorded week", summary: comparison.prior)
                RecordedWeeklyPeriodView(title: "Current recorded week", summary: comparison.current)
                RecordedSummaryReading(label: "Unallocated invalid inputs", value: String(comparison.unallocatedInvalidInputCount))
                RecordedSummaryNote("Partial archive totals · not full-week driving")
            }
        }
    }
}

@MainActor
private struct RecordedWeeklyPeriodView: View {
    let title: String
    let summary: RecordedWeeklyTrip
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.text(title)).font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
            // UTC epoch is deliberately explicit, never silently converted to the device time zone.
            RecordedSummaryReading(label: "Window start · UTC epoch seconds", value: RecordedSummaryFormat.number(summary.startUTC, unit: "s"))
            RecordedSummaryReading(label: "Window end · UTC epoch seconds", value: RecordedSummaryFormat.number(summary.endUTC, unit: "s"))
            RecordedSummaryReading(label: "Qualified distance estimate", value: RecordedSummaryFormat.number(summary.distanceKilometers, unit: "km"))
            RecordedSummaryReading(label: "Duration-weighted mean speed", value: RecordedSummaryFormat.number(summary.averageSpeedKmh, unit: "km/h"))
            RecordedCoverageSummaryView(coveredSeconds: summary.coveredSeconds, fraction: summary.coverageFraction)
            RecordedSummaryReading(label: "Accepted summary window duration", value: RecordedSummaryFormat.number(summary.summaryWindowSeconds, unit: "s"))
            RecordedSummaryNote("Coverage denominator is accepted summary duration · not elapsed week time")
            RecordedSummaryReading(label: "Qualified sessions", value: String(summary.qualifiedSessionCount))
            RecordedSummaryReading(label: "Accepted summaries", value: String(summary.acceptedSummaryCount))
            RecordedSummaryReading(label: "Duplicate summaries ignored", value: String(summary.duplicateCount))
            RecordedSummaryReading(label: "Upstream excluded intervals", value: String(summary.upstreamExcludedIntervalCount))
            RecordedSummaryReading(label: "Provenance mismatches", value: String(summary.exclusions[.provenanceMismatch, default: 0]))
            RecordedSummaryReading(label: "Boundary summaries requiring bounded input", value: String(summary.exclusions[.boundaryRequiresBoundedSummary, default: 0]))
            RecordedSummaryReading(label: "Overlapping summaries excluded", value: String(summary.exclusions[.overlap, default: 0]))
        }
    }
}

@MainActor
struct RecordedSpeedWindowSummaryView: View {
    let state: RecordedSummaryState<RecordedSpeedWindowReport>
    var body: some View {
        RecordedSummaryCard("Historical speed-window estimates") {
            RecordedSummaryContent(state) { report in
                RecordedSummaryScope(session: report.sessionID, signal: report.signalID, start: report.startSeconds, end: report.endSeconds)
                RecordedSummaryReading(label: "Lower speed threshold", value: RecordedSummaryFormat.number(report.policy.lowerKmh, unit: "km/h"))
                RecordedSummaryReading(label: "Upper speed threshold", value: RecordedSummaryFormat.number(report.policy.upperKmh, unit: "km/h"))
                RecordedSummaryReading(label: "Maximum admitted gap", value: RecordedSummaryFormat.number(report.policy.maxGapSeconds, unit: "s"))
                RecordedSummaryReading(label: "Maximum admitted duration", value: RecordedSummaryFormat.number(report.policy.maxDurationSeconds, unit: "s"))
                RecordedSummaryReading(label: "Qualified crossings", value: String(report.estimates.count))
                if let estimate = report.estimates.first {
                    RecordedSummaryNote("First qualified crossing only · remaining crossings not displayed")
                    RecordedSummaryReading(label: "Estimated duration", value: RecordedSummaryFormat.number(estimate.durationSeconds, unit: "s"))
                    RecordedSummaryReading(label: "Estimated lower crossing · recorded elapsed time", value: RecordedSummaryFormat.number(estimate.lowerCrossing.timestampSeconds, unit: "s"))
                    RecordedSummaryReading(label: "Estimated upper crossing · recorded elapsed time", value: RecordedSummaryFormat.number(estimate.upperCrossing.timestampSeconds, unit: "s"))
                    RecordedSummaryReading(label: "Lower bracket original sequences", value: "\(estimate.lowerCrossing.before.sourceSequence), \(estimate.lowerCrossing.after.sourceSequence)")
                    RecordedSummaryReading(label: "Upper bracket original sequences", value: "\(estimate.upperCrossing.before.sourceSequence), \(estimate.upperCrossing.after.sourceSequence)")
                    RecordedSummaryReading(label: "Lower bracket source segment", value: String(estimate.lowerCrossing.before.sourceSegment))
                    RecordedSummaryReading(label: "Upper bracket source segment", value: String(estimate.upperCrossing.before.sourceSegment))
                } else {
                    RecordedSummaryNote("No complete qualified crossing · not a zero-second run")
                }
                RecordedSummaryNote("Historical linear-interpolation estimate; not vehicle certification")
            }
        }
    }
}

@MainActor
struct RecordedLowSpeedSummaryView: View {
    let state: RecordedSummaryState<RecordedLowSpeedReport>
    var body: some View {
        RecordedSummaryCard("Historical low-speed estimate") {
            RecordedSummaryContent(state) { report in
                RecordedSummaryScope(session: report.sessionID, signal: report.signalID, start: report.startSeconds, end: report.endSeconds)
                RecordedSummaryReading(label: "Strictly below speed threshold", value: RecordedSummaryFormat.number(report.policy.thresholdKmh, unit: "km/h"))
                RecordedSummaryReading(label: "Estimated below-threshold duration", value: RecordedSummaryFormat.number(report.belowThresholdDurationEstimateSeconds, unit: "s"))
                RecordedSummaryReading(label: "Classified duration", value: RecordedSummaryFormat.number(report.classifiedDurationSeconds, unit: "s"))
                RecordedSummaryReading(label: "Unclassified duration", value: RecordedSummaryFormat.number(report.unclassifiedDurationSeconds, unit: "s"))
                RecordedSummaryReading(label: "Maximum admitted gap", value: RecordedSummaryFormat.number(report.policy.maxGapSeconds, unit: "s"))
                RecordedSummaryNote("Historical same-side endpoint bracket estimate; intervening motion unknown")
                RecordedSummaryNote("Not engine idle, parked, gear or fuel state · not a true-duration bound")
            }
        }
    }
}
