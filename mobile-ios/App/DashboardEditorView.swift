import SwiftUI

struct DashboardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: TelemetryModel

    var body: some View {
        NavigationStack {
            List {
                if let page = model.dashboardProfile?.pages.first {
                    Section(page.name) {
                        ForEach(page.widgets) { widget in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(widget.configuration.label)
                                    Text(widget.signalID ?? "unbound")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Duplicate") {
                                    model.duplicateDashboardWidget(pageID: page.id, widgetID: widget.id)
                                }
                                .buttonStyle(.bordered)
                                Button("Delete", role: .destructive) {
                                    model.deleteDashboardWidget(pageID: page.id, widgetID: widget.id)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        Button("Snap to 8 px grid") {
                            model.snapDashboard(pageID: page.id)
                        }
                    }
                }
            }
            .navigationTitle("Dashboard Editor")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
