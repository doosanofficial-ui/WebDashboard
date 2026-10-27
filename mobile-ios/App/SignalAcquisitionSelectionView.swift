import SwiftUI
import TelemetryCore

/// The host supplies its current KR/EN presentation translator. Definition
/// names, query IDs and numeric timing values retain their original meaning.
struct SignalAcquisitionSelectionLabels {
    var text: (String) -> String = { $0 }
}

/// Edits a local draft. Only Apply emits an action; opening, filtering,
/// dismissing or changing a toggle never starts/stops a transport or recording.
@MainActor
struct SignalAcquisitionSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let profile: AdapterProfile
    let localContextID: String
    let profileRevision: String
    let policy: SignalAcquisitionPolicy?
    let canApply: Bool
    let labels: SignalAcquisitionSelectionLabels
    let onApply: (SignalAcquisitionSelectionChange) throws -> Void

    @State private var draftQueryIDs: Set<String>
    @State private var usesProfileDefaults: Bool
    @State private var reviewedBinding: DraftBinding
    @State private var reviewedReplacement = false
    @State private var errorText: String?

    init(profile: AdapterProfile, localContextID: String, profileRevision: String,
         policy: SignalAcquisitionPolicy?, canApply: Bool,
         labels: SignalAcquisitionSelectionLabels = .init(),
         onApply: @escaping (SignalAcquisitionSelectionChange) throws -> Void) {
        self.profile = profile
        self.localContextID = localContextID
        self.profileRevision = profileRevision
        self.policy = policy
        self.canApply = canApply
        self.labels = labels
        self.onApply = onApply
        _draftQueryIDs = State(initialValue: Set(policy?.selectedQueryIDs ?? profile.diagnosticQueries.map(\.id)))
        _usesProfileDefaults = State(initialValue: policy == nil)
        _reviewedBinding = State(initialValue: DraftBinding(profile: profile,
            localContextID: localContextID, profileRevision: profileRevision, policy: policy))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(profile.name).font(.headline)
                    Text(labels.text("Collect only selected read-only queries from this profile."))
                    Text(labels.text("Selections apply to whole queries, including every decoded signal in each response."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(labels.text("Dashboard pages, filters and widgets do not change acquisition or passive CAN recording."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent(labels.text("Selected queries"),
                        value: "\(visibleSelectedCount) / \(profile.diagnosticQueries.count)")
                        .accessibilityIdentifier("acquisition-selected-count")
                    Text(labels.text(usesProfileDefaults
                        ? "Profile defaults · all configured queries" : "Explicit selection"))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("acquisition-selection-mode")
                    Button(labels.text("Select all")) {
                        draftQueryIDs = Set(profile.diagnosticQueries.map(\.id))
                        usesProfileDefaults = false
                        errorText = nil
                    }
                    .disabled(needsReview)
                    .accessibilityIdentifier("acquisition-select-all")
                    Button(labels.text("Select none")) {
                        draftQueryIDs = []
                        usesProfileDefaults = false
                        errorText = nil
                    }
                    .disabled(needsReview)
                    .accessibilityIdentifier("acquisition-select-none")
                    Button(labels.text("Use profile defaults"), action: reviewDefaults)
                        .accessibilityIdentifier("acquisition-use-defaults")
                }

                Section {
                    if profile.diagnosticQueries.isEmpty {
                        Text(labels.text("No diagnostic queries are configured."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(profile.diagnosticQueries, id: \.id) { query in
                            SignalAcquisitionQueryRow(query: query, labels: labels,
                                isSelected: selectionBinding(for: query.id))
                                .disabled(needsReview)
                        }
                    }
                } header: {
                    Text(labels.text("Diagnostic queries"))
                } footer: {
                    Text(labels.text("Configured delay follows each completed query. Response time and other queries also affect update rate."))
                }

                if needsReview {
                    Section {
                        Text(labels.text("Saved selection no longer matches this context or profile. Use profile defaults to review a replacement."))
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("acquisition-review-required")
                    }
                }
                if !canApply {
                    Section {
                        Text(labels.text("Stop live acquisition before applying this selection."))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("acquisition-apply-deferred")
                    }
                }
                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                            .accessibilityIdentifier("acquisition-selection-error")
                    }
                }
            }
            .navigationTitle(labels.text("Query acquisition"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(labels.text("Cancel")) { dismiss() }
                        .accessibilityIdentifier("acquisition-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(labels.text("Apply selection"), action: applySelection)
                        .disabled(!canApply || needsReview)
                        .accessibilityIdentifier("acquisition-apply")
                }
            }
        }
    }

    private var currentBinding: DraftBinding {
        DraftBinding(profile: profile, localContextID: localContextID,
            profileRevision: profileRevision, policy: policy)
    }

    private var needsReview: Bool {
        guard reviewedBinding == currentBinding else { return true }
        guard !reviewedReplacement else { return false }
        return (try? SignalAcquisitionPolicy.resolve(policy, profile: profile,
            localContextID: localContextID, profileRevision: profileRevision)) == nil
    }

    private var visibleSelectedCount: Int {
        profile.diagnosticQueries.filter { draftQueryIDs.contains($0.id) }.count
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding {
            draftQueryIDs.contains(id)
        } set: { selected in
            if selected { draftQueryIDs.insert(id) } else { draftQueryIDs.remove(id) }
            usesProfileDefaults = false
            errorText = nil
        }
    }

    private func reviewDefaults() {
        draftQueryIDs = Set(profile.diagnosticQueries.map(\.id))
        usesProfileDefaults = true
        reviewedBinding = currentBinding
        reviewedReplacement = true
        errorText = nil
    }

    private func applySelection() {
        guard canApply, !needsReview else { return }
        do {
            let change = try SignalAcquisitionSelectionChange(previousPolicy: policy,
                selectedQueryIDs: usesProfileDefaults ? nil : Array(draftQueryIDs),
                profile: profile, localContextID: localContextID, profileRevision: profileRevision)
            try onApply(change)
            dismiss()
        } catch {
            errorText = labels.text("Unable to apply selection.")
        }
    }

    // Prevent a draft from being applied to a profile/context changed while
    // the sheet was open. Rebinding requires the explicit defaults action.
    private struct DraftBinding: Equatable {
        let localContextID: String
        let profileID: String
        let profileRevision: String
        let queries: [OBDQueryDefinition]
        let policy: SignalAcquisitionPolicy?

        init(profile: AdapterProfile, localContextID: String, profileRevision: String,
             policy: SignalAcquisitionPolicy?) {
            self.localContextID = localContextID
            profileID = profile.id
            self.profileRevision = profileRevision
            queries = profile.diagnosticQueries
            self.policy = policy
        }
    }
}

@MainActor
private struct SignalAcquisitionQueryRow: View {
    let query: OBDQueryDefinition
    let labels: SignalAcquisitionSelectionLabels
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) {
            VStack(alignment: .leading, spacing: 5) {
                Text(query.name).font(.headline)
                Text(verbatim: query.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(query.signals.map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                timing(labels.text("Configured delay"), seconds: query.pollInterval)
                timing(labels.text("Timeout"), seconds: query.timeout)
            }
        }
        .accessibilityIdentifier("acquisition-query-\(query.id)")
    }

    private func timing(_ title: String, seconds: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
            Text(seconds, format: .number.precision(.fractionLength(0...3)))
                .monospacedDigit()
            Text(labels.text("s"))
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}
