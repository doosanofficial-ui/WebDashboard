import Foundation
import SwiftUI
import TelemetryCore

/// Presentation copy only. User/provider strings must never pass through localization.
@MainActor
enum DestinationDraftCopy: String, CaseIterable {
    case searchTitle = "Destination search draft"
    case query = "Place or address"
    case search = "Request suggestions"
    case searchPrivacy = "Searching may send this text to the selected provider. Home and work addresses can reveal private locations. Provider permission must be checked before transmission."
    case suggestionWarning = "Suggestions are not verified destinations. Selecting one does not resolve a place, request a route, or start navigation."
    case disabled = "No authorized host is connected. Actions are disabled."
    case noResults = "No current suggestions are available."
    case invalidQuery = "Enter plain text up to 128 Unicode scalars and 512 bytes. Control characters and address links are not supported."
    case selectSuggestion = "Select this suggestion for review only"
    case cancel = "Cancel draft"
    case reset = "Reset draft"
    case savedTitle = "Saved place draft"
    case savedPrivacy = "Home and work labels and coordinates are private location information. This draft does not save, delete, or share them."
    case choosePlace = "Select a saved place"
    case noPlaces = "No saved places were supplied."
    case label = "Place label"
    case kind = "Place kind"
    case home = "Home"
    case work = "Work"
    case other = "Other"
    case review = "Review proposed change"
    case reviewTitle = "Proposed saved place change"
    case requestReview = "Send draft for host review"
    case notCommitted = "This is an immutable local plan, not a saved change. A separate authorized commit and revision check are required."
    case unknown = "Destination validation is unknown. No provider or location check has run."
    case validPlan = "Local schema checks passed. Destination validation remains unknown."
    case invalidPlan = "Draft is invalid or conflicts with another saved place. Check the label and saved-place constraints before reviewing."
    case stale = "The selection or saved-place snapshot changed. Reset before reviewing."
    case noSelection = "Select a place before editing."
    case back = "Back to editing"
    var text: String { AppLocalization.text(rawValue) }
}

enum DestinationDraftText {
    /// Reject rather than silently truncate or normalize meaningful address text.
    static func queryAllowed(_ value: String, allowEmpty: Bool = false) -> Bool {
        if value.isEmpty { return allowEmpty }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.unicodeScalars.count <= 128, value.utf8.count <= 512,
              !value.contains(":"), !value.contains("/"), !value.contains("\\"),
              !value.lowercased().contains("www.") else { return false }
        return !value.unicodeScalars.contains {
            let n = $0.value
            return n < 32 || (127...159).contains(n) || (0x2028...0x202E).contains(n)
                || (0x2066...0x2069).contains(n)
        }
    }
    static func labelAllowed(_ value: String) -> Bool {
        guard value.unicodeScalars.count <= 80, value.utf8.count <= 320 else { return false }
        return queryAllowed(value, allowEmpty: true)
    }
}

/// Full value evidence is intentionally retained; the host must compare against its current
/// snapshot/selection before accepting. A review intent is never commit authority.
struct SavedPlaceDraftPlan {
    let baseline: SavedPlaceSnapshot
    let selected: SavedPlace
    let replacement: SavedPlace
    let proposed: SavedPlaceSnapshot

    init(baseline: SavedPlaceSnapshot, selected: SavedPlace, label: String, kind: SavedPlace.Kind) throws {
        guard baseline.places.contains(selected), DestinationDraftText.labelAllowed(label) else {
            throw SavedPlaceError.conflict
        }
        let replacement = try SavedPlace(id: selected.id, kind: kind, label: label,
            latitude: selected.latitude, longitude: selected.longitude)
        self.baseline = baseline
        self.selected = selected
        self.replacement = replacement
        self.proposed = try baseline.plan(expectedRevision: baseline.revision, operation: .edit(replacement))
    }
}
