import SwiftUI
import TelemetryCore

/// Unmounted, metadata-only review. The caller owns all state and optional intents.
/// Host callbacks must recheck generation/digest; they must not report preview success,
/// commit, write or import as a side effect of this metadata-review action.
@MainActor
struct ThemeImageImportReviewView: View {
    let presentation: ThemeImageReviewPresentation
    let template: OriginalThemeTemplate?
    let language: AppLanguage
    var onReviewMetadata: ((ThemeImageReviewIntent) -> Void)? = nil
    var onCancel: ((UInt64) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                Text(verbatim: localized(.title)).font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                metadataCard
                previewCard
                OriginalThemeTemplateReviewView(template: template, language: language)
                if let template, let manifest = presentation.manifest,
                   template.width != manifest.width || template.height != manifest.height {
                    Text(verbatim: localized(.mismatch)).foregroundStyle(TelemetryTheme.warning)
                }
                actions
            }
            .padding(TelemetryTheme.Spacing.medium)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(TelemetryTheme.background)
        .foregroundStyle(.white)
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            Text(verbatim: localized(.metadata)).font(.headline).accessibilityAddTraits(.isHeader)
            row(.stage, stageText)
            row(.generation, String(presentation.generation))
            if let manifest = presentation.manifest {
                row(.dimensions, "\(manifest.width) × \(manifest.height)")
                row(.bytes, String(manifest.byteCount))
                row(.digest, digestText(manifest.sha256))
            } else {
                Text(verbatim: localized(.noCandidate))
            }
            Text(verbatim: localized(.structureWarning)).font(.callout)
                .foregroundStyle(TelemetryTheme.warning)
        }
        .telemetrySurface()
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            Label {
                Text(verbatim: localized(.preview)).font(.headline)
            } icon: {
                Image(systemName: "eye.slash").accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isHeader)
            Text(verbatim: localized(.previewWarning))
            Text(verbatim: localized(.blocked)).font(.body.weight(.semibold))
                .foregroundStyle(TelemetryTheme.warning)
        }
        .telemetrySurface()
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            if let onReviewMetadata, let intent = presentation.reviewIntent {
                Button { onReviewMetadata(intent) } label: {
                    Text(verbatim: localized(.review)).frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityHint(Text(verbatim: localized(.reviewHint)))
            }
            if let onCancel {
                Button(role: .cancel) { onCancel(presentation.generation) } label: {
                    Text(verbatim: localized(.cancel)).frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityHint(Text(verbatim: localized(.cancelHint)))
            }
        }
    }

    private var stageText: String {
        switch presentation.phase {
        case .idle: return localized(.idle)
        case .selecting: return localized(.selecting)
        case .awaitingNativePreview: return localized(.nativePreview)
        case .awaitingUserCommit: return localized(.reportedCommit)
        }
    }

    private func localized(_ copy: ThemeReviewCopy) -> String {
        AppLocalization.text(copy.rawValue, language: language)
    }

    /// Never truncate a hash into something that could be mistaken for exact identity.
    /// The structural contract supplies 64 lowercase ASCII hex characters.
    private func digestText(_ digest: String) -> String {
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return localized(.unavailable) }
        return digest
    }

    private func row(_ label: ThemeReviewCopy, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: localized(label)).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.body.monospaced())
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
