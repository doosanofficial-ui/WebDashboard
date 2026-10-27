import SwiftUI
import TelemetryCore

/// The selected replay prefix is immutable. Opening this view never queries an ECU.
struct DiagnosticHistoryView: View {
    @Bindable var model: TelemetryModel

    private var projection: DiagnosticAuditReplayProjection? {
        guard model.runMode == .replay else { return nil }
        guard let history = model.replayController.recordedSystemHistory() else { return nil }
        return DiagnosticAuditReplayProjection.project(systemPayloadJSON: history.samples.map(\.payloadJSON),
                                                       historyWasCapped: history.truncated)
    }

    private var historyStatus: DiagnosticAuditHistoryStatus {
        switch projection?.status {
        case .available: .available
        case .truncated: .truncated
        case .unavailable, nil: .unavailable
        }
    }

    var body: some View {
        DiagnosticAuditView(attempts: projection?.attempts ?? [], historyStatus: historyStatus)
            .accessibilityIdentifier("diagnostic-audit-history")
    }
}
