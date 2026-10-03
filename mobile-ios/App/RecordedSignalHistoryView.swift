import SwiftUI
import Charts
import TelemetryCore

struct RecordedSignalHistoryView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let history: MeasurementReplay.SignalHistory?

    var body: some View {
        let units = Set(history?.samples.map(\.unit) ?? [])
        RecordedHistoryCard(title: title) {
            if units.count > 1 {
                Text("Recorded units changed · separate scales required").font(.caption)
            } else if let history, !history.samples.isEmpty {
                Chart(history.samples) { point in
                    LineMark(x: .value("Recorded seconds", point.elapsedSeconds), y: .value("Value", point.value),
                             series: .value("Recorded source segment", point.sourceSegment))
                        .foregroundStyle(TelemetryTheme.accent)
                    PointMark(x: .value("Recorded seconds", point.elapsedSeconds), y: .value("Value", point.value))
                        .foregroundStyle(TelemetryTheme.accent)
                }
                .chartXScale(domain: history.startSeconds...(history.endSeconds > history.startSeconds ? history.endSeconds : history.startSeconds + 1))
                .chartXAxis(.hidden).chartYAxis(.hidden)
            } else {
                Text("No recorded samples in this window").font(.caption)
            }
        } summary: {
            VStack(alignment: .leading, spacing: 2) {
                summaryLayout {
                    Text("Recorded samples: \(history?.samples.count ?? 0)").font(.caption)
                    if let history {
                        Text(String(format: "%.1f–%.1f recorded seconds · %@", history.startSeconds,
                            history.endSeconds, units.count > 1 ? "multiple units" : (units.first ?? "no unit")))
                            .font(.caption2).foregroundStyle(TelemetryTheme.mutedText)
                    }
                }
                Text("Historical freshness unknown").font(.caption2).foregroundStyle(TelemetryTheme.mutedText)
            }
        } details: {
            VStack(alignment: .leading, spacing: 12) {
                if let history {
                    Text("\(history.samples.count) displayed of \(history.totalSamplesInWindow) original samples in this window")
                    if history.truncated { Text("Latest 600 original samples are shown") }
                    if Set(history.samples.map(\.source)).count > 1 { Text("Recorded sources changed · lines separated") }
                    Text("Lines connect recorded observations. Original measurement times and units are preserved.")
                }
            }
        }
    }

    private var summaryLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
    }
}
