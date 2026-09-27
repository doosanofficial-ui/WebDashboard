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
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(TelemetryTheme.mutedText)
                Spacer(minLength: 4)
                Text(state.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(state == "VALID" ? TelemetryTheme.valid : TelemetryTheme.warning)
            }
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: emphasized ? 54 : 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.65)
                Text(unit)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(TelemetryTheme.mutedText)
            }
        }
        .telemetrySurface(emphasized ? .raised : .standard,
                          padding: emphasized ? TelemetryTheme.Spacing.large : TelemetryTheme.Spacing.medium)
    }
}
