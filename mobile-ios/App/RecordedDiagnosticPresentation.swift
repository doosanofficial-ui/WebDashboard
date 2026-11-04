import Foundation
import SwiftUI
import TelemetryCore

/// Static localizations never receive source evidence or VIN.
@MainActor
enum RecordedDiagnosticText {
    static func text(_ en: String, _ ko: String) -> String {
        let translated = AppLocalization.text(en)
        return AppLanguageStore.shared.language == .korean && translated == en ? ko : translated
    }
    static func bounded(_ value: String, limit: Int = 256) -> String {
        String(value.prefix(limit)) + (value.count > limit ? "…" : "")
    }
    static func bytes(_ value: [UInt8]) -> String {
        value.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    static func status(_ value: RecordedDiagnosticStatus) -> String {
        switch value {
        case .positive: return text("Positive response", "정상 형식의 응답")
        case .noData: return text("No data", "데이터 없음")
        case .unsupported: return text("Reported unsupported", "미지원으로 보고됨")
        case .unknown: return text("Unknown", "알 수 없음")
        case .negative: return text("Negative response", "부정 응답")
        case .malformed: return text("Malformed evidence", "잘못된 형식의 근거")
        }
    }
    static func support(_ value: Mode01SupportPage.Support) -> String {
        switch value {
        case .supported: return text("Supported in this evidence", "이 근거에서 지원됨")
        case .unsupported: return text("Unsupported in this evidence", "이 근거에서 미지원")
        case .unknown: return text("Unknown", "알 수 없음")
        }
    }
    static func availability(_ value: Mode01SupportPage.Availability) -> String {
        switch value {
        case .unknown: return text("Unknown", "알 수 없음")
        case .responseReceived: return text("Response received", "응답 수신")
        case .noData: return text("No data", "데이터 없음")
        case .timedOut: return text("Timed out", "시간 초과")
        case .disconnected: return text("Disconnected", "연결 끊김")
        case .failed: return text("Failed", "실패")
        }
    }
}

@MainActor
struct RecordedEvidenceField: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.xSmall) {
            Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: RecordedDiagnosticText.bounded(value))
                .font(.body.monospaced()).fixedSize(horizontal: false, vertical: true)
            if value.count > 256 {
                Text(RecordedDiagnosticText.text("Display truncated; not complete evidence", "표시가 잘렸으며 완전한 근거가 아닙니다"))
                    .font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
