import SwiftUI
import TelemetryCore

/// Unmounted draft editor. Callback is for review presentation only, never automatic persistence.
@MainActor
struct LocalDisplaySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LocalDisplaySettingsDraft
    @State private var errorText: String?
    @State private var didSubmit = false
    let onReview: (LocalDisplaySettingsReview) -> Void

    init(seed: LocalDisplaySettingsSeed, onReview: @escaping (LocalDisplaySettingsReview) -> Void) {
        _draft = State(initialValue: LocalDisplaySettingsDraft(seed: seed))
        self.onReview = onReview
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(AppLocalization.text("Draft only. Review does not save or change vehicle data."))
                        .font(.callout)
                }
                LocalVehicleMetadataSection(draft: $draft)
                LocalDisplayUnitSection(draft: $draft)
                LocalAppearanceSection(draft: $draft, errorText: $errorText)
                Section {
                    Button(AppLocalization.text("Restore opening draft")) {
                        draft = LocalDisplaySettingsDraft(seed: draft.seed)
                        errorText = nil
                    }
                    .accessibilityIdentifier("local-settings-restore")
                    if let errorText {
                        Label(AppLocalization.text(errorText), systemImage: "exclamationmark.triangle")
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("local-settings-error")
                    }
                    Button(AppLocalization.text("Review draft")) { submitReview() }
                        .buttonStyle(.borderedProminent)
                        .disabled(didSubmit)
                        .accessibilityIdentifier("local-settings-review")
                }
            }
            .navigationTitle(AppLocalization.text("Local display settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.text("Cancel")) {
                        draft = LocalDisplaySettingsDraft(seed: draft.seed)
                        dismiss()
                    }
                }
            }
        }
    }

    private func submitReview() {
        guard !didSubmit else { return }
        do {
            let proposal = try draft.review()
            didSubmit = true
            onReview(proposal)
            dismiss()
        } catch LocalDisplaySettingsDraftError.invalidRPM {
            errorText = "RPM label must be blank or a whole number from 1 to 100000. This is a storage bound, not an engine limit."
        } catch {
            errorText = "Draft could not be reviewed. Check the choices or reopen this editor from the current workspace."
        }
    }
}

@MainActor
private struct LocalVehicleMetadataSection: View {
    @Binding var draft: LocalDisplaySettingsDraft

    var body: some View {
        Section {
            choice("Fuel description", selection: $draft.fuel, values: ["unknown", "mixed", "gasoline", "diesel", "electric", "hydrogen", "other"])
            choice("Powertrain description", selection: $draft.powertrain, values: ["unknown", "mixed", "ice", "hev", "phev", "bev", "fuelCell", "other"])
            choice("Gearbox description", selection: $draft.gearbox, values: ["unknown", "mixed", "manual", "automatic", "cvt", "ecvt", "dualClutch", "singleSpeed", "other"])
            choice("Turbo description", selection: $draft.turbo, values: ["unknown", "mixed", "present", "absent", "notApplicable"])
            TextField(AppLocalization.text("Optional RPM display label"), text: $draft.rpmText)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("local-settings-rpm")
            Text(AppLocalization.text("Descriptions are independent. They do not identify an ECU, enable queries or establish engine limits. RPM is only a display label."))
                .font(.footnote)
            Button(AppLocalization.text("Reset vehicle draft to unknown")) { draft.resetVehicleDraft() }
                .accessibilityIdentifier("local-settings-vehicle-reset")
        } header: {
            Text(AppLocalization.text("Vehicle display metadata"))
        }
    }

    private func choice(_ title: String, selection: Binding<String>, values: [String]) -> some View {
        Picker(AppLocalization.text(title), selection: selection) {
            ForEach(values, id: \.self) { value in
                Text(AppLocalization.text(LocalSettingsLabels.vehicle[value] ?? value)).tag(value)
            }
        }
    }
}

@MainActor
private struct LocalDisplayUnitSection: View {
    @Binding var draft: LocalDisplaySettingsDraft
    private let quantities: [DUQuantity] = [.speed, .distance, .temperature, .pressure, .volume, .energy, .percentage, .economy]

    var body: some View {
        Section {
            ForEach(quantities, id: \.rawValue) { quantity in
                Picker(AppLocalization.text(LocalSettingsLabels.quantity(quantity)), selection: Binding(
                    get: { draft[unit: quantity] },
                    set: { draft[unit: quantity] = $0 }
                )) {
                    Text(AppLocalization.text("Keep source unit")).tag("source")
                    ForEach(LocalSettingsLabels.units(quantity), id: \.rawValue) { unit in
                        Text(AppLocalization.text(LocalSettingsLabels.unit(unit))).tag(unit.rawValue)
                    }
                }
                .accessibilityIdentifier("local-settings-unit-\(quantity.rawValue)")
            }
            Text(AppLocalization.text("Display preferences do not rewrite source records. US gallons and imperial gallons are different units. Unsupported conversions stay unavailable."))
                .font(.footnote)
            Button(AppLocalization.text("Use source units for all displays")) { draft.units.removeAll() }
        } header: {
            Text(AppLocalization.text("Display units"))
        }
    }
}

@MainActor
private struct LocalAppearanceSection: View {
    @Binding var draft: LocalDisplaySettingsDraft
    @Binding var errorText: String?

    var body: some View {
        Section {
            ForEach(AppearanceThemeID.allCases, id: \.rawValue) { id in
                Button {
                    do { draft.appearance = try draft.appearance.selecting(id); errorText = nil }
                    catch { errorText = "Appearance draft is invalid." }
                } label: {
                    Label(AppLocalization.text(LocalSettingsLabels.theme(id)), systemImage:
                        draft.appearance.selected == id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.primary)
                }
                .accessibilityAddTraits(draft.appearance.selected == id ? [.isSelected] : [])
                .accessibilityIdentifier("local-settings-theme-\(id.rawValue)")
            }
            if let palette = try? draft.appearance.palette() {
                LocalAppearancePalettePreview(palette: palette)
            }
            Button(AppLocalization.text("Reset only this theme's draft overrides")) {
                do { draft.appearance = try draft.appearance.resetting(draft.appearance.selected); errorText = nil }
                catch { errorText = "Appearance draft is invalid." }
            }
            Text(AppLocalization.text("Other themes keep their overrides. Existing appearance scheduling is unchanged. Preview colors do not guarantee rendered contrast or driving safety."))
                .font(.footnote)
            Text(AppLocalization.text("No background image is imported. Native preview and accessibility checks are required before applying."))
                .font(.footnote)
        } header: {
            Text(AppLocalization.text("Appearance draft"))
        }
    }
}

@MainActor
private struct LocalAppearancePalettePreview: View {
    let palette: AppearancePalette
    var body: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            Text(AppLocalization.text("Palette preview only"))
                .font(.headline)
                .foregroundStyle(color(.text))
            ForEach(AppearanceToken.foregrounds, id: \.rawValue) { token in
                Text(AppLocalization.text(LocalSettingsLabels.token(token)))
                    .foregroundStyle(color(token))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(TelemetryTheme.Spacing.xSmall)
                    .background(color(.surface))
            }
        }
        .padding(TelemetryTheme.Spacing.medium)
        .background(color(.background), in: RoundedRectangle(cornerRadius: TelemetryTheme.Radius.small))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("local-settings-palette-preview")
    }
    private func color(_ token: AppearanceToken) -> Color {
        guard let value = palette.tokens[token] else { return .primary }
        return Color(.sRGB, red: value.r, green: value.g, blue: value.b, opacity: value.a)
    }
}
