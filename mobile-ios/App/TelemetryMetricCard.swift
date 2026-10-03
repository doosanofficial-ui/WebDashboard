import SwiftUI

struct TelemetryMetricCard: View {
    let label: String
    let value: String
    let unit: String
    let state: String
    let accent: Color
    var emphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.xSmall) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TelemetryTheme.mutedText)
                Text(state.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(state.contains("INVALID") ? TelemetryTheme.critical : state.contains("UNKNOWN") ? TelemetryTheme.mutedText : state == "VALID" ? TelemetryTheme.valid : TelemetryTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    measurementText
                    unitText
                }.fixedSize(horizontal: true, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.horizontal) { measurementText.fixedSize() }
                        .fixedSize(horizontal: false, vertical: true)
                    unitText
                }
            }
        }
        .telemetrySurface(emphasized ? .raised : .standard,
                          padding: emphasized ? TelemetryTheme.Spacing.medium : TelemetryTheme.Spacing.small)
    }

    private var measurementText: some View {
        Text(value)
            .font(emphasized ? TelemetryTypography.primaryMeasurement : TelemetryTypography.measurement)
            .monospacedDigit().foregroundStyle(accent).contentTransition(.numericText())
    }

    private var unitText: some View {
        Text(unit).font(.caption.weight(.medium)).foregroundStyle(TelemetryTheme.mutedText)
    }
}
