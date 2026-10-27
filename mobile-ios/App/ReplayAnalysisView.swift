import SwiftUI
import TelemetryCore

/// Analysis of the accepted recorded-time snapshot, without acquisition or profile writes.
struct ReplayAnalysisView: View {
    @Bindable var model: TelemetryModel
    @State private var selectedSignalID: String?
    @State private var comparisonSelection = RecordedSignalComparison.Selection()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var signals: [String] {
        let configured = model.dashboardProfile?.pages.flatMap { $0.widgets.compactMap(\.signalID) } ?? []
        let recorded = model.frame?.sig.keys.sorted() ?? []
        var seen = Set<String>()
        let retained = comparisonEnabled ? comparisonSelection.availableSignalIDs : []
        return (configured + recorded + retained).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted
        }
    }
    private var currentSignal: String? {
        let preferred = comparisonEnabled ? comparisonSelection.signalIDs(primarySignalID: nil).first : selectedSignalID
        return preferred.flatMap { signals.contains($0) ? $0 : nil } ?? signals.first
    }
    private func label(_ id: String) -> String {
        model.dashboardProfile?.pages.flatMap(\.widgets).first { $0.signalID == id }?.configuration.label ?? id
    }
    private var comparisonEnabled: Bool {
        comparisonSelection.sessionID == model.replayController.sessionID && comparisonSelection.secondarySignalID != nil
    }
    private var comparisonCandidateIDs: [String] {
        guard let snapshot = model.replayController.snapshot, !model.replayController.loading else { return [] }
        let configured = model.dashboardProfile?.pages.flatMap { $0.widgets.compactMap(\.signalID) } ?? []
        return configured + snapshot.signals.map(\.signalID).sorted()
    }
    private var comparison: RecordedSignalComparison? {
        guard comparisonEnabled, let sessionID = model.replayController.sessionID,
              let snapshot = model.replayController.snapshot, !model.replayController.loading else { return nil }
        let ids = comparisonSelection.signalIDs(primarySignalID: currentSignal)
        guard ids.count == 2 else { return nil }
        return try? RecordedSignalComparison(sessionID: sessionID, signalIDs: ids,
            at: model.replayController.position, snapshot: snapshot) { model.replayController.recordedHistory(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let signal = currentSignal {
                Picker(AppLocalization.text("Recorded signal"), selection: Binding(get: { currentSignal ?? signal }, set: {
                    selectedSignalID = $0
                    comparisonSelection.selectSecondary(comparisonSelection.secondarySignalID, primarySignalID: $0)
                })) {
                    ForEach(signals, id: \.self) { id in Text(verbatim: label(id)).tag(id) }
                }
                .pickerStyle(.menu).tint(TelemetryTheme.accent)
                .accessibilityIdentifier("replay-analysis-signal")
                Picker(AppLocalization.text("Compare with"), selection: Binding<String?>(get: {
                    comparisonEnabled ? comparisonSelection.secondarySignalID : nil
                }, set: {
                    comparisonSelection.observe(sessionID: model.replayController.sessionID, signalIDs: comparisonCandidateIDs)
                    selectedSignalID = signal
                    comparisonSelection.selectSecondary($0, primarySignalID: signal)
                })) {
                    Text(AppLocalization.text("No comparison")).tag(String?.none)
                    ForEach(comparisonSelection.availableSignalIDs.filter { $0 != signal }, id: \.self) { id in
                        Text(verbatim: label(id)).tag(Optional(id))
                    }
                }
                .pickerStyle(.menu).tint(TelemetryTheme.accent)
                .accessibilityIdentifier("replay-analysis-comparison-signal")
                Group {
                    if comparisonEnabled {
                        if let comparison {
                            ReplayComparisonView(comparison: comparison,
                                titles: Dictionary(uniqueKeysWithValues: comparison.series.map { ($0.signalID, label($0.signalID)) }))
                        } else {
                            Text(AppLocalization.text("Comparison unavailable for this recorded cursor"))
                                .foregroundStyle(TelemetryTheme.mutedText)
                        }
                    } else {
                        RecordedSignalHistoryView(title: label(signal), history: model.replayController.recordedHistory(for: signal))
                            .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 240)
                    }
                }
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
        .onChange(of: model.replayController.sessionID) { _, newSessionID in
            selectedSignalID = nil
            comparisonSelection.observe(sessionID: newSessionID, signalIDs: comparisonCandidateIDs)
        }
        .onChange(of: comparisonCandidateIDs, initial: true) { _, ids in
            comparisonSelection.observe(sessionID: model.replayController.sessionID, signalIDs: ids)
        }
    }
}
