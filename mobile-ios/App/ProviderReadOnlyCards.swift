import SwiftUI
import Foundation
import TelemetryCore

// PREPARATION ONLY: no mounting, provider access, playback, speech, notification or UI commands.
// The future host must refresh `now` from the SAME monotonic domain, even without callbacks,
// and drop inputs immediately on scope changes, teardown, authorization loss or provider failure.
@MainActor
private enum ProviderCardText {
    static func plain(_ value: String?, limit: Int = 512) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= limit,
              !value.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
              }) else { return nil }
        return value
    }
    static func localized(_ value: String) -> String { AppLocalization.text(value) }
    static func number(_ value: Double?, locale: Locale) -> String? {
        guard let value, value.isFinite, abs(value) <= 1_000_000_000_000 else { return nil }
        return value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }
}

@MainActor
private struct ProviderCardRow: View {
    let label: String
    let value: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: ProviderCardText.localized(label)).font(.caption)
            Text(verbatim: value ?? ProviderCardText.localized("Unknown"))
                .font(.body).monospacedDigit()
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct ProviderCardFrame<Content: View>: View {
    let title: String
    let symbol: String
    let identifier: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            HStack(alignment: .top) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(verbatim: ProviderCardText.localized(title)).font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .telemetrySurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .privacySensitive()
    }
}

/// Numeric weather only. Never combine this source with an independently scoped condition icon.
@MainActor
struct ProviderWeatherValuesCard: View {
    let state: WeatherPresentationState
    let now: Double
    let offline: Bool
    @Environment(\.locale) private var locale
    private var evaluated: (WeatherPresentationState.Presentation, WeatherSnapshot?) {
        var copy = state
        let status = copy.presentation(now: now, offline: offline)
        guard let snapshot = copy.snapshot,
              ProviderCardText.plain(snapshot.metadata.attribution, limit: 2048) != nil else {
            return (.unavailable, nil)
        }
        return (status, snapshot)
    }
    var body: some View {
        let (status, snapshot) = evaluated
        ProviderCardFrame(title: "Provider weather", symbol: "thermometer.medium", identifier: "provider-weather-values") {
            ProviderCardRow(label: "Weather availability", value: ProviderCardText.localized(statusTitle(status)))
            ProviderCardRow(label: "Source", value: ProviderCardText.localized("Provider current conditions, not vehicle sensors"))
            if let snapshot {
                ProviderCardRow(label: "Temperature (°C)", value: ProviderCardText.number(snapshot.conditions.temperatureCelsius, locale: locale))
                ProviderCardRow(label: "Pressure (hPa)", value: ProviderCardText.number(snapshot.conditions.pressureHectopascals, locale: locale))
                ProviderCardRow(label: "Relative humidity (%)", value: ProviderCardText.number(snapshot.conditions.relativeHumidityFraction.map { $0 * 100 }, locale: locale))
                ProviderCardRow(label: "Wind (m/s)", value: ProviderCardText.number(snapshot.conditions.windMetersPerSecond, locale: locale))
                ProviderCardRow(label: "Provider attribution", value: ProviderCardText.plain(snapshot.metadata.attribution, limit: 2048))
            }
        }
    }
    private func statusTitle(_ status: WeatherPresentationState.Presentation) -> String {
        switch status {
        case .unavailable: return "Unavailable"
        case .fresh: return "Fresh provider observation"
        case .stale: return "Stale observation, not current weather"
        case .offline: return "Offline, retained observation"
        case .failed: return "Refresh failed, retained observation"
        }
    }
}

