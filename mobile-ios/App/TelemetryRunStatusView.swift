import SwiftUI

/// Shared wording for mode, acquisition and independent recording/GPS state.
struct TelemetryRunStatusView: View {
    @Bindable var model: TelemetryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TelemetryDisplayState.modeTitle(model.runMode, recordingMode: model.replayController.recordingMode))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(model.runMode == .demo ? TelemetryTheme.warning : TelemetryTheme.accent)
            Text(stateSummary)
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var stateSummary: String {
        if model.runMode == .replay {
            return "Acquisition off · Recording off · " + (model.lastLocation == nil ? "No recorded GPS" : "Recorded GPS")
        }
        let active = model.adapterStatus.localizedCaseInsensitiveContains("monitoring")
        let can = model.runMode == .demo ? (active ? "Synthetic CAN active" : "Synthetic CAN off")
            : (active ? "CAN collecting" : "CAN off")
        return can + " · " + (model.localRecordingEnabled ? "Recording on" : "Recording off")
            + " · " + (model.collecting ? "GPS collecting" : "GPS off")
    }
}
