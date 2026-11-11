import SwiftUI

struct RecordingActivitySettingsView: View {
    @Bindable var model: TelemetryModel
    private var korean: Bool { AppLanguageStore.shared.language == .korean }
    private func text(_ en: String, _ ko: String) -> String { korean ? ko : en }

    var body: some View {
        @Bindable var activity = model.recordingActivity
        VStack(alignment: .leading, spacing: 12) {
            Label(text("Recording Live Activity", "기록 Live Activity"), systemImage: "rectangle.topthird.inset.filled")
                .font(.headline).foregroundStyle(TelemetryTheme.accent)
            Toggle(text("Show recording outside the app", "앱 밖에서 기록 상태 표시"), isOn: $activity.enabled)
                .accessibilityIdentifier("recording-activity-enabled")
                .disabled(model.localRecordingEnabled && !activity.enabled)
            Text(text("Off by default. When enabled before REC, selected values may appear on the Lock Screen, Dynamic Island and supported CarPlay screens. Nothing starts recording or connects an adapter here.",
                      "기본값은 꺼짐입니다. REC 전에 켜면 선택한 값이 잠금 화면·Dynamic Island·지원되는 CarPlay 화면에 표시될 수 있습니다. 여기에서 기록이나 어댑터 연결이 시작되지는 않습니다."))
                .font(.caption).foregroundStyle(.secondary)
            if activity.enabled {
                signalPicker(text("First signal", "첫 번째 신호"), identifier: "recording-activity-first-signal", selection: $activity.firstSignal)
                signalPicker(text("Second signal", "두 번째 신호"), identifier: "recording-activity-second-signal", selection: $activity.secondSignal)
                Text(text("Values are checked when the app updates this snapshot. iOS may keep showing an older snapshot, including values and recording status. Check its update time. This does not keep the app awake.",
                          "앱이 화면 정보를 갱신할 때 값의 유효 시간을 확인합니다. iOS가 이전 값과 기록 상태를 계속 표시할 수 있으므로 갱신 시각을 확인하세요. 앱을 강제로 계속 실행하지 않습니다."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(status).font(.caption.weight(.semibold))
                .accessibilityIdentifier("recording-activity-status")
        }
        .padding().telemetrySurface(.standard)
        .onChange(of: activity.firstSignal) { _, _ in model.refreshRecordingActivity(force: true) }
        .onChange(of: activity.secondSignal) { _, _ in model.refreshRecordingActivity(force: true) }
    }

    private func signalPicker(_ title: String, identifier: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                Text(text("None", "선택 없음")).tag("")
                ForEach(Array(Set(model.availableSignalIDs + [selection.wrappedValue])).filter { !$0.isEmpty }.sorted(), id: \.self) { id in
                    Text(id).tag(id)
                }
            }.pickerStyle(.menu).labelsHidden().accessibilityLabel(title).accessibilityIdentifier(identifier)
        }
    }

    private var status: String {
        switch model.recordingActivity.status {
        case .off: return text("Live Activity off", "Live Activity 꺼짐")
        case .ready: return text("Ready for the next recording", "다음 기록부터 표시합니다")
        case .active: return text("Live Activity active", "Live Activity 표시 중")
        case .ending: return text("Ending Live Activity", "Live Activity 종료 중")
        case .unavailable: return text("Live Activity unavailable; recording is independent", "Live Activity를 사용할 수 없습니다. 기록은 별도로 계속됩니다")
        case .stopped: return text("Live Activity stopped", "Live Activity 종료")
        case .interrupted: return text("Live Activity interrupted", "Live Activity 중단")
        case .dismissed: return text("Dismissed; resumes with the next recording", "닫힘. 다음 기록부터 다시 표시합니다")
        }
    }
}
