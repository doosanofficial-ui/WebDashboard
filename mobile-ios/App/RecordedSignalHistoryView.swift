import SwiftUI
import Charts
import TelemetryCore

struct RecordedSignalHistoryView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let history: MeasurementReplay.SignalHistory?
    let comparisonObservations: Bool

    init(title: String, history: MeasurementReplay.SignalHistory?, comparisonObservations: Bool = false) {
        self.title = title
        self.history = history
        self.comparisonObservations = comparisonObservations
    }

    var body: some View {
        let units = Set(history?.samples.map(\.unit) ?? [])
        RecordedHistoryCard(title: title) {
            if units.count > 1 {
                Text(AppLocalization.text("Recorded units changed · separate scales required")).font(.caption)
            } else if let history, !history.samples.isEmpty {
                if comparisonObservations {
                    historyChart(history)
                        .chartXAxis(.automatic).chartYAxis(.automatic)
                        .chartXAxisLabel(AppLocalization.text("Recorded seconds"))
                        .chartYAxisLabel(units.first.flatMap { $0.isEmpty ? nil : $0 } ?? AppLocalization.text("no unit"))
                } else {
                    historyChart(history).chartXAxis(.hidden).chartYAxis(.hidden)
                }
            } else {
                Text(AppLocalization.text("No recorded samples in this window")).font(.caption)
            }
        } summary: {
            VStack(alignment: .leading, spacing: 2) {
                summaryLayout {
                    Text(AppLocalization.text("Recorded samples: \(history?.samples.count ?? 0)")).font(.caption)
                    if let history {
                        Text(AppLocalization.text(String(format: "%.1f–%.1f recorded seconds · %@", history.startSeconds,
                            history.endSeconds, units.count > 1 ? AppLocalization.text("multiple units") : (units.first ?? AppLocalization.text("no unit")))))
                            .font(.caption2).foregroundStyle(TelemetryTheme.mutedText)
                    }
                }
                Text(AppLocalization.text("Historical freshness unknown")).font(.caption2).foregroundStyle(TelemetryTheme.mutedText)
            }
        } details: {
            VStack(alignment: .leading, spacing: 12) {
                if let history {
                    Text(AppLocalization.text("\(history.samples.count) displayed of \(history.totalSamplesInWindow) original samples in this window"))
                    if history.truncated { Text(AppLocalization.text("Latest 600 original samples are shown")) }
                    if Set(history.samples.map(\.source)).count > 1 {
                        Text(AppLocalization.text(comparisonObservations ? "Recorded sources retained" : "Recorded sources changed · lines separated"))
                    }
                    if comparisonObservations {
                        Text(AppLocalization.text("Recorded observations only. Gaps are not filled or interpolated."))
                    } else {
                        Text(AppLocalization.text("Lines connect recorded observations. Original measurement times and units are preserved."))
                    }
                }
            }
        }
    }

    private func historyChart(_ history: MeasurementReplay.SignalHistory) -> some View {
        Chart(history.samples) { point in
            if !comparisonObservations {
                LineMark(x: .value("Recorded seconds", point.elapsedSeconds), y: .value("Value", point.value),
                         series: .value("Recorded source segment", point.sourceSegment))
                    .foregroundStyle(TelemetryTheme.accent)
            }
            PointMark(x: .value("Recorded seconds", point.elapsedSeconds), y: .value("Value", point.value))
                .foregroundStyle(TelemetryTheme.accent)
        }
        .chartXScale(domain: history.startSeconds...(history.endSeconds > history.startSeconds ? history.endSeconds : history.startSeconds + 1))
    }

    private var summaryLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
    }
}
