import SwiftUI
import TelemetryCore

@MainActor
struct RecordedReadinessSnapshotView: View {
    let snapshot: RecordedReadinessInterpretation
    private var state: String {
        switch snapshot.status {
        case .decoded: return RecordedDiagnosticText.text("Decoded for supplied schema", "제공된 스키마로 해석됨")
        case .partial: return RecordedDiagnosticText.text("Partial · contradictory or reserved bits", "부분 해석 · 모순되거나 예약된 비트")
        case .unknownSchema: return RecordedDiagnosticText.text("Unknown schema · raw evidence only", "스키마 불명 · 원본 근거만 표시")
        case .notApplicable: return RecordedDiagnosticText.text("Not applicable to this service", "이 서비스에 해당하지 않음")
        case .noData: return RecordedDiagnosticText.status(.noData)
        case .unsupported: return RecordedDiagnosticText.status(.unsupported)
        case .unknown: return RecordedDiagnosticText.status(.unknown)
        case .negative: return RecordedDiagnosticText.status(.negative)
        case .malformed: return RecordedDiagnosticText.status(.malformed)
        }
    }
    var body: some View {
        Form {
            Section {
                Text(RecordedDiagnosticText.text("Supplied readiness evidence, not an emissions-inspection result or engine identification.", "제공된 준비 상태 근거입니다. 배출가스 검사 결과나 엔진 식별이 아닙니다."))
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Source ECU", "출처 ECU"), value: snapshot.ecu)
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Interpretation state", "해석 상태"), value: state)
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Schema", "스키마"), value: snapshot.schema == .j1979DA2011 ? "SAE J1979-DA OCT2011" : RecordedDiagnosticText.text("Unknown", "알 수 없음"))
                if let family = snapshot.family {
                    RecordedEvidenceField(label: RecordedDiagnosticText.text("Monitor bit layout", "모니터 비트 배열"), value: family == .sparkMonitors ? RecordedDiagnosticText.text("Spark-monitor layout", "불꽃 점화 모니터 배열") : RecordedDiagnosticText.text("Compression-monitor layout", "압축 점화 모니터 배열"))
                }
                Text(RecordedDiagnosticText.text("Since-clear Mode 01 PID 01 only. Schema must be supplied explicitly; no model-year or fuel inference.", "코드 삭제 이후의 모드 01 PID 01만 대상입니다. 스키마는 명시적으로 제공해야 하며 연식이나 연료로 추정하지 않습니다."))
                    .font(.caption)
            }
            Section {
                if let monitors = snapshot.monitors {
                    ForEach(monitors, id: \.id) { monitor in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: monitorName(monitor.id)).font(.headline)
                            Text(verbatim: monitor.group == .nonContinuous ? RecordedDiagnosticText.text("Non-continuous monitor", "비연속 모니터") : RecordedDiagnosticText.text("Continuous / once per trip", "연속 / 주행당 1회"))
                            RecordedEvidenceField(label: RecordedDiagnosticText.text("Support bit", "지원 비트"), value: monitor.supported ? RecordedDiagnosticText.text("Set", "설정됨") : RecordedDiagnosticText.text("Not set", "설정되지 않음"))
                            RecordedEvidenceField(label: RecordedDiagnosticText.text("Completion", "완료 상태"), value: completion(monitor.completion))
                        }.accessibilityElement(children: .contain)
                    }
                } else {
                    Text(RecordedDiagnosticText.text("No decoded monitor list. Unknown is not complete.", "해석된 모니터 목록이 없습니다. 알 수 없음은 완료가 아닙니다."))
                }
                if !snapshot.issues.isEmpty {
                    RecordedEvidenceField(label: RecordedDiagnosticText.text("Interpreter issue tokens", "해석기 문제 토큰"), value: snapshot.issues.prefix(16).joined(separator: " · "))
                }
            } header: { Text(RecordedDiagnosticText.text("Readiness monitors", "준비 상태 모니터")) }
            Section {
                RecordedEvidenceField(label: RecordedDiagnosticText.text("Application PDU · hexadecimal", "응용 계층 PDU · 16진수"), value: RecordedDiagnosticText.bytes(snapshot.payload))
                if let raw = snapshot.raw {
                    RecordedEvidenceField(label: "B C D", value: RecordedDiagnosticText.bytes(raw))
                }
                if snapshot.evidenceTruncated || snapshot.payload.count > 64 {
                    Text(RecordedDiagnosticText.text("Display truncated; not complete evidence", "표시가 잘렸으며 완전한 근거가 아닙니다"))
                }
            } header: { Text(RecordedDiagnosticText.text("Supplied evidence", "제공된 근거")) }
        }
        .navigationTitle(RecordedDiagnosticText.text("Recorded readiness", "기록된 준비 상태"))
        .accessibilityIdentifier("recorded-readiness-snapshot")
    }
    private func completion(_ value: RecordedReadinessCompletion) -> String {
        switch value {
        case .complete: return RecordedDiagnosticText.text("Complete", "완료")
        case .incomplete: return RecordedDiagnosticText.text("Incomplete", "미완료")
        case .unknown: return RecordedDiagnosticText.text("Unknown", "알 수 없음")
        case .notApplicable: return RecordedDiagnosticText.text("Not applicable", "해당 없음")
        }
    }
    private func monitorName(_ id: String) -> String {
        switch id {
        case "misfire": return RecordedDiagnosticText.text("Misfire monitor", "실화 모니터")
        case "fuelSystem": return RecordedDiagnosticText.text("Fuel system monitor", "연료 시스템 모니터")
        case "components": return RecordedDiagnosticText.text("Component monitor", "구성품 모니터")
        case "catalyst": return RecordedDiagnosticText.text("Catalyst monitor", "촉매 모니터")
        case "heatedCatalyst": return RecordedDiagnosticText.text("Heated catalyst monitor", "가열 촉매 모니터")
        case "evaporative": return RecordedDiagnosticText.text("Evaporative monitor", "증발가스 모니터")
        case "secondaryAir": return RecordedDiagnosticText.text("Secondary air monitor", "2차 공기 모니터")
        case "oxygenSensor": return RecordedDiagnosticText.text("Oxygen sensor monitor", "산소 센서 모니터")
        case "oxygenHeater": return RecordedDiagnosticText.text("Oxygen heater monitor", "산소 센서 히터 모니터")
        case "egrVVT": return RecordedDiagnosticText.text("EGR / VVT monitor", "EGR / VVT 모니터")
        case "nmhcCatalyst": return RecordedDiagnosticText.text("NMHC catalyst monitor", "NMHC 촉매 모니터")
        case "noxSCR": return RecordedDiagnosticText.text("NOx / SCR monitor", "NOx / SCR 모니터")
        case "boostPressure": return RecordedDiagnosticText.text("Boost pressure monitor", "과급 압력 모니터")
        case "exhaustGasSensor": return RecordedDiagnosticText.text("Exhaust gas sensor monitor", "배기가스 센서 모니터")
        case "particulateFilter": return RecordedDiagnosticText.text("Particulate filter monitor", "입자 필터 모니터")
        default: return RecordedDiagnosticText.bounded(id)
        }
    }
}
