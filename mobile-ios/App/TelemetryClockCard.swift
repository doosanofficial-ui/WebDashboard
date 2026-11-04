import SwiftUI
import Combine
import UIKit

/// Device wall clock, never a recording/replay timestamp. Source preparation only.
/// The caller may supply a fixed date and formatting locale for native previews/tests.
@MainActor
struct TelemetryClockCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var appLocale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @State private var scheduleRevision = 0

    let fixedDate: Date?
    let formattingLocale: Locale?
    let foreground: Color

    init(fixedDate: Date? = nil, formattingLocale: Locale? = nil,
         foreground: Color = .primary) {
        self.fixedDate = fixedDate
        self.formattingLocale = formattingLocale
        self.foreground = foreground
    }

    var body: some View {
        Group {
            if let fixedDate {
                face(at: fixedDate)
            } else if scenePhase == .active {
                // Unlike a 60-second periodic timer, this begins on minute boundaries.
                TimelineView(.everyMinute) { context in
                    face(at: context.date)
                }
                .id(scheduleRevision)
            } else {
                // No scheduled work survives the active branch. Foreground re-entry
                // constructs a new timeline with the current minute immediately.
                face(at: .now)
            }
        }
        .onReceive(Publishers.Merge3(
            NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification),
            NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification),
            NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
        )) { _ in
            guard fixedDate == nil, scenePhase == .active else { return }
            scheduleRevision &+= 1
        }
    }

    private func face(at date: Date) -> some View {
        // Labels follow the app language. Date/time follow the device's regional
        // and 12/24-hour preferences, not DashboardView's language-only locale.
        let locale = formattingLocale ?? .autoupdatingCurrent
        let language: AppLanguage = appLocale.language.languageCode?.identifier == "ko" ? .korean : .english
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened,
                                        locale: locale, calendar: calendar, timeZone: timeZone)
        let dateStyle = Date.FormatStyle(date: .complete, time: .omitted,
                                        locale: locale, calendar: calendar, timeZone: timeZone)
        return VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: TelemetryTheme.Spacing.xSmall) {
                Image(systemName: "clock")
                    .accessibilityHidden(true)
                Text(AppLocalization.text("Time", language: language))
            }
            .font(.headline)
            .foregroundStyle(TelemetryTheme.accent)

            Text(date, format: timeStyle)
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)

            Text(date, format: dateStyle)
                .font(.body)
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: timeZone.identifier)
                .font(.caption)
                .foregroundStyle(TelemetryTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .telemetrySurface(.standard)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("device-clock-card")
    }
}
