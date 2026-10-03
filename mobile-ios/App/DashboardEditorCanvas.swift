import SwiftUI
import TelemetryCore

struct DashboardEditorCanvas: View {
    @Bindable var model: TelemetryModel
    let page: DashboardPage
    @Binding var selectedWidgetID: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewport = DashboardEditorViewport()
    @State private var draft: DashboardEditDraft?
    @GestureState private var moving = false
    @GestureState private var resizing = false

    private var columns: Int { page.orientation == .portrait ? 4 : 6 }
    private var rows: Int { max(4, (page.widgets.map { $0.rect.y + $0.rect.height }.max() ?? 4) + 1) }
    private var geometry: DashboardSnapGeometry { viewport.geometry(columns: columns, rows: rows) }
    private var status: String {
        guard let draft, !draft.isCancelled else {
            return dynamicTypeSize.isAccessibilitySize ? "Use card actions to move or resize. Undo restores the last edit." : "Drag a card or its corner. Changes save when released."
        }
        if !draft.result.overlappingWidgetIDs.isEmpty { return "Overlap with \(draft.result.overlappingWidgetIDs.count) card(s) · neighbors stay in place" }
        return draft.result.guides.isEmpty ? "Release to save · Undo restores this card" : "Aligned · release to save · Undo restores this card"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(status).font(.caption).foregroundStyle(draft?.result.overlappingWidgetIDs.isEmpty == false ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dashboard-edit-preview-status")
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    ForEach(page.widgets.sorted { $0.zIndex < $1.zIndex }) { widget in
                        card(widget).fixedSize(horizontal: false, vertical: true)
                        Menu("Move or resize \(widget.configuration.label)") {
                            Button("Move right") { step(widget, dx: 1) }
                            Button("Move left") { step(widget, dx: -1) }
                            Button("Move down") { step(widget, dy: 1) }
                            Button("Move up") { step(widget, dy: -1) }
                            Button("Wider") { step(widget, dw: 1) }
                            Button("Narrower") { step(widget, dw: -1) }
                            Button("Taller") { step(widget, dh: 1) }
                            Button("Shorter") { step(widget, dh: -1) }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("dashboard-widget-actions-\(widget.id)")
                    }
                }
            } else {
            DashboardGridLayout(columns: columns, rows: rows, frozenRowHeight: draft.flatMap { $0.isCancelled ? nil : CGFloat($0.geometry.rowHeight) }) {
                ForEach(page.widgets.sorted { $0.zIndex < $1.zIndex }) { widget in
                    card(widget)
                        // Selection lifts only the active card for reachable handles;
                        // stored zIndex and every neighbor remain unchanged.
                        .zIndex(selectedWidgetID == widget.id ? Double(page.widgets.map(\.zIndex).max() ?? 0) + 1 : Double(widget.zIndex))
                        .layoutValue(key: DashboardGridRectKey.self, value: widget.rect)
                        .layoutValue(key: DashboardGridPreviewKey.self,
                                     value: draft?.widget.id == widget.id ? draft?.result.bounds : nil)
                }
            }
            .background(TelemetryTheme.plot, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                if let draft, !draft.isCancelled {
                    DashboardSnapOverlay(result: draft.result, geometry: draft.geometry)
                }
            }
            .coordinateSpace(name: "dashboard-editor-grid")
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                viewport.observe(size, draft: &draft)
            }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard-editor-canvas-\(page.id)")
        .onChange(of: page) { _, _ in draft?.cancel() }
        .onChange(of: model.dashboardProfile?.id) { _, _ in draft?.cancel() }
        .onChange(of: dynamicTypeSize) { _, _ in draft?.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { draft?.cancel() } }
        .onChange(of: moving || resizing) { _, active in if !active { draft = nil } }
        .onDisappear { draft = nil }
    }
    private func card(_ widget: DashboardWidgetDefinition) -> some View {
        LiveCockpitView(model: model, editorPresented: .constant(false), selectedPageID: .constant(page.id))
            .dashboardWidget(widget, now: model.replayTimestamp.map(Date.init(timeIntervalSince1970:)) ?? .now,
                             allowsMapTiles: false)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(draft?.result.overlappingWidgetIDs.contains(widget.id) == true ? .orange :
                                (selectedWidgetID == widget.id ? .cyan : .clear), lineWidth: 3)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedWidgetID = widget.id }
            .gesture(gesture(widget, operation: .move), including: dynamicTypeSize.isAccessibilitySize ? .none : .all)
            .overlay(alignment: .bottomTrailing) {
                if selectedWidgetID == widget.id && !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(.cyan, in: Circle()).contentShape(Rectangle())
                        .highPriorityGesture(gesture(widget, operation: .resize))
                        .accessibilityLabel("Resize \(widget.configuration.label)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("resize-dashboard-widget-\(widget.id)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(widget.configuration.label)
            .accessibilityValue("Position \(widget.rect.x), \(widget.rect.y); size \(widget.rect.width) by \(widget.rect.height)")
            .accessibilityIdentifier("editor-widget-\(widget.id)")
            .accessibilityAction(named: "Move right") { step(widget, dx: 1, dy: 0) }
            .accessibilityAction(named: "Move left") { step(widget, dx: -1, dy: 0) }
            .accessibilityAction(named: "Move down") { step(widget, dx: 0, dy: 1) }
            .accessibilityAction(named: "Move up") { step(widget, dx: 0, dy: -1) }
            .accessibilityAction(named: "Wider") { step(widget, dw: 1) }
            .accessibilityAction(named: "Narrower") { step(widget, dw: -1) }
            .accessibilityAction(named: "Taller") { step(widget, dh: 1) }
            .accessibilityAction(named: "Shorter") { step(widget, dh: -1) }
    }
    private func gesture(_ widget: DashboardWidgetDefinition, operation: DashboardSnapOperation) -> some Gesture {
        DragGesture(minimumDistance: operation == .move ? 4 : 2, coordinateSpace: .named("dashboard-editor-grid"))
            .updating(operation == .move ? $moving : $resizing) { _, state, _ in state = true }
            .onChanged { value in update(widget, operation: operation, translation: value.translation) }
            .onEnded { value in
                guard draft?.widget.id == widget.id, draft?.operation == operation else { return }
                update(widget, operation: operation, translation: value.translation)
                guard let final = draft, let rect = final.releaseRect else { draft = nil; return }
                draft = nil
                model.commitDashboardWidgetEdit(profileID: final.profileID, page: final.page,
                                                widgetID: final.widget.id, rect: rect)
            }
    }
    private func update(_ widget: DashboardWidgetDefinition, operation: DashboardSnapOperation, translation: CGSize) {
        if draft == nil {
            guard let profile = model.dashboardProfile, geometry.columnWidth > 0, geometry.rowHeight > 0 else { return }
            draft = DashboardEditDraft(profileID: profile.id, page: page, widgetID: widget.id,
                                       operation: operation, geometry: geometry)
            selectedWidgetID = widget.id
        }
        guard var current = draft, current.widget.id == widget.id, current.operation == operation else { return }
        current.update(translationX: Double(translation.width), translationY: Double(translation.height))
        draft = current
    }
    private func step(_ widget: DashboardWidgetDefinition, dx: Int = 0, dy: Int = 0, dw: Int = 0, dh: Int = 0) {
        guard let profile = model.dashboardProfile else { return }
        model.commitDashboardWidgetEdit(profileID: profile.id, page: page, widgetID: widget.id,
            rect: .init(x: widget.rect.x + dx, y: widget.rect.y + dy,
                        width: widget.rect.width + dw, height: widget.rect.height + dh))
    }
}

/// Guides share the grid's card-edge gutter; orange outlines identify overlap.
struct DashboardSnapOverlay: View {
    let result: DashboardSnapResult
    let geometry: DashboardSnapGeometry
    var body: some View {
        Canvas { context, size in
            for guide in result.guides {
                let gutter: Double = guide.anchor == .leading ? 4 : guide.anchor == .trailing ? -4 : 0
                let scale = guide.axis == .x ? geometry.columnWidth : geometry.rowHeight
                let position = CGFloat(guide.position * scale + gutter)
                var line = Path()
                if guide.axis == .x { line.move(to: .init(x: position, y: 0)); line.addLine(to: .init(x: position, y: size.height)) }
                else { line.move(to: .init(x: 0, y: position)); line.addLine(to: .init(x: size.width, y: position)) }
                context.stroke(line, with: .color(.cyan), style: .init(lineWidth: 2, dash: guide.kind == .spacing ? [4, 4] : []))
            }
            let b = result.bounds
            let rect = CGRect(x: b.x * geometry.columnWidth + 4, y: b.y * geometry.rowHeight + 4,
                              width: max(36, b.width * geometry.columnWidth - 8), height: max(36, b.height * geometry.rowHeight - 8))
            context.stroke(Path(roundedRect: rect, cornerRadius: 14),
                with: .color(result.overlappingWidgetIDs.isEmpty ? .cyan : .orange), lineWidth: 3)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