/// Separate provider identity and lifetime; daylight is explicit text, never inferred from clock/GPS.
@MainActor
struct ProviderWeatherConditionCard: View {
    let display: ProviderWeatherDisplay
    let now: Double
    private var snapshot: ProviderWeatherDisplay.Snapshot? {
        var copy = display
        return copy.render(now: now)
    }
    var body: some View {
        let item = snapshot
        let condition = item?.values.condition ?? .unknown
        ProviderCardFrame(title: "Provider weather condition", symbol: symbol(condition), identifier: "provider-weather-condition") {
            ProviderCardRow(label: "Condition", value: ProviderCardText.localized(conditionTitle(condition)))
            ProviderCardRow(label: "Daylight", value: ProviderCardText.localized(daylightTitle(item?.values.daylight ?? .unknown)))
            ProviderCardRow(label: "Source", value: ProviderCardText.localized(item == nil ? "Unavailable or expired" : "Provider-observed weather"))
            ProviderCardRow(label: "Provider attribution", value: ProviderCardText.plain(item?.attribution, limit: 2048))
        }
    }
    private func conditionTitle(_ value: ProviderWeatherDisplay.Condition) -> String {
        switch value {
        case .unknown: return "Unknown"
        case .clear: return "Clear"
        case .partlyCloudy: return "Partly cloudy"
        case .cloudy: return "Cloudy"
        case .rain: return "Rain"
        case .snow: return "Snow"
        case .sleet: return "Sleet"
        case .hail: return "Hail"
        case .thunderstorm: return "Thunderstorm"
        case .fog: return "Fog"
        case .wind: return "Wind"
        case .dust: return "Dust"
        }
    }
    private func daylightTitle(_ value: ProviderWeatherDisplay.Daylight) -> String {
        switch value { case .unknown: return "Unknown"; case .day: return "Day"; case .night: return "Night" }
    }
    private func symbol(_ value: ProviderWeatherDisplay.Condition) -> String {
        // Original SF Symbol mapping. No sun/moon selection from inferred day/night.
        switch value {
        case .cloudy, .partlyCloudy: return "cloud"
        case .rain: return "cloud.rain"
        case .snow: return "cloud.snow"
        case .sleet: return "cloud.sleet"
        case .hail: return "cloud.hail"
        case .thunderstorm: return "cloud.bolt.rain"
        case .fog: return "cloud.fog"
        case .wind: return "wind"
        case .clear, .dust, .unknown: return "questionmark.circle"
        }
    }
}

@MainActor
struct ProviderRouteEstimateCard: View {
    let display: ProviderRouteCard
    let now: Double
    @Environment(\.locale) private var locale
    private var snapshot: ProviderRouteCard.Snapshot? {
        var copy = display
        return copy.render(now: now)
    }
    var body: some View {
        let item = snapshot
        ProviderCardFrame(title: "Provider route estimate", symbol: "map", identifier: "provider-route-estimate") {
            ProviderCardRow(label: "Source", value: ProviderCardText.localized(item == nil ? "Unavailable or expired" : "Provider estimate, not guaranteed"))
            ProviderCardRow(label: "Current street", value: ProviderCardText.plain(item?.values.currentStreet))
            ProviderCardRow(label: "Remaining distance (m)", value: ProviderCardText.number(item?.values.remainingMeters, locale: locale))
            ProviderCardRow(label: "Remaining duration (s)", value: ProviderCardText.number(item?.values.remainingSeconds, locale: locale))
            ProviderCardRow(label: "Estimated arrival", value: arrival(item?.values.estimatedArrivalUnix))
            ProviderCardRow(label: "Provider attribution", value: ProviderCardText.plain(item?.attribution, limit: 2048))
        }
    }
    private func arrival(_ unix: Double?) -> String? {
        guard let unix, unix.isFinite, (0...253_402_300_799).contains(unix) else { return nil }
        return Date(timeIntervalSince1970: unix).formatted(.dateTime.year().month().day().hour().minute().timeZone().locale(locale))
    }
}

/// Lifecycle reflects accepted Core state only, not proof of fresh progress or an external nav app.
@MainActor
struct ProviderNavigationStatusCard: View {
    let lifecycle: NavigationLifecycle
    var body: some View {
        ProviderCardFrame(title: "Navigation lifecycle", symbol: "map", identifier: "provider-navigation-status") {
            ProviderCardRow(label: "Accepted lifecycle state", value: ProviderCardText.localized(lifecycle.active == nil ? "No active route" : "Route started, progress freshness unknown"))
            ProviderCardRow(label: "Pending request", value: ProviderCardText.localized(lifecycle.pending == nil ? "None" : "Waiting for provider"))
            ProviderCardRow(label: "Candidate route", value: ProviderCardText.localized(lifecycle.candidate == nil ? "None" : "Accepted, not started"))
        }
    }
}

