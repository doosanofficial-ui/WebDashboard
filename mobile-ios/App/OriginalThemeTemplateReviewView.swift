import SwiftUI
import TelemetryCore

/// Text geometry only. No Canvas, background image, export, rendering or sharing.
/// OriginalThemeTemplate has a closed factory and four immutable region roles.
@MainActor
struct OriginalThemeTemplateReviewView: View {
    let template: OriginalThemeTemplate?
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            Text(verbatim: localized(.template)).font(.headline).accessibilityAddTraits(.isHeader)
            if let template {
                valueRow(.dimensions, "\(template.width) × \(template.height)")
                Text(verbatim: localized(.coordinateRule)).font(.callout)
                ForEach(template.reservedRegions, id: \.role) { region in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: localized(.region(region.role))).font(.subheadline.bold())
                        valueRow(.origin, "\(region.x), \(region.y)")
                        valueRow(.size, "\(region.width) × \(region.height)")
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(verbatim: localized(.instructions)).font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(template.instructionKeys, id: \.self) { key in
                    if let copy = ThemeReviewCopy.instruction(key) {
                        Text(verbatim: localized(copy))
                    }
                }
            } else {
                Text(verbatim: localized(.noTemplate))
            }
            Text(verbatim: localized(.schematicWarning)).font(.callout)
                .foregroundStyle(TelemetryTheme.warning)
        }
        .fixedSize(horizontal: false, vertical: true)
        .telemetrySurface()
    }

    private func localized(_ copy: ThemeReviewCopy) -> String {
        AppLocalization.text(copy.rawValue, language: language)
    }

    private func valueRow(_ label: ThemeReviewCopy, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: localized(label)).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.body.monospaced())
        }
        .accessibilityElement(children: .combine)
    }
}
