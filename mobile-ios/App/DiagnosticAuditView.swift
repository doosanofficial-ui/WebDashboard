import Foundation
import SwiftUI
import TelemetryCore

enum DiagnosticAuditHistoryStatus: Equatable {
    case available
    case truncated
    case unavailable
}

/// Read-only projection of an audit reconstruction. The caller supplies history
/// availability because a selected-time row cap can omit earlier persisted rows.
struct DiagnosticAuditView: View {
    let attempts: [DiagnosticAuditAttempt]
    let historyStatus: DiagnosticAuditHistoryStatus

    var body: some View {
        List {
            if historyStatus == .truncated {
                Section {
                    Text(AppLocalization.text("Some earlier diagnostic audit rows are outside this selection."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(AppLocalization.text("Diagnostic audit history is truncated."))
                }
            }

            if historyStatus == .unavailable {
                ContentUnavailableView(
                    AppLocalization.text("Diagnostic audit details unavailable"),
                    systemImage: "list.bullet.rectangle",
                    description: Text(AppLocalization.text("The selected audit rows do not contain a complete attempt history."))
                )
            }
            if attempts.isEmpty && historyStatus != .unavailable {
                ContentUnavailableView(
                    AppLocalization.text("No diagnostic attempts"),
                    systemImage: "waveform.path.ecg",
                    description: Text(AppLocalization.text("Diagnostic query attempts will appear here when recorded."))
                )
            } else {
                ForEach(attempts) { attempt in
                    Section {
                        attemptDetails(attempt)
                    } header: {
                        Text(attempt.query.name)
                            .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle(AppLocalization.text("Diagnostic audit"))
    }

    private func attemptDetails(_ attempt: DiagnosticAuditAttempt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            querySummary(attempt)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                ForEach(attempt.events, id: \.ordinal) { event in
                    eventRow(event)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func querySummary(_ attempt: DiagnosticAuditAttempt) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            summaryLine("Audit scope", value: scopeName(attempt.scope))
            summaryLine("Scope ID", value: attempt.scope.identifier.uuidString)
            summaryLine("Query ID", value: attempt.query.id)
            summaryLine("Service", value: attempt.query.service.rawValue)
            summaryLine("Command", value: attempt.query.command)
            summaryLine("Vehicle context", value: attempt.context.vehicleContextID ?? bilingual("Unassigned", "미지정"))
            summaryLine("Adapter profile", value: attempt.context.adapterProfileName)
            summaryLine("Transport", value: attempt.context.transport.uppercased())
            summaryLine("Connection", value: attempt.context.connectionID.uuidString)
            summaryLine("Request CAN ID", value: canID(attempt.query.requestCANID))
            summaryLine("Response CAN ID", value: canID(attempt.query.responseCANID))
            if attempt.query.isExtended {
                Text(AppLocalization.text("Extended CAN identifiers"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    private func summaryLine(_ title: String, value: String) -> some View {
        LabeledContent(AppLocalization.text(title), value: value)
            .font(.caption)
    }

    private func eventRow(_ event: DiagnosticAuditEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(event.stage == .terminal ? Color.accentColor : Color.secondary)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(stageTitle(event))
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Text(Date(timeIntervalSince1970: event.timestamp.epochSeconds)
                        .formatted(date: .abbreviated, time: .standard))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let reasonCode = event.reasonCode {
                    Text(bilingual("Reason code: \(reasonCode)", "사유 코드: \(reasonCode)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let reason = event.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let sequence = event.responseSequence {
                    Text(bilingual("Response sequence: \(sequence)", "응답 순번: \(sequence)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if event.stage == .transportWriteCompleted {
                    Text(AppLocalization.text("The transport write returned; ECU receipt is not confirmed."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stageTitle(_ event: DiagnosticAuditEvent) -> String {
        if event.stage == .terminal, let outcome = event.terminalOutcome {
            switch outcome {
            case .succeeded: return AppLocalization.text("Response received")
            case .failed: return AppLocalization.text("Query failed")
            case .cancelled: return AppLocalization.text("Query cancelled")
            case .recordingWindowClosed: return AppLocalization.text("Recording window closed")
            }
        }
        switch event.stage {
        case .queued: return AppLocalization.text("Queued")
        case .started: return AppLocalization.text("Started")
        case .transportWriteStarted: return AppLocalization.text("Transport write started")
        case .transportWriteCompleted: return AppLocalization.text("Transport write returned")
        case .transportWriteFailed: return AppLocalization.text("Transport write failed")
        case .terminal: return AppLocalization.text("Finished")
        }
    }

    private func canID(_ value: UInt32) -> String {
        String(format: "0x%X", value)
    }

    private func scopeName(_ scope: DiagnosticAuditScope) -> String {
        switch scope {
        case .acquisition: bilingual("Acquisition", "수집 세션")
        case .recordingWindow: bilingual("Recording window", "기록 구간")
        }
    }

    private func bilingual(_ english: String, _ korean: String) -> String {
        switch AppLanguageStore.shared.language {
        case .english: english
        case .korean: korean
        }
    }
}
