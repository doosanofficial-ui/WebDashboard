import Foundation
import SwiftUI
import TelemetryCore

/// A value-only view. Selecting a context, restoring evidence and collecting
/// queries belong to the parent; opening this view performs no acquisition.
struct VehicleCapabilityView: View {
    enum Language {
        case english, korean

        func text(_ english: String, _ korean: String) -> String {
            self == .korean ? korean : english
        }
    }

    let catalogue: ECUCapabilityCatalogue
    var language: Language = .english
    /// The parent supplies these from its existing TimelineView. A missing
    /// query at an explicit display time is unknown, never a cached fresh flag.
    var snapshotTime: Date? = nil
    var freshnessByQuery: [ECUCapabilityQueryID: ECUCapabilityCatalogue.Freshness] = [:]

    var body: some View {
        List {
            Section {
                CapabilityValueLine(label: language.text("Local context", "로컬 문맥"),
                                    value: catalogue.context.localContextID)
                CapabilityValueLine(label: language.text("Profile", "프로필"),
                                    value: catalogue.context.profileID)
                CapabilityValueLine(label: language.text("Profile revision", "프로필 리비전"),
                                    value: catalogue.context.profileRevision)
                CapabilityValueLine(label: language.text("Session", "세션"),
                                    value: catalogue.context.sessionID)
                if let snapshotTime {
                    CapabilityObservationTime(epoch: snapshotTime.timeIntervalSince1970,
                                              language: language, isDisplaySnapshot: true)
                }
                Text(language.text("A local label does not prove vehicle identity.",
                                   "로컬 이름은 차량 식별을 증명하지 않습니다."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if catalogue.entries.isEmpty {
                Text(language.text("No configured queries", "설정된 질의 없음"))
            }
            ForEach(catalogue.entries, id: \.query.id) { entry in
                CapabilityQuerySection(entry: entry, language: language, snapshotTime: snapshotTime,
                    snapshotFreshness: freshnessByQuery[ECUCapabilityQueryID(entry.query)])
            }
            Section {
                Text(language.text("Historical evidence does not establish current availability.",
                                   "과거 근거는 현재 가용 상태를 보장하지 않습니다."))
                Text(language.text("Configured delay is not guaranteed sampling frequency.",
                                   "설정 대기 시간은 보장된 수집 빈도가 아닙니다."))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle(language.text("Vehicle / ECU query evidence", "차량 / ECU 질의 근거"))
        .accessibilityIdentifier("vehicle-capability-catalogue")
    }
}

private struct CapabilityQuerySection: View {
    let entry: ECUCapabilityCatalogue.Entry
    let language: VehicleCapabilityView.Language
    let snapshotTime: Date?
    let snapshotFreshness: ECUCapabilityCatalogue.Freshness?

    var body: some View {
        Section {
            CapabilityValueLine(label: language.text("Query ID", "질의 ID"), value: entry.query.id)
            CapabilityValueLine(label: language.text("Query support evidence", "질의 지원 근거"),
                                value: evidenceStatus)
            if let evidence = entry.latestVehicleEvidence {
                CapabilityEvidenceDetails(evidence: evidence, language: language)
            }
            if let evidence = entry.historicalEvidence.last(where: { $0.origin == .syntheticFixture }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("Synthetic fixture evidence", "합성 fixture 근거"))
                        .font(.caption.weight(.semibold))
                    CapabilityEvidenceDetails(evidence: evidence, language: language)
                }
            }
            CapabilityValueLine(label: language.text("Current scheduler support", "현재 스케줄러 지원 상태"),
                                value: language.support(entry.currentSchedulerSupport))
            CapabilityValueLine(label: language.text("Current availability", "현재 가용 상태"),
                                value: availability)
            CapabilityValueLine(label: snapshotTime == nil
                ? language.text("Freshness at last update", "마지막 갱신 시 최신성")
                : language.text("Signal freshness", "신호 최신성"), value: freshness)
            if let state = entry.currentState {
                CapabilityValueLine(label: language.text("Observation origin", "관찰 출처"),
                                    value: language.origin(state.origin))
                CapabilityObservationTime(epoch: state.observedAtEpoch, language: language)
            } else {
                Text(language.text("No current observation", "현재 관찰 없음"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            CapabilityValueLine(label: language.text("Request / response", "요청 / 응답"),
                                value: targetDescription)
            CapabilityValueLine(label: language.text("Definition source", "정의 출처"),
                                value: "\(entry.query.sourceRepository) / \(entry.query.sourcePath)")
            CapabilityValueLine(label: language.text("Source revision", "출처 리비전"),
                                value: entry.query.sourceCommit)
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("Configured delay after each sequential query (seconds)",
                                   "각 순차 질의 후 설정 대기 시간(초)"))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(entry.query.pollInterval, format: .number.precision(.fractionLength(0...3)))
                    .font(.caption.monospacedDigit())
            }
        } header: {
            Text(verbatim: entry.query.name)
        }
        .accessibilityIdentifier("capability-query-\(entry.query.id)")
    }

    private var evidenceStatus: String {
        switch entry.vehicleQueryEvidenceStatus {
        case .candidate: return language.text("Definition only · candidate", "정의만 있음 · 후보")
        case .supported: return language.text("Query support observed", "질의 지원 관찰됨")
        case .unsupported:
            return language.text("Unsupported in observed support page", "관찰된 지원 페이지에서 미지원")
        }
    }

    private var availability: String {
        switch entry.currentState?.availability ?? .unknown {
        case .unknown: return language.text("Unknown", "알 수 없음")
        case .responseReceived: return language.text("Response received", "응답 수신")
        case .noData: return language.text("No data", "데이터 없음")
        case .timedOut: return language.text("Timed out", "시간 초과")
        case .disconnected: return language.text("Disconnected", "연결 끊김")
        case .failed: return language.text("Query failed", "질의 실패")
        }
    }

    private var freshness: String {
        let value = snapshotTime == nil
            ? entry.currentState?.freshness ?? .unknown
            : snapshotFreshness ?? .unknown
        switch value {
        case .unknown: return language.text("Unknown", "알 수 없음")
        case .fresh: return language.text("Fresh", "최신")
        case .stale: return language.text("Stale", "오래됨")
        }
    }

    private var targetDescription: String {
        let query = entry.query
        let format = query.isExtended ? "%08X" : "%03X"
        let addresses = "\(String(format: format, query.requestCANID)) → \(String(format: format, query.responseCANID))"
        let kind = query.isExtended
            ? language.text("Extended CAN identifier", "확장 CAN 식별자")
            : language.text("Standard CAN identifier", "표준 CAN 식별자")
        return "\(addresses) · \(query.service.rawValue)\(query.command) · \(kind)"
    }
}

private struct CapabilityEvidenceDetails: View {
    let evidence: ECUCapabilityCatalogue.SupportEvidence
    let language: VehicleCapabilityView.Language

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CapabilityValueLine(label: language.text("Historical query evidence", "과거 질의 근거"),
                                value: "\(language.origin(evidence.origin)) · \(language.support(evidence.support))")
            CapabilityObservationTime(epoch: evidence.observedAtEpoch, language: language)
            CapabilityValueLine(label: language.text("Evidence basis", "근거 종류"), value: basis)
            CapabilityValueLine(label: language.text("Session", "세션"), value: evidence.context.sessionID)
        }
    }

    private var basis: String {
        switch evidence.basis {
        case .positiveResponse: return language.text("Positive response", "정상 응답")
        case .schedulerSupport: return language.text("Scheduler support page", "스케줄러 지원 페이지")
        }
    }
}

private struct CapabilityValueLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label).font(.caption2).foregroundStyle(.secondary)
            Text(verbatim: value.isEmpty ? "—" : value)
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CapabilityObservationTime: View {
    let epoch: Double
    let language: VehicleCapabilityView.Language
    var isDisplaySnapshot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isDisplaySnapshot
                ? language.text("View snapshot time", "화면 기준 시각")
                : language.text("Observed at", "관찰 시각"))
                .font(.caption2).foregroundStyle(.secondary)
            Text(Date(timeIntervalSince1970: epoch), format: .dateTime.year().month().day().hour().minute().second())
                .font(.caption.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}

private extension VehicleCapabilityView.Language {
    func support(_ support: OBDQuerySupport) -> String {
        switch support {
        case .unknown: return text("Unknown", "알 수 없음")
        case .supported: return text("Supported", "지원")
        case .unsupported: return text("Unsupported", "미지원")
        }
    }

    func origin(_ origin: ECUCapabilityCatalogue.Origin) -> String {
        switch origin {
        case .vehicleSession: return text("Vehicle session", "차량 세션")
        case .syntheticFixture: return text("Synthetic fixture", "합성 fixture")
        }
    }
}
