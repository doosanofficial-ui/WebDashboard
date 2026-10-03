import SwiftUI

/// Keeps the plot and its result visible; provenance is available on demand.
struct RecordedHistoryCard<Plot: View, Summary: View, Details: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingDetails = false
    let title: String
    let plot: Plot
    let summary: Summary
    let details: Details

    init(title: String, @ViewBuilder plot: () -> Plot,
         @ViewBuilder summary: () -> Summary, @ViewBuilder details: () -> Details) {
        self.title = title; self.plot = plot(); self.summary = summary(); self.details = details()
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    plot.frame(height: 180)
                    summary.fixedSize(horizontal: false, vertical: true)
                    details.font(.caption2).foregroundStyle(TelemetryTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
            } else {
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: 4) {
                        header
                        plot.frame(minHeight: 24, maxHeight: .infinity)
                        summary.fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: max(0, geometry.size.width - 24), height: max(0, geometry.size.height - 24))
                    .telemetrySurface(.standard, padding: TelemetryTheme.Spacing.small)
                }
            }
        }
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView {
                    details.frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDetails = false } } }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !dynamicTypeSize.isAccessibilitySize {
            Button { showingDetails = true } label: {
                Image(systemName: "info.circle").font(.body).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Recorded history details")
            }
        }
    }
}
