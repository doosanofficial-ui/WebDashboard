import Foundation
import SwiftUI
import TelemetryCore

/// In-memory inspection only. Host context ID must change on capture/source/generation.
@MainActor
struct RecordedVINStatusView: View {
    let snapshot: RecordedVINInterpretation
    let privacyContextID: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var revealedSnapshot: RecordedVINInterpretation?
    @State private var revealedContext: String?

    private var canReveal: Bool {
        !privacyContextID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && snapshot.status == .positive && snapshot.vin != nil && scenePhase == .active
    }
    // Equality guards hide changed content before onChange callbacks have run.
    private var isRevealed: Bool {
        canReveal && revealedContext == privacyContextID && revealedSnapshot == snapshot
    }
    private var state: String {
        switch snapshot.status {
        case .positive: return RecordedDiagnosticText.status(.positive)
        case .noData: return RecordedDiagnosticText.status(.noData)
        case .unsupported: return RecordedDiagnosticText.status(.unsupported)
        case .unknown: return RecordedDiagnosticText.status(.unknown)
        case .negative: return RecordedDiagnosticText.status(.negative)
        case .malformed: return RecordedDiagnosticText.status(.malformed)
        }
    }
    private var layout: String {
        switch snapshot.response.framing {
        case .iso15765CAN: return "ISO 15765 CAN"
        case .legacy: return "Legacy"
        case .unknown: return RecordedDiagnosticText.text("Unknown", "알 수 없음")
        }
    }
    var body: some View {
        Form {
            Section {
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Source ECU", "출처 ECU"), value: snapshot.response.ecu)
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Response state", "응답 상태"), value: state)
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Framing", "프레이밍"), value: layout)
                if isRevealed, let vin = snapshot.vin {
                    Text(verbatim: vin)
                        .font(.body.monospaced()).fixedSize(horizontal: false, vertical: true)
                        .privacySensitive()
                        .accessibilityLabel(RecordedDiagnosticText.text("Revealed VIN", "공개된 VIN"))
                        .accessibilityValue(vin)
                        .accessibilityIdentifier("recorded-vin-revealed")
                } else {
                    Text(RecordedDiagnosticText.text("VIN hidden", "VIN 숨김"))
                        .font(.headline)
                        .accessibilityIdentifier("recorded-vin-masked")
                }
                Button(isRevealed ? RecordedDiagnosticText.text("Hide VIN", "VIN 숨기기") : RecordedDiagnosticText.text("Reveal VIN locally", "이 화면에서 VIN 보기")) {
                    if isRevealed {
                        conceal()
                    } else if canReveal {
                        revealedSnapshot = snapshot
                        revealedContext = privacyContextID
                    }
                }
                .disabled(!canReveal)
                .accessibilityIdentifier("recorded-vin-toggle")
                Text(RecordedDiagnosticText.text("Reveal only in a private setting. A visible VIN can be read by nearby people, accessibility tools or a screen capture. There is no copy, export or storage action.", "주변이 안전한 곳에서만 표시하세요. 표시된 VIN은 주변 사람, 접근성 도구 또는 화면 캡처에 노출될 수 있습니다. 복사, 내보내기 또는 저장 동작은 없습니다."))
                Text(RecordedDiagnosticText.text("A positive result validates supported syntax only. It does not identify or authenticate a vehicle, model, year or owner.", "양성 결과는 지원하는 구문만 확인합니다. 차량, 모델, 연식 또는 소유자를 식별하거나 인증하지 않습니다."))
            }
            Section {
                Text(RecordedDiagnosticText.text("Mode 09 PID 02: only explicitly supplied ISO 15765 CAN framing with a 20-byte application PDU is interpreted. Legacy and unknown layouts remain unknown, not ECU non-support.", "모드 09 PID 02: 명시적으로 제공된 ISO 15765 CAN 프레이밍과 20바이트 응용 PDU만 해석합니다. 레거시 및 불명 형식은 알 수 없음이며 ECU 미지원이 아닙니다."))
                Text(RecordedDiagnosticText.text("The host must verify source and request correlation. No check-digit, jurisdiction or manufacturer lookup is performed.", "호스트가 출처와 요청의 연관성을 확인해야 합니다. 검사 숫자, 관할 규정 또는 제조사 조회는 수행하지 않습니다."))
            } header: { Text(RecordedDiagnosticText.text("Protocol limits", "프로토콜 제한")) }
        }
        .navigationTitle(RecordedDiagnosticText.text("Recorded VIN status", "기록된 VIN 상태"))
        .accessibilityIdentifier("recorded-vin-status")
        // Privacy-only local callbacks: no command, transport, persistence or host action.
        .onChange(of: snapshot) { _, _ in conceal() }
        .onChange(of: privacyContextID) { _, _ in conceal() }
        .onChange(of: scenePhase) { _, _ in conceal() }
        .onDisappear { conceal() }
    }
    private func conceal() {
        revealedSnapshot = nil
        revealedContext = nil
    }
}
