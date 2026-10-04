import SwiftUI
import TelemetryCore

/// Analysis of the accepted recorded-time snapshot, without acquisition or profile writes.
struct ReplayAnalysisView: View {
    @Bindable var model: TelemetryModel
    @State private var selectedSignalID: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var signals: [String] {
        let configured = model.dashboardProfile?.pages.flatMap { $0.widgets.compactMap(\.signalID) } ?? []
        let recorded = model.frame?.sig.keys.sorted() ?? []
        var seen = Set<String>()
        return (configured + recorded).filter { seen.insert($0).inserted }
    }
    private var currentSignal: String? {
        selectedSignalID.flatMap { signals.contains($0) ? $0 : nil } ?? signals.first
    }
    private func label(_ id: String) -> String {
        model.dashboardProfile?.pages.flatMap(\.widgets).first { $0.signalID == id }?.configuration.label ?? id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let signal = currentSignal {
                Picker(AppLocalization.text("Recorded signal"), selection: Binding(get: { currentSignal ?? signal }, set: { selectedSignalID = $0 })) {
                    ForEach(signals, id: \.self) { id in Text(verbatim: label(id)).tag(id) }
                }
                .pickerStyle(.menu).tint(TelemetryTheme.accent)
                .accessibilityIdentifier("replay-analysis-signal")
                RecordedSignalHistoryView(title: label(signal), history: model.replayController.recordedHistory(for: signal))
                    .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 240)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("replay-analysis-history")
            } else {
                Text(AppLocalization.text("No recorded signal selected")).foregroundStyle(TelemetryTheme.mutedText)
            }
            let route = model.replayController.recordedLocations()
            RecordedRouteView(title: "Recorded route", history: route)
                .frame(minHeight: dynamicTypeSize.isAccessibilitySize || route?.projectedPoints.isEmpty != false ? nil : 220)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("replay-analysis-route")
            Text(AppLocalization.text(String(format: "%.1f / %.1f recorded seconds", model.replayController.position, model.replayController.duration)))
                .font(.caption.monospacedDigit()).foregroundStyle(TelemetryTheme.mutedText)
                .accessibilityIdentifier("replay-analysis-time")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-replay-analysis")
        .onChange(of: model.replayController.sessionID) { _, _ in selectedSignalID = nil }
    }
}
