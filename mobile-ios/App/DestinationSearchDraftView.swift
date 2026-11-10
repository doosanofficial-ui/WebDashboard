import SwiftUI
import TelemetryCore

/// Unmounted, side-effect-free presentation. Host supplies an immutable Core snapshot.
@MainActor
struct DestinationSearchDraftView: View {
    enum Intent {
        case requestSuggestions(expectedGeneration: Int64, plaintext: String)
        case selectSuggestion(PlaceSearchPreparation.Selection)
        case cancel(expectedGeneration: Int64)
    }
    let preparation: PlaceSearchPreparation
    var resultToken: PlaceSearchPreparation.Token? = nil
    var hostPermission = false
    var onIntent: ((Intent) -> Void)? = nil

    var body: some View {
        DestinationSearchEditor(preparation: preparation, resultToken: resultToken,
            hostPermission: hostPermission, onIntent: onIntent)
            .id(preparation.generation)
    }
}

@MainActor
private struct DestinationSearchEditor: View {
    let preparation: PlaceSearchPreparation
    let resultToken: PlaceSearchPreparation.Token?
    let hostPermission: Bool
    let onIntent: ((DestinationSearchDraftView.Intent) -> Void)?
    @State private var query: String
    @State private var rejectedInput = false
    @State private var submitted = false
    @State private var cancelled = false

    init(preparation: PlaceSearchPreparation, resultToken: PlaceSearchPreparation.Token?,
         hostPermission: Bool, onIntent: ((DestinationSearchDraftView.Intent) -> Void)?) {
        self.preparation = preparation; self.resultToken = resultToken
        self.hostPermission = hostPermission; self.onIntent = onIntent
        // One-time draft seed; parent keys this editor by Core generation.
        _query = State(initialValue: preparation.query ?? "")
    }
    private var enabled: Bool { hostPermission && onIntent != nil && !cancelled && !submitted }
    private var canRequest: Bool { enabled && !rejectedInput && DestinationDraftText.queryAllowed(query) }
    private var currentRows: [PlaceSearchPreparation.Suggestion] {
        guard !rejectedInput, query == preparation.query, let token = resultToken,
              token.generation == preparation.generation else { return [] }
        return preparation.results.filter { preparation.select(token, resultID: $0.id) != nil }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                Text(DestinationDraftCopy.searchTitle.text).font(.title2.weight(.semibold))
                Text(DestinationDraftCopy.searchPrivacy.text).font(.callout)
                TextField(DestinationDraftCopy.query.text, text: Binding(get: { query }, set: { value in
                    guard enabled else { return }
                    rejectedInput = !DestinationDraftText.queryAllowed(value, allowEmpty: true)
                    if !rejectedInput { query = value }
                }))
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                .textInputAutocapitalization(.never).disabled(!enabled)
                .accessibilityLabel(DestinationDraftCopy.query.text)
                if rejectedInput { Text(DestinationDraftCopy.invalidQuery.text).foregroundStyle(TelemetryTheme.warning) }
                Button(DestinationDraftCopy.search.text) {
                    guard canRequest else { return }
                    submitted = true
                    onIntent?(.requestSuggestions(expectedGeneration: preparation.generation, plaintext: query))
                }.disabled(!canRequest).buttonStyle(.borderedProminent)
                Text(DestinationDraftCopy.suggestionWarning.text).font(.callout)
                if currentRows.isEmpty { Text(DestinationDraftCopy.noResults.text).font(.subheadline) }
                ForEach(currentRows, id: \.id) { row in
                    Button {
                        guard enabled, query == preparation.query, let token = resultToken,
                              let selection = preparation.select(token, resultID: row.id) else { return }
                        submitted = true
                        onIntent?(.selectSuggestion(selection))
                    } label: {
                        Text(verbatim: row.label).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .disabled(!enabled).buttonStyle(.bordered)
                    .accessibilityHint(DestinationDraftCopy.selectSuggestion.text)
                }
                if !hostPermission || onIntent == nil { Text(DestinationDraftCopy.disabled.text).foregroundStyle(TelemetryTheme.warning) }
                Button(DestinationDraftCopy.cancel.text, role: .cancel) {
                    query = ""; rejectedInput = false; cancelled = true
                    if hostPermission { onIntent?(.cancel(expectedGeneration: preparation.generation)) }
                }
            }
            .telemetrySurface().padding(TelemetryTheme.Spacing.medium)
        }.background(TelemetryTheme.background).foregroundStyle(.white).tint(TelemetryTheme.accent)
    }
}
