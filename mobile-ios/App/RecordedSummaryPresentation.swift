import SwiftUI

/// Host-owned result state; no loading or analysis is performed by these views.
enum RecordedSummaryState<Value> {
    case available(Value)
    case unavailable
    case unsupported
    case rejected
}

@MainActor
struct RecordedSummaryCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            Text(AppLocalization.text(title)).font(.headline)
                .accessibilityAddTraits(.isHeader)
            RecordedSummaryNote("Recorded analysis · not live vehicle data")
            content
        }
        .fixedSize(horizontal: false, vertical: true)
        .telemetrySurface()
        .accessibilityElement(children: .contain)
    }
}

@MainActor
struct RecordedSummaryContent<Value, Content: View>: View {
    let state: RecordedSummaryState<Value>
    let content: (Value) -> Content

    init(_ state: RecordedSummaryState<Value>, @ViewBuilder content: @escaping (Value) -> Content) {
        self.state = state
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .available(let value): content(value)
            case .unavailable: RecordedSummaryNote("Recorded analysis unavailable")
            case .unsupported: RecordedSummaryNote("Recorded analysis unsupported")
            case .rejected: RecordedSummaryNote("Recorded evidence rejected · no result")
            }
        }
    }
}

@MainActor
struct RecordedSummaryNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(AppLocalization.text(text))
            .font(.caption).foregroundStyle(TelemetryTheme.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
struct RecordedSummaryReading: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let label: String
    let value: String

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            Text(AppLocalization.text(label)).foregroundStyle(TelemetryTheme.mutedText)
            Text(verbatim: value).font(.body.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.text(label))
        .accessibilityValue(value)
    }
}

@MainActor
enum RecordedSummaryFormat {
    // Presentation only: preserve positive tiny values, partial fractions and exact stored time.
    // Decimal/scientific Double text avoids rounding a partial fraction to 1 or an epoch to minutes.
    static func number(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return AppLocalization.text("Unavailable") }
        return String(value) + " " + unit
    }
    static func identifier(_ value: String) -> String {
        String(value.prefix(160)) + (value.count > 160 ? "…" : "")
    }
}

@MainActor
struct RecordedSummaryScope: View {
    let session: String
    let signal: String
    let start: Double
    let end: Double
    var body: some View {
        RecordedSummaryReading(label: "Recorded session", value: RecordedSummaryFormat.identifier(session))
        RecordedSummaryReading(label: "Recorded source signal", value: RecordedSummaryFormat.identifier(signal))
        RecordedSummaryReading(label: "Window start · recorded elapsed time", value: RecordedSummaryFormat.number(start, unit: "s"))
        RecordedSummaryReading(label: "Window end · recorded elapsed time", value: RecordedSummaryFormat.number(end, unit: "s"))
    }
}

@MainActor
struct RecordedCoverageSummaryView: View {
    let coveredSeconds: Double
    let fraction: Double?
    var body: some View {
        RecordedSummaryReading(label: "Qualified coverage", value: RecordedSummaryFormat.number(coveredSeconds, unit: "s"))
        RecordedSummaryReading(label: "Coverage fraction · 0 to 1", value: RecordedSummaryFormat.number(fraction, unit: ""))
        RecordedSummaryNote("Coverage may be partial · missing intervals are not zero")
    }
}
