import Foundation
import SwiftUI
import TelemetryCore

/// One explicitly supplied response. No model, transport, command or action closure.
@MainActor
struct RecordedDiagnosticSnapshotView: View {
    let snapshot: RecordedDiagnosticInterpretation
    private var service: String {
        switch snapshot.response.service {
        case .monitorStatus: return RecordedDiagnosticText.text("MIL / stored count · Mode 01 PID 01", "MIL / 저장 개수 · 모드 01 PID 01")
        case .stored: return RecordedDiagnosticText.text("Confirmed / stored · Mode 03", "확정 / 저장 · 모드 03")
        case .pending: return RecordedDiagnosticText.text("Pending · Mode 07", "대기 · 모드 07")
        case .permanent: return RecordedDiagnosticText.text("Permanent · Mode 0A", "영구 · 모드 0A")
        }
    }
    var body: some View {
        Form {
            Section {
                Text(RecordedDiagnosticText.text("Supplied snapshot only. Not live status or a fault-cause diagnosis.", "제공된 스냅샷만 표시합니다. 실시간 상태나 고장 원인 진단이 아닙니다."))
                Text(verbatim: service).font(.headline)
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Response state", "응답 상태"), value: RecordedDiagnosticText.status(snapshot.status))
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Source ECU", "출처 ECU"), value: snapshot.response.ecu)
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Framing", "프레이밍"), value: snapshot.response.framing == .iso15765CAN ? "ISO 15765 CAN" : "Legacy")
                Text(RecordedDiagnosticText.text("Reassembled application bytes only. Permanent-code legacy layout is not interpreted. A layout limitation does not establish ECU non-support.", "재조립된 응용 계층 바이트만 대상입니다. 레거시 영구 코드 형식은 해석하지 않습니다. 형식 제한으로 ECU 미지원을 단정하지 않습니다."))
                    .font(.caption)
            }
            Section {
                if snapshot.status == .positive, snapshot.response.service == .monitorStatus {
                    RecordedEvidenceField(label: "MIL", value: snapshot.mil.map { $0 ? RecordedDiagnosticText.text("On", "켜짐") : RecordedDiagnosticText.text("Off", "꺼짐") } ?? RecordedDiagnosticText.text("Unknown", "알 수 없음"))
                    RecordedEvidenceField(label: RecordedDiagnosticText.text("Reported stored count", "보고된 저장 개수"), value: snapshot.storedCount.map { String($0) } ?? RecordedDiagnosticText.text("Unknown", "알 수 없음"))
                    Text(RecordedDiagnosticText.text("MIL off and a zero count are not a vehicle-health guarantee.", "MIL 꺼짐과 개수 0은 차량 정상 상태를 보장하지 않습니다."))
                } else if snapshot.status == .positive, let codes = snapshot.codes {
                    if codes.isEmpty {
                        Text(RecordedDiagnosticText.text("This ECU positively reported zero codes for this service.", "이 ECU가 이 서비스에서 코드 0개를 명시적으로 보고했습니다."))
                    } else {
                        // Preserve repetitions and order; avoid duplicate ForEach identities.
                        Text(verbatim: codes.prefix(256).joined(separator: " · "))
                            .font(.body.monospaced()).fixedSize(horizontal: false, vertical: true)
                        if codes.count > 256 {
                            Text(RecordedDiagnosticText.text("Display truncated; not complete evidence", "표시가 잘렸으며 완전한 근거가 아닙니다"))
                        }
                    }
                } else {
                    Text(RecordedDiagnosticText.text("No positive code-count evidence. Do not interpret this as zero faults.", "코드 개수를 확정할 양성 응답 근거가 없습니다. 고장 0개로 해석하지 마세요."))
                }
                if let negative = snapshot.negativeCode {
                    RecordedEvidenceField(label: RecordedDiagnosticText.text("Opaque negative byte", "해석하지 않은 부정 응답 바이트"), value: String(format: "%02X", negative))
                }
                if let issue = snapshot.issue {
                    RecordedEvidenceField(label: RecordedDiagnosticText.text("Interpreter issue token", "해석기 문제 토큰"), value: issue)
                }
            } header: { Text(RecordedDiagnosticText.text("Reported values", "보고된 값")) }
            Section {
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Application PDU · hexadecimal", "응용 계층 PDU · 16진수"), value: RecordedDiagnosticText.bytes(snapshot.response.payload))
                if snapshot.response.payload.count > 64 {
                    Text(RecordedDiagnosticText.text("Only the first 64 bytes are shown.", "처음 64바이트만 표시합니다."))
                }
            } header: { Text(RecordedDiagnosticText.text("Supplied evidence", "제공된 근거")) }
        }
        .navigationTitle(RecordedDiagnosticText.text("Recorded diagnostics", "기록된 진단"))
        .accessibilityIdentifier("recorded-diagnostic-snapshot")
    }
}
