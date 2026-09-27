import SwiftUI
import TelemetryCore

struct SignalCatalogEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let model: TelemetryModel
    let profile: AdapterProfile
    @State private var signals: [SignalDefinition]
    @State private var selectedID: String?
    @State private var draft = SignalDraft()
    @State private var errorText: String?
    @State private var confirmDelete = false
    @State private var pendingDeleteOffsets: IndexSet?

    init(model: TelemetryModel, profile: AdapterProfile) {
        self.model = model
        self.profile = profile
        _signals = State(initialValue: profile.signals)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Signals") {
                    ForEach(signals, id: \.id) { signal in
                        Button {
                            selectedID = signal.id
                            draft = SignalDraft(signal)
                            errorText = nil
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(signal.name)
                                        .foregroundStyle(.primary)
                                    Text("\(signal.id) · 0x\(String(signal.canID, radix: 16, uppercase: true)) · \(signal.unit)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedID == signal.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityIdentifier("signal-definition-\(signal.id)")
                    }
                    .onDelete { offsets in
                        pendingDeleteOffsets = offsets
                        confirmDelete = true
                    }
                    Button("Add signal", systemImage: "plus") {
                        addSignal()
                    }
                    .accessibilityIdentifier("add-signal-definition")
                }

                if selectedID != nil {
                    Section("Definition") {
                        TextField("Signal ID", text: $draft.id)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Name", text: $draft.name)
                        TextField("CAN ID (0x123)", text: $draft.canID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("Extended 29-bit ID", isOn: $draft.isExtended)
                        LabeledContent("Start bit") {
                            TextField("0", text: $draft.startBit)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Bit length") {
                            TextField("8", text: $draft.bitLength)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        Picker("Byte order", selection: $draft.byteOrder) {
                            Text("Intel / little-endian").tag(ByteOrder.intel)
                            Text("Motorola / big-endian").tag(ByteOrder.motorola)
                        }
                        Toggle("Signed", isOn: $draft.isSigned)
                        LabeledContent("Factor") {
                            TextField("1", text: $draft.factor)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Offset") {
                            TextField("0", text: $draft.offset)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Minimum") {
                            TextField("Optional", text: $draft.minimum)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Maximum") {
                            TextField("Optional", text: $draft.maximum)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                        }
                        TextField("Unit", text: $draft.unit)
                        LabeledContent("Timeout seconds") {
                            TextField("0.5", text: $draft.timeout)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                        }
                        Button("Apply definition") { applyDraft() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("apply-signal-definition")
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Signal Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.replaceAdapterProfileSignals(signals) { dismiss() }
                    }
                    .disabled(signals.isEmpty)
                }
            }
            .confirmationDialog("Delete signal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete signal", role: .destructive) {
                    deletePendingSignals()
                }
            } message: {
                Text("The definition will be removed from this profile when you save.")
            }
            .onAppear {
                if selectedID == nil, let first = signals.first {
                    selectedID = first.id
                    draft = SignalDraft(first)
                }
            }
        }
    }


    private func deletePendingSignals() {
        guard let pendingDeleteOffsets else { return }
        signals.remove(atOffsets: pendingDeleteOffsets)
        if let selectedID, !signals.contains(where: { $0.id == selectedID }) {
            self.selectedID = signals.first?.id
            if let first = signals.first { draft = SignalDraft(first) }
        }
        self.pendingDeleteOffsets = nil
    }

    private func addSignal() {
        let baseID = "signal"
        var suffix = 1
        var id = baseID
        while signals.contains(where: { $0.id == id }) {
            suffix += 1
            id = "\(baseID)_\(suffix)"
        }
        guard let signal = try? SignalDefinition(
            id: id,
            name: "New Signal",
            canID: 0x123,
            isExtended: false,
            startBit: 0,
            bitLength: 8,
            byteOrder: .intel,
            isSigned: false,
            factor: 1,
            offset: 0,
            minimum: nil,
            maximum: nil,
            unit: "",
            timeout: 0.5
        ) else { return }
        signals.append(signal)
        selectedID = id
        draft = SignalDraft(signal)
    }

    private func applyDraft() {
        guard let selectedID,
              let index = signals.firstIndex(where: { $0.id == selectedID }) else { return }
        do {
            let updated = try draft.makeDefinition(enumMap: signals[index].enumMap)
            if updated.id != selectedID,
               signals.contains(where: { $0.id == updated.id }) {
                throw SignalDefinitionError.emptyIdentifier
            }
            signals[index] = updated
            self.selectedID = updated.id
            errorText = nil
        } catch {
            errorText = "Invalid signal definition: \(error.localizedDescription)"
        }
    }
}

private struct SignalDraft {
    var id = "signal"
    var name = "Signal"
    var canID = "0x123"
    var isExtended = false
    var startBit = "0"
    var bitLength = "8"
    var byteOrder: ByteOrder = .intel
    var isSigned = false
    var factor = "1"
    var offset = "0"
    var minimum = ""
    var maximum = ""
    var unit = ""
    var timeout = "0.5"

    init() {}

    init(_ signal: SignalDefinition) {
        id = signal.id
        name = signal.name
        canID = "0x\(String(signal.canID, radix: 16, uppercase: true))"
        isExtended = signal.isExtended
        startBit = String(signal.startBit)
        bitLength = String(signal.bitLength)
        byteOrder = signal.byteOrder
        isSigned = signal.isSigned
        factor = String(signal.factor)
        offset = String(signal.offset)
        minimum = signal.minimum.map { String($0) } ?? ""
        maximum = signal.maximum.map { String($0) } ?? ""
        unit = signal.unit
        timeout = String(signal.timeout)
    }

    func makeDefinition(enumMap: [UInt64: String]) throws -> SignalDefinition {
        try SignalDefinition(
            id: id.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            canID: try parseCANID(canID),
            isExtended: isExtended,
            startBit: try parseInt(startBit),
            bitLength: try parseInt(bitLength),
            byteOrder: byteOrder,
            isSigned: isSigned,
            factor: try parseDouble(factor),
            offset: try parseDouble(offset),
            minimum: parseOptionalDouble(minimum),
            maximum: parseOptionalDouble(maximum),
            unit: unit,
            timeout: try parseDouble(timeout),
            enumMap: enumMap
        )
    }

    private func parseCANID(_ value: String) throws -> UInt32 {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("0x"), let parsed = UInt32(normalized.dropFirst(2), radix: 16) {
            return parsed
        }
        guard let parsed = UInt32(normalized, radix: 10) else { throw SignalDefinitionError.invalidCANIdentifier }
        return parsed
    }

    private func parseInt(_ value: String) throws -> Int {
        guard let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SignalDefinitionError.invalidBitRange
        }
        return parsed
    }

    private func parseDouble(_ value: String) throws -> Double {
        guard let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SignalDefinitionError.nonFiniteScaling
        }
        return parsed
    }

    private func parseOptionalDouble(_ value: String) -> Double? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : Double(normalized)
    }
}
