import SwiftUI
import TelemetryCore

/// Two independent value scales over the same accepted recorded-time window.
struct ReplayComparisonView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let comparison: RecordedSignalComparison
    let titles: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalization.text("Two signals · separate Y scales"))
                .font(.subheadline.weight(.semibold))
            Text(AppLocalization.text("Recorded observations only. Gaps are not filled or interpolated."))
                .font(.caption).foregroundStyle(TelemetryTheme.mutedText)
            ForEach(comparison.series) { series in
                VStack(alignment: .leading, spacing: 4) {
                    RecordedSignalHistoryView(title: titles[series.signalID] ?? series.signalID,
                        history: series.history, comparisonObservations: true)
                        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 280)
                    // This belongs to the accepted cursor snapshot, not every plotted row.
                    Text(AppLocalization.text("Cursor state quality") + ": " +
                        AppLocalization.text(series.cursorState?.quality.rawValue.uppercased() ?? "NO SAMPLE"))
                        .font(.caption).foregroundStyle(TelemetryTheme.mutedText)
                    Text(AppLocalization.text("Cursor freshness") + ": " +
                        AppLocalization.text(series.cursorFreshness?.rawValue.uppercased() ?? "UNKNOWN"))
                        .font(.caption).foregroundStyle(TelemetryTheme.mutedText)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("replay-analysis-comparison-history-\(series.signalID)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replay-analysis-comparison")
    }
}
