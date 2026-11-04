import SwiftUI
import TelemetryCore

@MainActor
struct ManualFillUpDraftView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ManualFillUpDraft()
    @State private var recordID = UUID().uuidString
    @State private var showingError = false
    @State private var rejectedFields: Set<String> = []
    let onReview: (ManualFillUpReviewEvent) -> Void

    var body: some View {
        Form {
            Section {
                Text(AppLocalization.text("Manual entry only. Nothing is saved or calibrated."))
                    .fixedSize(horizontal: false, vertical: true)
                field("Vehicle identity", value: $draft.vehicle, limit: 80, isValid: ManualFillUpDraft.isIdentity)
                field("Odometer reset epoch", value: $draft.epoch, limit: 80, isValid: ManualFillUpDraft.isIdentity)
                Text(AppLocalization.text("Use a new epoch after replacement, reset or rollover. Do not infer continuity."))
                    .font(.caption).foregroundStyle(.secondary)
                DatePicker(AppLocalization.text("Reported fill date"), selection: $draft.fillDate)
                    .onChange(of: draft.fillDate) { draft.dateConfirmed = false }
                Toggle(AppLocalization.text("I reviewed the reported date and time"), isOn: $draft.dateConfirmed)
                Text(AppLocalization.text("Reported time is not a verified post-fill anchor."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                field("Odometer reading", value: $draft.odometer, limit: 24) { ManualFillUpDraft.decimal($0) != nil }
                Picker(AppLocalization.text("Distance unit"), selection: $draft.distanceUnit) {
                    Text(AppLocalization.text("Kilometers")).tag(LocalFillUpRecord.DistanceUnit.km)
                    Text(AppLocalization.text("Miles")).tag(LocalFillUpRecord.DistanceUnit.miles)
                }
                field("Added volume; blank means unknown", value: $draft.volume, limit: 24) {
                    $0.isEmpty || ManualFillUpDraft.decimal($0).map({ $0 > 0 }) == true
                }
                Picker(AppLocalization.text("Volume unit"), selection: $draft.volumeUnit) {
                    Text(AppLocalization.text("Liters")).tag(LocalFillUpRecord.VolumeUnit.liters)
                    Text(AppLocalization.text("US gallons")).tag(LocalFillUpRecord.VolumeUnit.usGallons)
                    Text(AppLocalization.text("Imperial gallons")).tag(LocalFillUpRecord.VolumeUnit.imperialGallons)
                }
                Text(AppLocalization.text("Use digits and a decimal point. Units change interpretation, not entered numbers."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(AppLocalization.text("Reported tank state"), selection: $draft.tank) {
                    Text(AppLocalization.text("Unknown")).tag(LocalFillUpRecord.TankState.unknown)
                    Text(AppLocalization.text("Partial fill")).tag(LocalFillUpRecord.TankState.partial)
                    Text(AppLocalization.text("Full fill")).tag(LocalFillUpRecord.TankState.full)
                }
                Picker(AppLocalization.text("Fill history since preceding record"), selection: $draft.completeness) {
                    Text(AppLocalization.text("Uncertain")).tag(LocalFillUpRecord.Completeness.uncertain)
                    Text(AppLocalization.text("Missing fills")).tag(LocalFillUpRecord.Completeness.missing)
                    Text(AppLocalization.text("All fills reported")).tag(LocalFillUpRecord.Completeness.complete)
                }
                Text(AppLocalization.text("History completeness is a user assertion, not complete measured fuel coverage."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if showingError {
                    Text(AppLocalization.text("Review identities, date confirmation and numeric fields. Volume must be positive or blank."))
                        .foregroundStyle(TelemetryTheme.warning)
                        .accessibilityIdentifier("fillup.validationError")
                }
                Button(AppLocalization.text("Review draft only")) { review() }
                    .accessibilityIdentifier("fillup.reviewDraft")
                    .disabled(!rejectedFields.isEmpty)
                Button(AppLocalization.text("Reset draft")) { reset() }
                Button(AppLocalization.text("Cancel"), role: .cancel) {
                    reset(); onReview(.cancelled); dismiss()
                }
            }
        }
        .navigationTitle(AppLocalization.text("Manual fill-up draft"))
        .tint(TelemetryTheme.accent)
    }

    private func field(_ label: String, value: Binding<String>, limit: Int,
                       isValid: @escaping (String) -> Bool) -> some View {
        VStack(alignment: .leading) {
            Text(AppLocalization.text(label)).font(.caption)
            TextField(AppLocalization.text(label), text: Binding(
                get: { value.wrappedValue },
                set: { proposed in
                    // Never manufacture a different number or identity by clipping a paste.
                    guard proposed.count <= limit else {
                        rejectedFields.insert(label)
                        return
                    }
                    value.wrappedValue = proposed
                    if isValid(proposed) {
                        rejectedFields.remove(label)
                        showingError = false
                    }
                }
            ))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityLabel(AppLocalization.text(label))
            if rejectedFields.contains(label) {
                Text(AppLocalization.text("Correct this field before review. Overlong edits are rejected; the previous value is kept."))
                    .font(.caption).foregroundStyle(TelemetryTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func review() {
        guard rejectedFields.isEmpty else { return }
        do { onReview(.reviewDraft(try draft.reviewRecord(id: recordID))); showingError = false }
        catch { showingError = true }
    }
    private func reset() {
        draft = ManualFillUpDraft(); recordID = UUID().uuidString; showingError = false
        rejectedFields.removeAll()
    }
}
