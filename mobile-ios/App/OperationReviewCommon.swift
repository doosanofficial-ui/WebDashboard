import SwiftUI
import Foundation

/// Display evidence only. These fields are NOT authorization or validity proofs.
struct OperationReviewContext {
    let revision: String
    let freshness: String
    let ownership: String
    let outcome: String
    static let unknown = Self(revision: "Unknown", freshness: "Unknown", ownership: "Unknown", outcome: "Unknown")
}

enum OperationReviewPlaintext {
    /// Bounds input before decoding; escapes controls/bidi/invisible scalars, never parses markup.
    static func render(_ data: Data) -> String {
        let source = String(decoding: data.prefix(1024), as: UTF8.self)
        var result = ""
        for scalar in source.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
                || (0x200B...0x200F).contains(scalar.value) || (0x2028...0x202E).contains(scalar.value)
                || (0x2060...0x206F).contains(scalar.value) || scalar.value == 0xFEFF {
                result += String(format: "\\u{%04X}", scalar.value)
            } else { result.unicodeScalars.append(scalar) }
        }
        return result
    }
    static func render(_ value: String) -> String { render(Data(value.utf8.prefix(1024))) }
}

@MainActor
struct OperationReviewText: View {
    let key: String
    var body: some View { Text(verbatim: AppLocalization.text(key)).fixedSize(horizontal: false, vertical: true) }
}

@MainActor
struct OperationReviewField: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            OperationReviewText(key: label).font(.caption)
            Text(verbatim: OperationReviewPlaintext.render(value)).font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

@MainActor
struct OperationReviewFrame<Content: View>: View {
    let title: String
    let context: OperationReviewContext
    let content: Content
    init(title: String, context: OperationReviewContext, @ViewBuilder content: () -> Content) {
        self.title = title; self.context = context; self.content = content()
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.medium) {
                OperationReviewText(key: title).font(.title2).accessibilityAddTraits(.isHeader)
                OperationReviewText(key: "Review only. Nothing is authorized or executed here.")
                OperationReviewField(label: "Snapshot revision", value: context.revision)
                OperationReviewField(label: "Freshness evidence", value: context.freshness)
                OperationReviewField(label: "Ownership evidence", value: context.ownership)
                OperationReviewField(label: "Outcome evidence", value: context.outcome)
                OperationReviewText(key: "Metadata is limited to 1024 UTF-8 bytes per field; original identity must be checked by the host.").font(.footnote)
                content
            }.padding().telemetrySurface()
        }.foregroundStyle(.white).background(TelemetryTheme.background)
    }
}

@MainActor
struct OperationReviewButton: View {
    let title: String
    let action: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { action?() } label: { OperationReviewText(key: title).frame(minHeight: 44) }
                .buttonStyle(.bordered).disabled(action == nil)
                .accessibilityHint(Text(verbatim: AppLocalization.text("Requests another review, not execution or confirmation.")))
            if action == nil { OperationReviewText(key: "Review host unavailable").font(.footnote) }
        }
    }
}
