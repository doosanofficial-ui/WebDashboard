import SwiftUI
import TelemetryCore

@MainActor
struct SavedPlaceDraftView: View {
    enum Intent {
        case select(expectedRevision: UInt64, place: SavedPlace)
        case review(SavedPlaceDraftPlan)
        case cancel(expectedRevision: UInt64, selectedID: String?)
    }
    let snapshot: SavedPlaceSnapshot
    var selectedID: String? = nil
    var hostPermission = false
    var onIntent: ((Intent) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                Text(DestinationDraftCopy.savedTitle.text).font(.title2.weight(.semibold))
                Text(DestinationDraftCopy.savedPrivacy.text).font(.callout)
                Text(DestinationDraftCopy.unknown.text).font(.callout)
                Text(DestinationDraftCopy.choosePlace.text).font(.headline)
                if snapshot.places.isEmpty { Text(DestinationDraftCopy.noPlaces.text) }
                ForEach(snapshot.places, id: \.id) { place in
                    Button {
                        guard hostPermission, let onIntent else { return }
                        onIntent(.select(expectedRevision: snapshot.revision, place: place))
                    } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: place.label)
                            if selectedID == place.id {
                                Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.bordered).disabled(!hostPermission || onIntent == nil)
                    .accessibilityAddTraits(selectedID == place.id ? [.isSelected] : [])
                }
                if let selected = snapshot.places.first(where: { $0.id == selectedID }) {
                    SavedPlaceEditor(snapshot: snapshot, selected: selected,
                        hostPermission: hostPermission, onIntent: onIntent)
                        .id(selected.id)
                } else { Text(DestinationDraftCopy.noSelection.text) }
                if !hostPermission || onIntent == nil {
                    Text(DestinationDraftCopy.disabled.text).foregroundStyle(TelemetryTheme.warning)
                }
            }.telemetrySurface().padding(TelemetryTheme.Spacing.medium)
        }.background(TelemetryTheme.background).foregroundStyle(.white).tint(TelemetryTheme.accent)
    }
}

@MainActor
private struct SavedPlaceEditor: View {
    let snapshot: SavedPlaceSnapshot
    let selected: SavedPlace
    let hostPermission: Bool
    let onIntent: ((SavedPlaceDraftView.Intent) -> Void)?
    @State private var baseline: SavedPlaceSnapshot
    @State private var original: SavedPlace
    @State private var label: String
    @State private var kind: SavedPlace.Kind
    @State private var rejectedInput = false
    @State private var review: SavedPlaceDraftPlan?
    @State private var sent = false
    @State private var cancelled = false

    init(snapshot: SavedPlaceSnapshot, selected: SavedPlace, hostPermission: Bool,
         onIntent: ((SavedPlaceDraftView.Intent) -> Void)?) {
        self.snapshot = snapshot; self.selected = selected
        self.hostPermission = hostPermission; self.onIntent = onIntent
        // Intentional immutable baseline for this edit session. Never silently refresh a draft.
        _baseline = State(initialValue: snapshot); _original = State(initialValue: selected)
        _label = State(initialValue: selected.label); _kind = State(initialValue: selected.kind)
    }
    private var current: Bool { snapshot == baseline && selected == original }
    private var enabled: Bool { current && hostPermission && onIntent != nil && !sent && !cancelled }
    private var plan: SavedPlaceDraftPlan? {
        guard current, !rejectedInput else { return nil }
        return try? SavedPlaceDraftPlan(baseline: baseline, selected: original, label: label, kind: kind)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            if !current { Text(DestinationDraftCopy.stale.text).foregroundStyle(TelemetryTheme.warning) }
            if let review {
                Text(DestinationDraftCopy.reviewTitle.text).font(.headline)
                Text(verbatim: review.replacement.label).font(.body)
                Text(kindCopy(review.replacement.kind)).font(.subheadline)
                Text(DestinationDraftCopy.validPlan.text)
                Text(DestinationDraftCopy.notCommitted.text)
                Button(DestinationDraftCopy.requestReview.text) {
                    guard enabled, review.baseline == snapshot, review.selected == selected else { return }
                    sent = true
                    onIntent?(.review(review))
                }.disabled(!enabled).buttonStyle(.borderedProminent)
                Button(DestinationDraftCopy.back.text) { self.review = nil }.disabled(sent)
            } else {
                TextField(DestinationDraftCopy.label.text, text: Binding(get: { label }, set: { value in
                    guard enabled else { return }
                    rejectedInput = !DestinationDraftText.labelAllowed(value)
                    if !rejectedInput { label = value }
                })).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .textInputAutocapitalization(.never).disabled(!enabled)
                Picker(DestinationDraftCopy.kind.text, selection: $kind) {
                    Text(DestinationDraftCopy.home.text).tag(SavedPlace.Kind.home)
                    Text(DestinationDraftCopy.work.text).tag(SavedPlace.Kind.work)
                    Text(DestinationDraftCopy.other.text).tag(SavedPlace.Kind.other)
                }.disabled(!enabled)
                if plan == nil || rejectedInput {
                    Text(DestinationDraftCopy.invalidPlan.text).foregroundStyle(TelemetryTheme.warning)
                }
                Button(DestinationDraftCopy.review.text) {
                    guard enabled else { return }; review = plan
                }.disabled(!enabled || plan == nil).buttonStyle(.bordered)
            }
            Button(DestinationDraftCopy.reset.text) {
                baseline = snapshot; original = selected; label = selected.label; kind = selected.kind
                review = nil; rejectedInput = false; sent = false; cancelled = false
            }
            Button(DestinationDraftCopy.cancel.text, role: .cancel) {
                review = nil; label = ""; rejectedInput = false; cancelled = true
                if hostPermission { onIntent?(.cancel(expectedRevision: baseline.revision, selectedID: original.id)) }
            }
        }.accessibilityElement(children: .contain)
    }
    private func kindCopy(_ value: SavedPlace.Kind) -> String {
        switch value {
        case .home: DestinationDraftCopy.home.text
        case .work: DestinationDraftCopy.work.text
        case .other: DestinationDraftCopy.other.text
        }
    }
}
