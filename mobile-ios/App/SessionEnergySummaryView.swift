import SwiftUI
import TelemetryCore

/// Read-only presentation of energy integrated from qualified recorded samples.
/// Callers provide the selected language's copy and whether either history was capped.
struct SessionEnergySummaryView: View {
    struct Labels {
        let title: String
        let selectedWindow: String
        let windowOnly: String
        let truncatedWindow: String
        let unavailable: String
        let consumed: String
        let regenerated: String
        let signed: String
        let validDuration: String
        let excludedIntervals: String
        let seconds: String
        let kilowattHours: String
        let maxGap: String
        let maxSkew: String
        let currentConvention: String
        let positiveCurrentConsumption: String
        let negativeCurrentConsumption: String
        let voltage: String
        let current: String
        let afterCursor: String
        let beforeWindow: String
        let nonFiniteTimestamp: String
        let unknownTimeUnit: String
        let unknownSignalUnit: String
        let qualityUnknown: String
        let qualityNotValid: String
        let nonFiniteValue: String
        let negativeVoltage: String
        let nonFinitePower: String
        let nonFiniteEnergy: String
        let gapExceeded: String
        let skewExceeded: String
        let noPairedSample: String

        static let english = Labels(
            title: "Recorded energy",
            selectedWindow: "Selected recorded window",
            windowOnly: "Energy covers this selected window only.",
            truncatedWindow: "The recorded window is capped; this is partial-window energy, not a whole-session total.",
            unavailable: "Energy is unavailable until a qualified voltage/current interval exists.",
            consumed: "Consumed",
            regenerated: "Regenerated",
            signed: "Net",
            validDuration: "Valid duration",
            excludedIntervals: "Excluded intervals",
            seconds: "s",
            kilowattHours: "kWh",
            maxGap: "Maximum gap",
            maxSkew: "Maximum sample skew",
            currentConvention: "Current sign",
            positiveCurrentConsumption: "positive current means consumption",
            negativeCurrentConsumption: "negative current means consumption",
            voltage: "Voltage",
            current: "Current",
            afterCursor: "After the selected replay cursor",
            beforeWindow: "Before the selected window",
            nonFiniteTimestamp: "Non-finite recorded timestamp",
            unknownTimeUnit: "Unknown time unit",
            unknownSignalUnit: "Unknown signal unit",
            qualityUnknown: "Recorded quality is unknown",
            qualityNotValid: "Recorded quality is not valid",
            nonFiniteValue: "Non-finite signal value",
            negativeVoltage: "Negative voltage",
            nonFinitePower: "Non-finite power",
            nonFiniteEnergy: "Non-finite interval energy",
            gapExceeded: "Gap exceeds the configured maximum",
            skewExceeded: "Sample skew exceeds the configured maximum",
            noPairedSample: "No unused matching sample"
        )

        static let korean = Labels(
            title: "기록 에너지",
            selectedWindow: "선택된 기록 구간",
            windowOnly: "에너지는 선택된 구간에 대해서만 계산됩니다.",
            truncatedWindow: "기록 구간이 제한되었습니다. 전체 세션 합계가 아닌 일부 구간의 에너지입니다.",
            unavailable: "유효한 전압/전류 기록 구간이 없어 에너지를 계산할 수 없습니다.",
            consumed: "소비",
            regenerated: "회생",
            signed: "순 에너지",
            validDuration: "유효 구간 길이",
            excludedIntervals: "제외 구간",
            seconds: "초",
            kilowattHours: "kWh",
            maxGap: "최대 간격",
            maxSkew: "최대 샘플 시차",
            currentConvention: "전류 부호",
            positiveCurrentConsumption: "양수 전류는 소비를 뜻함",
            negativeCurrentConsumption: "음수 전류는 소비를 뜻함",
            voltage: "전압",
            current: "전류",
            afterCursor: "선택한 재생 위치 이후",
            beforeWindow: "선택한 구간 이전",
            nonFiniteTimestamp: "유한하지 않은 기록 시각",
            unknownTimeUnit: "시간 단위를 알 수 없음",
            unknownSignalUnit: "신호 단위를 알 수 없음",
            qualityUnknown: "기록된 품질을 알 수 없음",
            qualityNotValid: "기록된 품질이 유효하지 않음",
            nonFiniteValue: "유한하지 않은 신호 값",
            negativeVoltage: "음수 전압",
            nonFinitePower: "유한하지 않은 전력",
            nonFiniteEnergy: "유한하지 않은 구간 에너지",
            gapExceeded: "간격이 설정된 최댓값을 초과함",
            skewExceeded: "샘플 시차가 설정된 최댓값을 초과함",
            noPairedSample: "사용할 수 있는 대응 샘플이 없음"
        )
    }

    let summary: RecordedEnergySummary
    let isWindowTruncated: Bool
    let labels: Labels

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(labels.title)
                .font(.headline)

