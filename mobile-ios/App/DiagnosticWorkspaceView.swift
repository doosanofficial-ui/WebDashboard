import SwiftUI
import TelemetryCore

/// Explicit settings UI; opening/filtering this screen never requests a PID.
struct DiagnosticWorkspaceView: View {
    @Bindable var state: DiagnosticWorkspaceState
    let profile: AdapterProfile?
    let allowsEditing: Bool
    let onApply: (SignalAcquisitionSelectionChange) throws -> Void
    @State private var newName = ""
    @State private var failure: String?
    @State private var selectionPresented = false

    private var korean: Bool { AppLanguageStore.shared.language == .korean }
    private func text(_ en: String, _ ko: String) -> String { korean ? ko : en }
    private var editable: Bool { allowsEditing && state.canEdit }

    var body: some View {
        Form {
            Section {
                Text(text("A local label separates your profiles and observed ECU evidence. It does not identify a vehicle automatically.",
                          "로컬 이름으로 프로필과 ECU 관찰 근거를 구분합니다. 차량을 자동으로 식별하지 않습니다."))
                    .font(.caption)
                Picker(text("Local context", "로컬 문맥"), selection: Binding<String?>(get: {
                    state.settings.selectedContextID
                }, set: { id in perform { try state.selectContext(id, profile: profile) } })) {
                    Text(text("Unassigned · profile defaults", "미지정 · 프로필 기본값")).tag(String?.none)
                    ForEach(state.settings.contexts) { context in Text(context.name).tag(Optional(context.id)) }
                }
                .disabled(!editable)
                .accessibilityIdentifier("diagnostic-context-picker")
                TextField(text("New local name", "새 로컬 이름"), text: $newName)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("diagnostic-context-name")
                Button(text("Add local context", "로컬 문맥 추가")) {
                    perform { try state.addContext(name: newName, profile: profile); newName = "" }
                }
                .disabled(!editable || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("diagnostic-context-add")
            } header: { Text(text("Vehicle / profile scope", "차량 / 프로필 범위")) }

            Section {
                if let profile {
                    Text(profile.name)
                    Button(text("Choose queries to collect", "수집할 질의 선택")) { selectionPresented = true }
                        .disabled(state.settings.selectedContextID == nil)
                        .accessibilityIdentifier("diagnostic-query-selection")
                    if state.settings.selectedContextID == nil {
                        Text(text("Without a local context, the existing profile defaults remain active. Add a context to save an explicit selection.",
                                  "로컬 문맥이 없으면 기존 프로필 기본값을 사용합니다. 명시적인 수집 선택을 저장하려면 문맥을 추가하세요."))
                            .font(.caption)
                    }
                } else {
                    Text(text("Import a verified adapter profile to choose its read-only queries.",
                              "검증된 어댑터 프로필을 불러오면 읽기 전용 질의를 선택할 수 있습니다."))
                }
                Text(text("Live pages, filters and widgets do not change query acquisition or raw recording.",
                          "Live 페이지, 필터, 위젯을 바꾸어도 질의 수집이나 원본 기록은 바뀌지 않습니다."))
                    .font(.caption)
                if !editable {
                    Text(text("Stop acquisition and leave Replay before changing the local context or selection.",
                              "로컬 문맥이나 수집 선택을 변경하려면 수집을 중지하고 Replay에서 나오세요."))
                        .font(.caption)
                }
            } header: { Text(text("Acquisition", "수집")) }

            Section {
                if let catalogue = state.catalogue {
                    NavigationLink(text("Inspect query support and availability", "질의 지원 근거와 가용 상태 보기")) {
                        TimelineView(.periodic(from: .now, by: 0.5)) { time in
                            VehicleCapabilityView(catalogue: state.catalogue ?? catalogue,
                                language: korean ? .korean : .english, snapshotTime: time.date,
                                freshnessByQuery: state.freshness(at: time.date))
                        }
                    }
                    .accessibilityIdentifier("diagnostic-capability-open")
                } else {
                    Text(text("Select a local context and profile to inspect configured candidates. No vehicle support is inferred.",
                              "로컬 문맥과 프로필을 선택하면 설정된 후보를 볼 수 있습니다. 차량 지원 여부를 추정하지 않습니다."))
                        .font(.caption)
                }
                if let message = state.storageError {
                    Text(AppLocalization.text(message)).foregroundStyle(.red)
                        .accessibilityIdentifier("diagnostic-workspace-storage-error")
                }
                if let message = state.evidenceSaveError {
                    Text(AppLocalization.text(message)).foregroundStyle(.orange)
                    Button(text("Retry saving evidence", "근거 저장 다시 시도")) { state.flushEvidence() }
                        .accessibilityIdentifier("diagnostic-evidence-save-retry")
                }
                if let message = state.observationError {
                    Text(AppLocalization.text(message)).foregroundStyle(.orange)
                        .accessibilityIdentifier("diagnostic-observation-unavailable")
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            } header: { Text(text("Observed evidence", "관찰 근거")) }
        }
        .navigationTitle(text("Diagnostic workspace", "진단 작업 공간"))
        .onChange(of: profile, initial: true) { _, current in
            perform { try state.preview(profile: current) }
        }
        .onChange(of: state.acquiring) { _, active in
            if !active { perform { try state.preview(profile: profile) } }
        }
        .sheet(isPresented: $selectionPresented) {
            if let profile, let contextID = state.settings.selectedContextID,
               let revision = try? DiagnosticWorkspaceState.revision(of: profile) {
                SignalAcquisitionSelectionView(profile: profile, localContextID: contextID,
                    profileRevision: revision, policy: try? state.settings.activePolicy(profileID: profile.id),
                    canApply: editable, labels: .init(text: { AppLocalization.text($0) }), onApply: onApply)
            }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); failure = nil }
        catch {
            failure = text("Change was not saved. Check the name, stop acquisition and review the current profile.",
                           "변경을 저장하지 못했습니다. 이름을 확인하고 수집을 중지한 뒤 현재 프로필을 검토하세요.")
        }
    }
}
