import SwiftUI
import TelemetryCore

@MainActor
enum FillUpReviewPresentation {
    static func plain(_ value: String) -> String {
        let scalars = value.unicodeScalars.prefix(320).filter {
            !CharacterSet.controlCharacters.contains($0) &&
            !CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0)
        }
        return String(String(String.UnicodeScalarView(scalars)).prefix(160))
    }
    static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return AppLocalization.text("Unavailable") }
        return value.formatted(.number.precision(.significantDigits(1...6)))
    }
    static func volume(_ unit: LocalFillUpRecord.VolumeUnit) -> String {
        switch unit {
        case .liters: return "Liters"
        case .usGallons: return "US gallons"
        case .imperialGallons: return "Imperial gallons"
        }
    }
    static func tank(_ state: LocalFillUpRecord.TankState) -> String {
        switch state { case .full: return "Full fill"; case .partial: return "Partial fill"; case .unknown: return "Unknown" }
    }
    static func completeness(_ value: LocalFillUpRecord.Completeness) -> String {
        switch value { case .complete: return "All fills reported"; case .missing: return "Missing fills"; case .uncertain: return "Uncertain" }
    }
    static func exclusion(_ value: LocalFillUpHistory.Exclusion) -> String {
        switch value {
        case .incompleteHistory: return "Incomplete fill history"
        case .unknownTankState: return "Unknown tank state"
        case .missingVolume: return "Missing volume"
        case .odometerDiscontinuity: return "Odometer continuity unavailable"
        case .nonPositiveDistance: return "Distance must increase"
        case .numericRange: return "Numeric range unavailable"
        }
    }
}

@MainActor
struct FillUpReviewValue: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppLocalization.text(label)).font(.caption).foregroundStyle(TelemetryTheme.mutedText)
            Text(verbatim: FillUpReviewPresentation.plain(value))
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

/// Snapshot review only. Does not append, reorder, deduplicate, save or export supplied records.
@MainActor
struct ManualFillUpHistoryView: View {
    let records: [LocalFillUpRecord]
    private var summary: LocalFillUpHistory.Summary? {
        guard records.count <= 200 else { return nil }
        return try? LocalFillUpHistory.summarize(records)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                Text(AppLocalization.text("Manual fill-up history")).font(.title2)
                Text(AppLocalization.text("User-entered full-to-full estimate. Tank repeatability and entry error remain unquantified."))
                    .fixedSize(horizontal: false, vertical: true)
                if let summary {
                    if records.isEmpty { Text(AppLocalization.text("No fill-up records supplied")) }
                    ForEach(records, id: \.id) { record in
                        recordCard(record)
                    }
                    ForEach(summary.intervals, id: \.endID) { interval in
                        intervalCard(interval)
                    }
                    FillUpReviewValue(label: "Records without full anchors", value: String(summary.unanchoredRecordIDs.count))
                    Text(AppLocalization.text("Unanchored records do not establish consumed fuel."))
                } else {
                    Text(AppLocalization.text("History unavailable. Supply at most 200 unique records for one vehicle in strictly increasing time order."))
                        .foregroundStyle(TelemetryTheme.warning)
                }
            }.padding()
        }
        .background(TelemetryTheme.background)
    }
    private func recordCard(_ record: LocalFillUpRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            FillUpReviewValue(label: "Record identity", value: record.id)
            FillUpReviewValue(label: "Vehicle identity", value: record.vehicle)
            FillUpReviewValue(label: "Odometer reset epoch", value: record.epoch)
            FillUpReviewValue(label: "Reported Unix seconds", value: record.time.formatted(.number.grouping(.never).precision(.fractionLength(0...3))))
            FillUpReviewValue(label: record.distanceUnit == .km ? "Odometer in kilometers" : "Odometer in miles",
                              value: FillUpReviewPresentation.number(record.odometer))
            FillUpReviewValue(label: FillUpReviewPresentation.volume(record.volumeUnit),
                              value: FillUpReviewPresentation.number(record.volume))
            FillUpReviewValue(label: "Reported tank state", value: AppLocalization.text(FillUpReviewPresentation.tank(record.tank)))
            FillUpReviewValue(label: "Fill history since preceding record", value: AppLocalization.text(FillUpReviewPresentation.completeness(record.completeness)))
        }.telemetrySurface()
    }
    private func intervalCard(_ interval: LocalFillUpHistory.Interval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalization.text("Full-to-full interval")).font(.headline)
            FillUpReviewValue(label: "Starting record", value: interval.startID)
            FillUpReviewValue(label: "Ending record", value: interval.endID)
            FillUpReviewValue(label: "Included volume records", value: String(interval.includedVolumeRecordIDs.count))
            Text(AppLocalization.text("Starting full fill excluded; intervening partials and ending full fill included."))
                .font(.caption)
            if interval.exclusions.isEmpty {
                FillUpReviewValue(label: "Interval kilometers", value: FillUpReviewPresentation.number(interval.kilometers))
                FillUpReviewValue(label: "Interval liters", value: FillUpReviewPresentation.number(interval.liters))
                FillUpReviewValue(label: "Estimated liters per 100 kilometers", value: FillUpReviewPresentation.number(interval.litersPer100Kilometers))
            } else {
                ForEach(interval.exclusions, id: \.rawValue) { reason in
                    Text(AppLocalization.text(FillUpReviewPresentation.exclusion(reason)))
                        .foregroundStyle(TelemetryTheme.warning)
                }
            }
        }.telemetrySurface()
    }
}
