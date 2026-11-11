import SwiftUI
import TelemetryCore

/// A local draft, deliberately separate from acquisition and observed evidence.
struct CustomPIDEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: TelemetryModel
    // Immutable optimistic-concurrency snapshot, not a mirror of live inputs.
    @State private var openedProfile: AdapterProfile?
    @State private var draft = CustomOBDPIDDraft()
    @State private var sample = ""
    @State private var preview: CustomOBDPIDDraft.Preview?
    @State private var message: String?
    @State private var showingMessage = false
    @FocusState private var focusedField: String?

    init(model: TelemetryModel, openedProfile: AdapterProfile?) {
        self.model = model
        _openedProfile = State(initialValue: openedProfile)
    }

    private var korean: Bool { AppLanguageStore.shared.language == .korean }
    private func text(_ en: String, _ ko: String) -> String { korean ? ko : en }
    private var canSave: Bool {
        model.canEditCustomPID && openedProfile == model.adapterProfile &&
        !(openedProfile?.diagnosticQueries.isEmpty ?? true) && (try? draft.makeQuery()) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(text("Read-only · local draft", "읽기 전용 · 로컬 초안"), systemImage: "lock.shield")
                    Text(text("Opening, previewing and saving never query the vehicle. Only services 01, 21 and 22 are allowed.",
                              "열기·미리보기·저장으로 차량에 질의하지 않습니다. 서비스 01, 21, 22만 허용됩니다."))
                        .font(.caption)
                    if let openedProfile, !openedProfile.diagnosticQueries.isEmpty {
                        Text(openedProfile.name).font(.caption.weight(.semibold))
                        Text(text("After saving, review your query selection in Diagnostic workspace before connecting. Profile defaults include all configured queries.",
                                  "저장 후 연결 전에 진단 작업 공간에서 수집할 질의를 검토하세요. 프로필 기본값은 설정된 모든 질의를 포함합니다."))
                            .font(.caption)
                    } else {
                        Text(text("Load a verified diagnostic adapter profile to save. A passive CAN profile is not changed into polling. You can still validate a local draft.",
                                  "저장하려면 검증된 진단 어댑터 프로필이 필요합니다. 수동 CAN 프로필을 폴링으로 바꾸지 않습니다. 로컬 초안 검증은 가능합니다."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.canEditCustomPID {
                        Text(text("Stop acquisition and recording, then leave Replay to save.",
                                  "저장하려면 수집과 기록을 중지하고 Replay에서 나오세요."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section(text("Identity", "신호 정보")) {
                    field("Signal ID", "신호 ID", $draft.id, "id")
                    field("Name", "이름", $draft.name, "name")
                    field("Unit", "단위", $draft.unit, "unit")
                }
                Section(text("Read-only request", "읽기 전용 요청")) {
                    Picker(text("Service", "서비스"), selection: $draft.service) {
                        Text("01").tag(OBDService.mode01)
                        Text("21").tag(OBDService.service21)
                        Text("22").tag(OBDService.service22)
                    }
                    .accessibilityIdentifier("custom-pid-service")
                    field("Identifier (hex)", "식별자 (16진수)", $draft.command, "command")
                    field("Request ECU (hex)", "요청 ECU (16진수)", $draft.requestCANID, "request")
                    field("Response ECU (hex)", "응답 ECU (16진수)", $draft.responseCANID, "response")
                    Toggle(text("Extended 29-bit address", "확장 29비트 주소"), isOn: $draft.isExtended)
                    Toggle(text("ISO-TP flow control", "ISO-TP 흐름 제어"), isOn: $draft.flowControl)
                }
                Section(text("Decoding", "디코딩")) {
                    Text(text("Value = raw × factor + offset. Bits start at the diagnostic payload, after service and identifier bytes.",
                              "값 = 원시값 × 배율 + 오프셋. 비트 위치는 서비스·식별자 다음의 진단 페이로드 기준입니다."))
                        .font(.caption)
                    field("Start bit", "시작 비트", $draft.startBit, "start-bit")
                    field("Bit length", "비트 길이", $draft.bitLength, "bit-length")
                    Picker(text("Byte order", "바이트 순서"), selection: $draft.byteOrder) {
                        Text("Intel / little-endian").tag(ByteOrder.intel)
                        Text("Motorola / big-endian").tag(ByteOrder.motorola)
                    }
                    Toggle(text("Signed", "부호 있음"), isOn: $draft.isSigned)
                    field("Factor", "배율", $draft.factor, "factor")
                    field("Offset", "오프셋", $draft.offset, "offset")
                    field("Minimum (optional)", "최솟값 (선택)", $draft.minimum, "minimum")
                    field("Maximum (optional)", "최댓값 (선택)", $draft.maximum, "maximum")
                    field("Poll interval (seconds)", "질의 간격 (초)", $draft.pollInterval, "interval")
                    field("Timeout (seconds)", "유효 시간 (초)", $draft.timeout, "timeout")
                }
                Section(text("Offline response preview", "오프라인 응답 미리보기")) {
                    Text(text("Paste a header-on ELM response. This is sample text, not a live reading or proof of vehicle support. Nothing is recorded.",
                              "ECU 헤더가 포함된 ELM 응답을 붙여 넣으세요. 입력된 예제이며 실시간 값이나 차량 지원 근거가 아닙니다. 기록하지 않습니다."))
                        .font(.caption)
                    TextField(text("Copied response", "복사한 응답"), text: $sample, axis: .vertical)
                        .lineLimit(3...8).font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: "sample")
                        .accessibilityIdentifier("custom-pid-sample")
                    Button(text("Decode sample", "예제 디코딩")) {
                        focusedField = nil
                        do { preview = try draft.preview(sample) }
                        catch { preview = nil; show(error) }
                    }
                    .accessibilityIdentifier("custom-pid-preview")
                    if let preview {
                        Text(text("SAMPLE · ", "예제 · ") + String(format: "%.6g", preview.value) + " " + preview.unit)
                            .font(.headline.monospacedDigit())
                            .accessibilityIdentifier("custom-pid-preview-value")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(text("New Custom PID", "커스텀 PID 추가"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(text("Cancel", "취소")) { dismiss() }
                        .accessibilityIdentifier("custom-pid-cancel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        focusedField = nil
                        do {
                            let query = try draft.makeQuery()
                            message = text("Valid read-only request: ", "유효한 읽기 전용 요청: ") + query.requestString.trimmingCharacters(in: .whitespacesAndNewlines)
                            showingMessage = true
                        } catch { show(error) }
                    } label: { Label(text("Validate", "검증"), systemImage: "checkmark.shield") }
                    .accessibilityIdentifier("custom-pid-validate")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(text("Save", "저장")) {
                        guard let openedProfile else { return }
                        do { try model.addCustomPID(draft, expected: openedProfile); dismiss() }
                        catch { show(error) }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("custom-pid-save")
                }
            }
            .alert(text("Custom PID", "커스텀 PID"), isPresented: $showingMessage) {
                Button(text("OK", "확인"), role: .cancel) {}
            } message: { Text(message ?? "") }
            .onChange(of: draft) { _, _ in preview = nil }
            .onChange(of: sample) { _, _ in preview = nil }
        }
    }

    private func field(_ en: String, _ ko: String, _ value: Binding<String>, _ id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text(en, ko)).font(.caption).foregroundStyle(.secondary)
            TextField(text(en, ko), text: value)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focusedField, equals: id)
                .accessibilityIdentifier("custom-pid-" + id)
        }
    }

    private func show(_ error: Error) {
        switch error {
        case CustomOBDPIDDraft.ValidationError.invalidField(let field):
            message = text("Check \(field).", "입력값을 확인하세요: \(field)")
        case CustomOBDPIDDraft.ValidationError.profileChanged:
            message = text("The profile changed. Cancel and reopen this editor.", "프로필이 변경되었습니다. 취소한 뒤 편집기를 다시 여세요.")
        case AdapterProfileError.duplicateSignalID, AdapterProfileError.duplicateDiagnosticQueryID:
            message = text("This signal ID already exists. Choose a unique ID.", "이미 있는 신호 ID입니다. 다른 ID를 입력하세요.")
        default:
            message = text("Check the request, ECU addresses, bit range, finite scale, limits and timing. A sample must match the request and expected ECU. Changes were not saved.",
                           "요청·ECU 주소·비트 범위·배율·한계·시간을 확인하세요. 예제는 요청과 응답 ECU가 일치해야 합니다. 변경은 저장되지 않았습니다.")
        }
        showingMessage = true
    }
}