/// Displays a proposal only. The host must clear it on expiry/stop; never execute suggestions here.
/// No raw Progress input: `verified == true` alone is not adapter verification.
@MainActor
struct ProviderGuidanceSuggestionCard: View {
    let suggestion: GuidancePresentation.Suggestion?
    // Adapter-provided expiry in its monotonic domain, not a fabricated provider timestamp.
    let expiresAt: Double
    let now: Double
    private var currentSuggestion: GuidancePresentation.Suggestion? {
        guard now.isFinite, now >= 0, expiresAt.isFinite, expiresAt > now else { return nil }
        if case .focusMap(_, let focusExpiry)? = suggestion {
            guard focusExpiry.isFinite, focusExpiry > now else { return nil }
        }
        return suggestion
    }
    @Environment(\.locale) private var locale
    var body: some View {
        ProviderCardFrame(title: "Guidance proposal", symbol: "info.circle", identifier: "provider-guidance-proposal") {
            ProviderCardRow(label: "Presentation only", value: ProviderCardText.localized("No spoken guidance or layout change"))
            ProviderCardRow(label: "Proposal", value: ProviderCardText.localized(title))
            if case .prompt(_, let distance)? = currentSuggestion, distance.isFinite, (0...50_000_000).contains(distance) {
                ProviderCardRow(label: "Observed maneuver distance (m)", value: ProviderCardText.number(distance, locale: locale))
            }
        }
    }
    private var title: String {
        switch currentSuggestion {
        case .none: return "No proposal"
        case .some(.focusMap): return "Map focus proposed"
        case .some(.restoreLayout): return "Layout restoration proposed"
        case .some(.prompt(let key, _)):
            // Closed allowlist: arbitrary provider strings are never translated or interpreted.
            switch key {
            case "guidance.turn.approach.left": return "Left turn approach proposed"
            case "guidance.turn.approach.right": return "Right turn approach proposed"
            case "guidance.turn.approach.straight": return "Straight approach proposed"
            case "guidance.turn.approach.uTurn": return "U-turn approach proposed"
            case "guidance.turn.now.left": return "Left turn prompt proposed"
            case "guidance.turn.now.right": return "Right turn prompt proposed"
            case "guidance.turn.now.straight": return "Straight prompt proposed"
            case "guidance.turn.now.uTurn": return "U-turn prompt proposed"
            default: return "Unknown proposal"
            }
        }
    }
}

