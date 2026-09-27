import SwiftUI
import Charts

struct TelemetryChartCard: View {
    let title: String
    let points: [CanPoint]
    let signals: [String]
    let now: Date
    let units: String
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("LAST 60 SECONDS · \(units)")
                        .font(.caption2.weight(.bold))
                        .tracking(0.7)
                        .foregroundStyle(TelemetryTheme.quietText)
                }
                Spacer()
                TelemetryStatusBadge(
                    title: stale ? "Stale" : "Live",
                    color: stale ? TelemetryTheme.warning : TelemetryTheme.valid,
                    symbol: stale ? "pause.fill" : "waveform"
                )
            }
            Chart(points) { point in
                ForEach(signals, id: \.self) { signal in
                    if let value = point.signals[signal] {
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value(signal, value),
                            series: .value("Signal", signal)
                        )
                        .foregroundStyle(by: .value("Signal", signal))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .chartXScale(domain: now.addingTimeInterval(-60)...now)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                        .foregroundStyle(TelemetryTheme.grid)
                    AxisValueLabel()
                        .font(.caption2)
                        .foregroundStyle(TelemetryTheme.quietText)
                }
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
            .frame(height: 132)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(TelemetryTheme.plot, in: RoundedRectangle(cornerRadius: TelemetryTheme.Radius.small, style: .continuous))
        }
        .telemetrySurface(.standard)
    }
}
