import Foundation
import SwiftUI
import TelemetryCore

/// A single candidate and fully supplied contexts; pure assessment, no discovery.
@MainActor
struct RecordedSupportSnapshotView: View {
    let candidate: StandardMode01Candidate
    let current: Mode01SupportPage.Context
    let evidence: Mode01SupportPage.Evidence?
    let availability: Mode01SupportPage.Availability

    private var assessment: Mode01SupportPage.Assessment {
        Mode01SupportPage.assess(evidence, current: current,
            pid: UInt8(candidate.rawValue, radix: 16) ?? 0,
            isCandidate: true, availability: availability)
    }
    var body: some View {
        Form {
            Section {
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Candidate PID", "후보 PID"), value: "01 " + candidate.rawValue)
                Text(verbatim: candidateName).font(.headline)
                Text(RecordedDiagnosticText.text("A catalog candidate is not observed support, selection, permission or a live value.", "카탈로그 후보는 관찰된 지원, 선택, 실행 허가 또는 실시간 값이 아닙니다."))
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Observed support", "관찰된 지원"), value: RecordedDiagnosticText.support(assessment.observedSupport))
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Availability at supplied snapshot", "제공된 스냅샷의 가용 상태"), value: RecordedDiagnosticText.availability(assessment.currentAvailability))
                Text(RecordedDiagnosticText.text("No data, timeout or disconnection does not erase support evidence or establish non-support.", "데이터 없음, 시간 초과 또는 연결 끊김은 지원 근거를 지우거나 미지원을 확정하지 않습니다."))
            }
            Section {
                context(current)
            } header: { Text(RecordedDiagnosticText.text("Supplied current context", "제공된 현재 문맥")) }
            Section {
                if let evidence {
                    context(evidence.context)
                    RecordedEvidenceField(label: RecordedDiagnosticText.text("Page / mask · hexadecimal", "페이지 / 마스크 · 16진수"), value: String(format: "%02X / %08X", evidence.page, evidence.mask))
                    RecordedEvidenceField(label: RecordedDiagnosticText.text("Evidence origin", "근거 출처"), value: evidence.origin == .vehicle ? RecordedDiagnosticText.text("Vehicle response", "차량 응답") : RecordedDiagnosticText.text("Synthetic", "합성"))
                    RecordedEvidenceField(label: RecordedDiagnosticText.text("Exact context match", "문맥 완전 일치"), value: evidence.context == current ? RecordedDiagnosticText.text("Yes", "예") : RecordedDiagnosticText.text("No", "아니요"))
                    Text(RecordedDiagnosticText.text("Synthetic, mismatched or out-of-page evidence leaves support unknown.", "합성, 문맥 불일치 또는 페이지 범위 밖 근거에서는 지원을 알 수 없음으로 유지합니다."))
                } else {
                    Text(RecordedDiagnosticText.text("No support-page evidence was supplied.", "지원 페이지 근거가 제공되지 않았습니다."))
                }
            } header: { Text(RecordedDiagnosticText.text("Supplied support evidence", "제공된 지원 근거")) }
            Section {
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Documentation URL", "문서 URL"), value: candidate.sourceDocumentationURL)
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Documentation section", "문서 절"), value: candidate.sourceDocumentationSection)
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Documentation review date", "문서 검토일"), value: StandardMode01Candidate.documentationReviewedOn)
                Text(RecordedDiagnosticText.text("Classic Mode 01 CAN pages 00–C0 only. Historical schema and product bounds are not complete SAE coverage. No page query or next-page action is provided.", "클래식 모드 01 CAN의 00–C0 페이지만 대상입니다. 과거 스키마와 제품 범위는 SAE 전체를 포괄하지 않습니다. 페이지 질의나 다음 페이지 실행 동작은 제공하지 않습니다."))
                Text(RecordedDiagnosticText.text("Support is per exact ECU and session context. It is not verified vehicle identity or sensor quality.", "지원은 정확한 ECU와 세션 문맥별입니다. 검증된 차량 신원이나 센서 품질을 뜻하지 않습니다."))
            } header: { Text(RecordedDiagnosticText.text("Protocol limits", "프로토콜 제한")) }
        }
        .navigationTitle(RecordedDiagnosticText.text("Recorded PID support", "기록된 PID 지원"))
        .accessibilityIdentifier("recorded-pid-support")
    }
    @ViewBuilder
    private func context(_ value: Mode01SupportPage.Context) -> some View {
        RecordedEvidenceField(label: RecordedDiagnosticText.text("Local vehicle context label", "로컬 차량 문맥 이름"), value: value.vehicle)
        RecordedEvidenceField(label: RecordedDiagnosticText.text("Adapter context", "어댑터 문맥"), value: value.adapter)
        RecordedEvidenceField(label: RecordedDiagnosticText.text("Session", "세션"), value: value.session)
        RecordedEvidenceField(label: RecordedDiagnosticText.text("Generation", "세대"), value: value.generation)
        RecordedEvidenceField(label: RecordedDiagnosticText.text("Protocol variant", "프로토콜 변형"), value: value.protocolVariant.rawValue)
        RecordedEvidenceField(label: RecordedDiagnosticText.text("Request / response CAN ID", "요청 / 응답 CAN ID"), value: String(format: "%X / %X", value.requestCANID, value.responseCANID))
    }
    private var candidateName: String {
        switch candidate {
        case .load: return RecordedDiagnosticText.text("Calculated engine load", "계산된 엔진 부하")
        case .fuelPressure: return RecordedDiagnosticText.text("Fuel pressure (PID 0A)", "연료 압력 (PID 0A)")
        case .manifoldPressure: return RecordedDiagnosticText.text("Intake manifold pressure", "흡기 매니폴드 압력")
        case .intakeTemperature: return RecordedDiagnosticText.text("Intake air temperature", "흡기 온도")
        case .airMassFlow: return RecordedDiagnosticText.text("Mass air flow", "공기 질량 유량")
        case .throttle: return RecordedDiagnosticText.text("Throttle position", "스로틀 위치")
        case .engineRuntime: return RecordedDiagnosticText.text("Engine runtime", "엔진 가동 시간")
        case .fuelLevel: return RecordedDiagnosticText.text("Fuel level", "연료 수준")
        case .barometricPressure: return RecordedDiagnosticText.text("Barometric pressure", "대기압")
        case .moduleVoltage: return RecordedDiagnosticText.text("Control module voltage", "제어 모듈 전압")
        case .ambientTemperature: return RecordedDiagnosticText.text("Ambient air temperature", "외기 온도")
        case .oilTemperature: return RecordedDiagnosticText.text("Engine oil temperature", "엔진 오일 온도")
        case .fuelRate: return RecordedDiagnosticText.text("Engine fuel rate", "엔진 연료 유량")
        case .railGaugePressure: return RecordedDiagnosticText.text("Fuel rail pressure (atmospheric gauge)", "연료 레일 압력 (대기압 기준 게이지)")
        }
    }
}