            Text("\(labels.selectedWindow): \(summary.selectedWindowStartSeconds, format: .number.precision(.fractionLength(1)))–\(summary.cursorSeconds, format: .number.precision(.fractionLength(1))) \(labels.seconds)")
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)

            Text(labels.windowOnly)
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)

            if isWindowTruncated {
                Label(labels.truncatedWindow, systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(TelemetryTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if summary.availability == .available {
                metric(label: labels.consumed, value: summary.consumedKWh)
                metric(label: labels.regenerated, value: summary.regeneratedKWh)
                metric(label: labels.signed, value: summary.signedKWh)
            } else {
                Label(labels.unavailable, systemImage: "bolt.slash")
                    .font(.subheadline)
                    .foregroundStyle(TelemetryTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("\(labels.validDuration): \(summary.validDurationSeconds, format: .number.precision(.fractionLength(1))) \(labels.seconds)")
                .font(.caption.monospacedDigit())

            Text(policyDescription)
                .font(.caption2)
                .foregroundStyle(TelemetryTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            if !summary.excludedIntervals.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(labels.excludedIntervals): \(summary.excludedIntervals.count)")
                        .font(.caption.weight(.semibold))
                    ForEach(Array(summary.excludedIntervals.prefix(8))) { interval in
                        VStack(alignment: .leading, spacing: 2) {
                            if let start = interval.startSeconds, let end = interval.endSeconds {
                                Text("\(start, format: .number.precision(.fractionLength(2)))–\(end, format: .number.precision(.fractionLength(2))) \(labels.seconds)")
                                    .font(.caption2.monospacedDigit())
                            } else if !interval.sourceSequences.isEmpty {
                                Text("\(labels.excludedIntervals) · #\(interval.sourceSequences.map { String($0) }.joined(separator: ", "))")
                                    .font(.caption2.monospacedDigit())
                            }
                            ForEach(interval.reasons, id: \.self) { reason in
                                Text(reasonDescription(reason))
                                    .font(.caption2)
                                    .foregroundStyle(TelemetryTheme.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if summary.excludedIntervals.count > 8 {
                        Text("+\(summary.excludedIntervals.count - 8)")
                            .font(.caption2)
                            .foregroundStyle(TelemetryTheme.mutedText)
                    }
                }
            }
        }
        .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
        .accessibilityElement(children: .contain)
    }

    private var policyDescription: String {
        let convention = summary.policy.currentSignConvention == .positiveCurrentMeansConsumption
            ? labels.positiveCurrentConsumption : labels.negativeCurrentConsumption
        return "\(labels.maxGap): \(summary.policy.maxGapSeconds.formatted(.number.precision(.fractionLength(2)))) \(labels.seconds) · \(labels.maxSkew): \(summary.policy.maxSampleSkewSeconds.formatted(.number.precision(.fractionLength(2)))) \(labels.seconds) · \(labels.currentConvention): \(convention)"
    }

    private func metric(label: String, value: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.subheadline)
            Spacer(minLength: 8)
            Text(value, format: .number.precision(.fractionLength(4)))
                .font(.headline.monospacedDigit())
                .accessibilityLabel("\(label), \(value.formatted(.number.precision(.fractionLength(4)))) \(labels.kilowattHours)")
            Text(labels.kilowattHours).font(.caption).foregroundStyle(TelemetryTheme.mutedText)
        }
    }

    private func signalName(_ signal: RecordedEnergySignal) -> String {
        signal == .voltage ? labels.voltage : labels.current
    }

    private func reasonDescription(_ reason: RecordedEnergyExclusionReason) -> String {
        switch reason {
        case .afterCursor: labels.afterCursor
        case .beforeSelectedWindow: labels.beforeWindow
        case .nonFiniteTimestamp: labels.nonFiniteTimestamp
        case .unknownTimeUnit(let signal, let unit): "\(labels.unknownTimeUnit) · \(signalName(signal)) (\(unit))"
        case .unknownSignalUnit(let signal, let unit): "\(labels.unknownSignalUnit) · \(signalName(signal)) (\(unit))"
        case .qualityUnknown(let signal): "\(labels.qualityUnknown) · \(signalName(signal))"
        case .qualityNotValid(let signal, let quality): "\(labels.qualityNotValid) · \(signalName(signal)) (\(quality))"
        case .nonFiniteValue(let signal): "\(labels.nonFiniteValue) · \(signalName(signal))"
        case .negativeVoltage: labels.negativeVoltage
        case .nonFinitePower: labels.nonFinitePower
        case .nonFiniteEnergy: labels.nonFiniteEnergy
        case .maxGapExceeded: labels.gapExceeded
        case .maxSampleSkewExceeded(let signal, let delta): "\(labels.skewExceeded) · \(signalName(signal)) (\(delta.formatted(.number.precision(.fractionLength(3)))) \(labels.seconds))"
        case .noPairedSample(let signal): "\(labels.noPairedSample) · \(signalName(signal))"
        }
    }
}