@MainActor
struct ProviderScopedMediaCard: View {
    let media: ScopedMediaPresentation
    @Environment(\.locale) private var locale
    var body: some View {
        ProviderCardFrame(title: "Scoped media", symbol: "music.note", identifier: "provider-scoped-media") {
            ProviderCardRow(label: "Source", value: ProviderCardText.localized(sourceTitle))
            ProviderCardRow(label: "Authorization", value: ProviderCardText.localized(authorizationTitle))
            ProviderCardRow(label: "Observed playback state", value: ProviderCardText.localized(playbackTitle))
            ProviderCardRow(label: "Freshness", value: ProviderCardText.localized("Last source observation, freshness not tracked"))
            ProviderCardRow(label: "Title", value: media.eligible ? ProviderCardText.plain(media.title, limit: 2048) : nil)
            ProviderCardRow(label: "Artist", value: media.eligible ? ProviderCardText.plain(media.artist, limit: 2048) : nil)
            ProviderCardRow(label: "Observed elapsed (s)", value: media.eligible ? ProviderCardText.number(media.elapsed, locale: locale) : nil)
            ProviderCardRow(label: "Duration (s)", value: media.eligible ? ProviderCardText.number(media.duration, locale: locale) : nil)
            if media.eligible, let elapsed = media.elapsed, let duration = media.duration,
               duration.isFinite, duration > 0, elapsed.isFinite, elapsed >= 0, elapsed <= duration {
                ProgressView(value: elapsed / duration)
                    .accessibilityLabel(ProviderCardText.localized("Observed playback progress, not live"))
            }
            ProviderCardRow(label: "Privacy", value: ProviderCardText.localized("Local display only, excluded from export"))
        }
    }
    private var sourceTitle: String {
        switch media.source {
        case .none: return "No media source"
        case .appOwned: return "App-owned player"
        case .appleMusic: return "Apple Music, authorization required"
        case .unsupportedOtherApp: return "Other apps are unsupported"
        }
    }
    private var authorizationTitle: String {
        switch media.authorization {
        case .notRequired: return "Authorization not required"
        case .notDetermined: return "Authorization not determined"
        case .denied: return "Authorization denied"
        case .authorized: return "Authorized"
        }
    }
    private var playbackTitle: String {
        guard media.eligible else { return "Unavailable" }
        switch media.playback {
        case .unavailable: return "Unavailable"
        case .stopped: return "Stopped"
        case .paused: return "Paused"
        case .playing: return "Playing, last observation"
        case .buffering: return "Buffering"
        case .interrupted: return "Interrupted"
        }
    }
}

@MainActor
struct ProviderEvaluatedAlertsCard: View {
    let snapshot: ConditionAlertPresentation.Snapshot
    @Environment(\.locale) private var locale
    var body: some View {
        ProviderCardFrame(title: "Evaluated conditions", symbol: "exclamationmark.triangle", identifier: "provider-evaluated-alerts") {
            ProviderCardRow(label: "Source domain", value: ProviderCardText.localized(snapshot.scope.domain == .synthetic ? "Synthetic data" : "Vehicle data"))
            ProviderCardRow(label: "Scope", value: ProviderCardText.localized("Evaluated results only, not safety monitoring"))
            ProviderCardRow(label: "Active evidence including hidden conditions", value: snapshot.activeEvidenceCount.formatted(.number.locale(locale)))
            ProviderCardRow(label: "Unavailable conditions", value: snapshot.unavailableCount.formatted(.number.locale(locale)))
            if snapshot.rows.isEmpty {
                ProviderCardRow(label: "Visible conditions", value: ProviderCardText.localized("None visible, not an all-clear"))
            }
            ForEach(snapshot.rows, id: \.definition.id) { row in
                VStack(alignment: .leading, spacing: 6) {
                    ProviderCardRow(label: "Condition identifier", value: row.definition.id.rawValue.formatted(.number.locale(locale)))
                    ProviderCardRow(label: "Severity", value: ProviderCardText.localized(severity(row.definition.severity)))
                    ProviderCardRow(label: "Category", value: ProviderCardText.localized(category(row.definition.category)))
                    ProviderCardRow(label: "Evaluated state", value: ProviderCardText.localized(state(row.state)))
                    if row.lastConfirmedActive {
                        ProviderCardRow(label: "Retained evidence", value: ProviderCardText.localized("Last confirmed active; unavailable does not mean resolved"))
                    }
                }.accessibilityElement(children: .contain)
            }
        }
    }
    private func severity(_ value: ConditionAlertPresentation.Severity) -> String {
        switch value { case .warning: return "Warning"; case .attention: return "Attention"; case .information: return "Information" }
    }
    private func category(_ value: ConditionAlertPresentation.Category) -> String {
        switch value { case .condition: return "Condition"; case .diagnostic: return "Diagnostic"; case .telemetry: return "Telemetry" }
    }
    private func state(_ value: ConditionAlertPresentation.State) -> String {
        switch value {
        case .active: return "Active"
        case .resolved: return "Resolved"
        case .unknown: return "Unknown"
        case .stale: return "Stale"
        case .disconnected: return "Disconnected"
        }
    }
}
