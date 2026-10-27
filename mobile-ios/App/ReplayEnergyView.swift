import SwiftUI
import TelemetryCore

/// Read-only energy summary over two explicitly selected signals from the
/// accepted replay snapshot. No acquisition or recording state is changed.
struct ReplayEnergyView: View {
    struct Labels {
        let title: String
        let estimateScope: String
        let voltageSignal: String
        let currentSignal: String
        let currentSignConvention: String
        let chooseVoltageSignal: String
        let chooseCurrentSignal: String
        let chooseSignConvention: String
        let positiveCurrentConsumption: String
        let negativeCurrentConsumption: String
        let noSession: String
        let missingVoltageCandidate: String
        let missingCurrentCandidate: String
        let selectedVoltageUnavailable: String
        let selectedCurrentUnavailable: String
        let missingOrigin: String
        let missingHistory: String
        let invalidRecordedData: String
        let noQualifiedSelection: String
        let maxGap: String
        let maxSkew: String
        let seconds: String
        let energy: SessionEnergySummaryView.Labels

        static let english = Labels(
            title: "Replay energy",
            estimateScope: "Sampled energy estimate for this selected recorded window; only qualified intervals between observed samples are included.",
            voltageSignal: "Voltage signal",
            currentSignal: "Current signal",
            currentSignConvention: "Current sign convention",
            chooseVoltageSignal: "Select a voltage signal",
            chooseCurrentSignal: "Select a current signal",
            chooseSignConvention: "Select how current sign maps to consumption",
            positiveCurrentConsumption: "Positive current means consumption",
            negativeCurrentConsumption: "Negative current means consumption",
            noSession: "No replay session is selected.",
            missingVoltageCandidate: "No recorded voltage signal is available at this replay cursor.",
            missingCurrentCandidate: "No recorded current signal is available at this replay cursor.",
            selectedVoltageUnavailable: "The selected voltage signal is not present in the accepted replay snapshot. It was not replaced automatically.",
            selectedCurrentUnavailable: "The selected current signal is not present in the accepted replay snapshot. It was not replaced automatically.",
            missingOrigin: "The shared recorded monotonic origin is unavailable, so energy cannot be calculated.",
            missingHistory: "The selected signal histories are unavailable at the accepted replay cursor.",
            invalidRecordedData: "The selected recorded rows could not be validated for this session and window.",
            noQualifiedSelection: "Select distinct voltage and current signals and an explicit current sign convention.",
            maxGap: "Maximum gap",
            maxSkew: "Maximum sample skew",
            seconds: "s",
            energy: .english
        )

        static let korean = Labels(
            title: "재생 에너지",
            estimateScope: "선택한 기록 구간에서 관측된 유효 샘플 간격만 포함한 에너지 추정치입니다.",
            voltageSignal: "전압 신호",
            currentSignal: "전류 신호",
            currentSignConvention: "전류 부호 규칙",
            chooseVoltageSignal: "전압 신호를 선택하세요",
            chooseCurrentSignal: "전류 신호를 선택하세요",
            chooseSignConvention: "전류 부호가 소비를 뜻하는 방식을 선택하세요",
            positiveCurrentConsumption: "양수 전류는 소비를 뜻함",
            negativeCurrentConsumption: "음수 전류는 소비를 뜻함",
            noSession: "선택된 재생 세션이 없습니다.",
            missingVoltageCandidate: "현재 재생 위치에 기록된 전압 신호가 없습니다.",
            missingCurrentCandidate: "현재 재생 위치에 기록된 전류 신호가 없습니다.",
            selectedVoltageUnavailable: "선택한 전압 신호가 현재 승인된 재생 스냅샷에 없습니다. 다른 신호로 자동 변경하지 않았습니다.",
            selectedCurrentUnavailable: "선택한 전류 신호가 현재 승인된 재생 스냅샷에 없습니다. 다른 신호로 자동 변경하지 않았습니다.",
            missingOrigin: "공유 기록 단조 시계 원점이 없어 에너지를 계산할 수 없습니다.",
            missingHistory: "선택한 재생 위치에서 신호 기록을 사용할 수 없습니다.",
            invalidRecordedData: "선택한 기록 행을 이 세션과 구간에 대해 검증할 수 없습니다.",
            noQualifiedSelection: "서로 다른 전압·전류 신호와 명시적인 전류 부호 규칙을 선택하세요.",
            maxGap: "최대 간격",
            maxSkew: "최대 샘플 시차",
            seconds: "초",
            energy: .korean
        )
    }

    @Bindable var replayController: ReplayController
    let recordedMonotonicOrigin: UInt64?
    let recordedVoltageSignalIDs: [String]
    let recordedCurrentSignalIDs: [String]
    let maxGapSeconds: Double
    let maxSampleSkewSeconds: Double
    let labels: Labels

    @Binding private var selectedVoltageSignalID: String?
    @Binding private var selectedCurrentSignalID: String?
    @Binding private var selectedCurrentSignConventionRawValue: String?

    private enum ProjectionState {
        case ready(RecordedEnergyReplayProjection.Result)
        case unavailable(String)
    }

