import SwiftUI
import TelemetryCore

struct DashboardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: TelemetryModel
    @State private var selectedPageID: String?
    @State private var selectedWidgetID: String?

    private var selectedPage: DashboardPage? {
        guard let profile = model.dashboardProfile else { return nil }
        return profile.pages.first { $0.id == (selectedPageID ?? profile.pages.first?.id) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let profile = model.dashboardProfile, let page = selectedPage {
                    pageControls(profile: profile, page: page)
                    ScrollView {
                        DashboardEditorCanvas(model: model, page: page,
                                               selectedWidgetID: $selectedWidgetID)
                            .padding(.horizontal)
                    }
                    selectionControls(page: page)
                } else {
                    ContentUnavailableView("No dashboard profile", systemImage: "rectangle.3.group")
                }
            }
            .navigationTitle("Dashboard Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if selectedPageID == nil { selectedPageID = model.dashboardProfile?.pages.first?.id }
            }
        }
    }

    private func pageControls(profile: DashboardProfile, page: DashboardPage) -> some View {
        VStack(spacing: 8) {
            Picker("Page", selection: Binding(
                get: { selectedPageID ?? profile.pages.first?.id ?? page.id },
                set: { selectedPageID = $0 }
            )) {
                ForEach(profile.pages) { page in
                    Text(page.name).tag(page.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("dashboard-page-picker")

            HStack {
                Button("Add page", action: model.addDashboardPage)
                    .accessibilityIdentifier("add-dashboard-page")
                Menu("Add widget", systemImage: "plus.square") {
                    ForEach(DashboardWidgetType.allCases, id: \.self) { type in
                        Button(widgetLabel(type)) {
                            model.addDashboardWidget(pageID: page.id, type: type)
                        }
                    }
                }
                .accessibilityIdentifier("add-dashboard-widget")
                Menu("Orientation") {
                    Button("Portrait") {
                        model.setDashboardOrientation(pageID: page.id, orientation: .portrait)
                    }
                    Button("Landscape") {
                        model.setDashboardOrientation(pageID: page.id, orientation: .landscape)
                    }
                }
                Button("Snap") { model.snapDashboard(pageID: page.id) }
                Button("Delete page", role: .destructive) {
                    model.deleteDashboardPage(pageID: page.id)
                    selectedPageID = model.dashboardProfile?.pages.first?.id
                    selectedWidgetID = nil
                }
                .disabled(profile.pages.count == 1)
            }
            .buttonStyle(.bordered)
            Text("\(page.orientation.rawValue.capitalized) · drag widgets, use the corner handle to resize")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private func widgetLabel(_ type: DashboardWidgetType) -> String {
        switch type {
        case .numericGauge: return "Numeric Gauge"
        case .circularGauge: return "Circular Gauge"
        case .semiCircularGauge: return "Semi Gauge"
        case .horizontalBar: return "Horizontal Bar"
        case .verticalBar: return "Vertical Bar"
        case .led: return "LED Indicator"
        case .statusIcon: return "Status"
        case .rawCANHex: return "Raw CAN"
        case .bitView: return "Bit View"
        case .timeSeries: return "Time Series"
        case .gps: return "GPS Info"
        case .map: return "Route Track"
        }
    }

    private func selectionControls(page: DashboardPage) -> some View {
        Group {
            if let selectedWidgetID,
               let widget = page.widgets.first(where: { $0.id == selectedWidgetID }) {
                HStack {
                    Text(widget.configuration.label).font(.caption.weight(.semibold))
                    Spacer()
                    Button("Front") {
                        model.bringDashboardWidgetToFront(pageID: page.id, widgetID: widget.id)
                    }
                    Button("Duplicate") {
                        model.duplicateDashboardWidget(pageID: page.id, widgetID: widget.id)
                    }
                    Button("Delete", role: .destructive) {
                        model.deleteDashboardWidget(pageID: page.id, widgetID: widget.id)
                        self.selectedWidgetID = nil
                    }
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
        }
    }
}

private struct DashboardEditorCanvas: View {
    @Bindable var model: TelemetryModel
    let page: DashboardPage
    @Binding var selectedWidgetID: String?

    private var columns: Int { page.orientation == .portrait ? 4 : 6 }
    private var maxRow: Int {
        max(4, (page.widgets.map { $0.rect.y + $0.rect.height }.max() ?? 4) + 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let cell = max(42, proxy.size.width / CGFloat(columns))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(.secondarySystemGroupedBackground))
                ForEach(page.widgets.sorted { $0.zIndex < $1.zIndex }) { widget in
                    editorWidget(widget)
                        .frame(width: max(42, cell * CGFloat(widget.rect.width) - 8),
                               height: max(42, cell * CGFloat(widget.rect.height) - 8))
                        .position(
                            x: cell * (CGFloat(widget.rect.x) + CGFloat(widget.rect.width) / 2),
                            y: cell * (CGFloat(widget.rect.y) + CGFloat(widget.rect.height) / 2)
                        )
                        .overlay(alignment: .bottomTrailing) {
                            resizeHandle(widget: widget, cell: cell)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(selectedWidgetID == widget.id ? Color.cyan : .clear,
                                        lineWidth: 3)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedWidgetID = widget.id }
                        .gesture(moveGesture(widget: widget, cell: cell))
                }
            }
            .frame(height: cell * CGFloat(maxRow), alignment: .top)
        }
        .frame(height: page.orientation == .portrait ? 520 : 360)
        .accessibilityIdentifier("dashboard-editor-canvas-\(page.id)")
    }

    private func editorWidget(_ widget: DashboardWidgetDefinition) -> some View {
        let value = widget.signalID.flatMap { model.frame?.sig[$0] }
        return VStack(alignment: .leading, spacing: 4) {
            Text(widget.configuration.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.map { String(format: "%.*f", widget.configuration.decimals, $0) } ?? "-")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
            Text(widget.configuration.unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("editor-widget-\(widget.id)")
    }

    private func moveGesture(widget: DashboardWidgetDefinition, cell: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onEnded { value in
                let dx = Int((value.translation.width / cell).rounded())
                let dy = Int((value.translation.height / cell).rounded())
                guard dx != 0 || dy != 0 else { return }
                model.updateDashboardWidgetRect(
                    pageID: page.id,
                    widgetID: widget.id,
                    rect: DashboardRect(x: widget.rect.x + dx, y: widget.rect.y + dy,
                                        width: widget.rect.width, height: widget.rect.height)
                )
                selectedWidgetID = widget.id
            }
    }

    private func resizeHandle(widget: DashboardWidgetDefinition, cell: CGFloat) -> some View {
        Circle()
            .fill(Color.cyan)
            .frame(width: 16, height: 16)
            .padding(4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2).onEnded { value in
                let dw = Int((value.translation.width / cell).rounded())
                let dh = Int((value.translation.height / cell).rounded())
                guard dw != 0 || dh != 0 else { return }
                model.updateDashboardWidgetRect(
                    pageID: page.id,
                    widgetID: widget.id,
                    rect: DashboardRect(x: widget.rect.x, y: widget.rect.y,
                                        width: widget.rect.width + dw,
                                        height: widget.rect.height + dh)
                )
                selectedWidgetID = widget.id
            })
    }
}