    init(
        replayController: ReplayController,
        recordedMonotonicOrigin: UInt64?,
        recordedVoltageSignalIDs: [String],
        recordedCurrentSignalIDs: [String],
        selectedVoltageSignalID: Binding<String?>,
        selectedCurrentSignalID: Binding<String?>,
        selectedCurrentSignConventionRawValue: Binding<String?>,
        maxGapSeconds: Double,
        maxSampleSkewSeconds: Double,
        labels: Labels
    ) {
        self.replayController = replayController
        self.recordedMonotonicOrigin = recordedMonotonicOrigin
        self.recordedVoltageSignalIDs = recordedVoltageSignalIDs
        self.recordedCurrentSignalIDs = recordedCurrentSignalIDs
        self._selectedVoltageSignalID = selectedVoltageSignalID
        self._selectedCurrentSignalID = selectedCurrentSignalID
        self._selectedCurrentSignConventionRawValue = selectedCurrentSignConventionRawValue
        self.maxGapSeconds = maxGapSeconds
        self.maxSampleSkewSeconds = maxSampleSkewSeconds
        self.labels = labels
    }

    private var voltageSignalOptions: [String] {
        Array(Set(recordedVoltageSignalIDs)).sorted()
    }

    private var currentSignalOptions: [String] {
        Array(Set(recordedCurrentSignalIDs)).sorted()
    }

    private var projectionState: ProjectionState {
        guard replayController.sessionID != nil else { return .unavailable(labels.noSession) }
        guard !voltageSignalOptions.isEmpty else { return .unavailable(labels.missingVoltageCandidate) }
        guard !currentSignalOptions.isEmpty else { return .unavailable(labels.missingCurrentCandidate) }
        guard let voltageID = selectedVoltageSignalID else {
            return .unavailable(labels.noQualifiedSelection)
        }
        guard voltageSignalOptions.contains(voltageID) else {
            return .unavailable(labels.selectedVoltageUnavailable)
        }
        guard let currentID = selectedCurrentSignalID else {
            return .unavailable(labels.noQualifiedSelection)
        }
        guard currentSignalOptions.contains(currentID) else {
            return .unavailable(labels.selectedCurrentUnavailable)
        }
        guard voltageID != currentID else { return .unavailable(labels.noQualifiedSelection) }
        guard let rawSignConvention = selectedCurrentSignConventionRawValue,
              let signConvention = RecordedEnergyCurrentSignConvention(rawValue: rawSignConvention) else {
            return .unavailable(labels.noQualifiedSelection)
        }
        guard recordedMonotonicOrigin != nil else { return .unavailable(labels.missingOrigin) }
        guard let voltageHistory = replayController.recordedHistory(for: voltageID),
              let currentHistory = replayController.recordedHistory(for: currentID) else {
            return .unavailable(labels.missingHistory)
        }

        do {
            return .ready(try RecordedEnergyReplayProjection.summarize(
                selectedSessionID: replayController.sessionID,
                recordedMonotonicOrigin: recordedMonotonicOrigin,
                voltageSignalID: voltageID,
                voltageHistory: voltageHistory,
                currentSignalID: currentID,
                currentHistory: currentHistory,
                selectedWindowStartSeconds: voltageHistory.startSeconds,
                cursorSeconds: replayController.position,
                policy: RecordedEnergyPolicy(
                    maxGapSeconds: maxGapSeconds,
                    maxSampleSkewSeconds: maxSampleSkewSeconds,
                    currentSignConvention: signConvention
                )
            ))
        } catch {
            return .unavailable(labels.invalidRecordedData)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(labels.title).font(.headline)
            Text(labels.estimateScope)
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            signalPicker(
                title: labels.voltageSignal,
                placeholder: labels.chooseVoltageSignal,
                selectedID: $selectedVoltageSignalID,
                options: voltageSignalOptions,
                unavailableLabel: labels.selectedVoltageUnavailable,
                accessibilityID: "replay-energy-voltage-signal"
            )
            signalPicker(
                title: labels.currentSignal,
                placeholder: labels.chooseCurrentSignal,
                selectedID: $selectedCurrentSignalID,
                options: currentSignalOptions,
                unavailableLabel: labels.selectedCurrentUnavailable,
                accessibilityID: "replay-energy-current-signal"
            )
            Picker(labels.currentSignConvention, selection: $selectedCurrentSignConventionRawValue) {
                Text(labels.chooseSignConvention).tag(String?.none)
                Text(labels.positiveCurrentConsumption).tag(
                    String?.some(RecordedEnergyCurrentSignConvention.positiveCurrentMeansConsumption.rawValue)
                )
                Text(labels.negativeCurrentConsumption).tag(
                    String?.some(RecordedEnergyCurrentSignConvention.negativeCurrentMeansConsumption.rawValue)
                )
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("replay-energy-sign-convention")

            Text("\(labels.maxGap): \(maxGapSeconds.formatted(.number.precision(.fractionLength(2)))) \(labels.seconds) · \(labels.maxSkew): \(maxSampleSkewSeconds.formatted(.number.precision(.fractionLength(2)))) \(labels.seconds)")
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)

            switch projectionState {
            case .ready(let projection):
                SessionEnergySummaryView(
                    summary: projection.summary,
                    isWindowTruncated: projection.isWindowTruncated,
                    labels: labels.energy
                )
            case .unavailable(let message):
                Label(message, systemImage: "bolt.slash")
                    .font(.subheadline)
                    .foregroundStyle(TelemetryTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("replay-energy-unavailable")
            }
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replay-energy-summary")
    }

    private func signalPicker(
        title: String,
        placeholder: String,
        selectedID: Binding<String?>,
        options: [String],
        unavailableLabel: String,
        accessibilityID: String
    ) -> some View {
        Picker(title, selection: selectedID) {
            Text(placeholder).tag(String?.none)
            if let selected = selectedID.wrappedValue, !options.contains(selected) {
                Text("\(selected) · \(unavailableLabel)").tag(String?.some(selected))
            }
            ForEach(options, id: \.self) { id in
                Text(verbatim: id).tag(String?.some(id))
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier(accessibilityID)
    }
}
