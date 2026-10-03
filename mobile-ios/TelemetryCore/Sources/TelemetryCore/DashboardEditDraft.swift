import Foundation

/// A gesture owns immutable page/geometry snapshots and never writes a profile.
public struct DashboardEditDraft: Equatable, Sendable {
    public let profileID: String
    public let page: DashboardPage
    public let widget: DashboardWidgetDefinition
    public let operation: DashboardSnapOperation
    public let geometry: DashboardSnapGeometry
    public private(set) var result: DashboardSnapResult
    public private(set) var isCancelled = false
    public var releaseRect: DashboardRect? { isCancelled ? nil : result.rect }

    public init?(profileID: String, page: DashboardPage, widgetID: String,
                 operation: DashboardSnapOperation, geometry: DashboardSnapGeometry) {
        guard let widget = page.widgets.first(where: { $0.id == widgetID }),
              [geometry.columnWidth, geometry.rowHeight, geometry.zoom].allSatisfy({ $0.isFinite && $0 > 0 }),
              geometry.thresholdPoints.isFinite, geometry.thresholdPoints >= 0 else { return nil }
        self.profileID = profileID; self.page = page; self.widget = widget
        self.operation = operation; self.geometry = geometry
        result = .init(bounds: .init(widget.rect), rect: widget.rect, guides: [], overlappingWidgetIDs: [])
    }
    public mutating func update(translationX: Double, translationY: Double) {
        guard !isCancelled else { return }
        guard translationX.isFinite, translationY.isFinite else { cancel(); return }
        var proposed = DashboardSnapBounds(widget.rect)
        let dx = translationX / (geometry.columnWidth * geometry.zoom)
        let dy = translationY / (geometry.rowHeight * geometry.zoom)
        if operation == .move { proposed.x += dx; proposed.y += dy }
        else { proposed.width += dx; proposed.height += dy }
        result = DashboardMagneticSnap.preview(original: widget.rect, proposed: proposed,
            neighbors: page.widgets.filter { $0.id != widget.id }, operation: operation, geometry: geometry)
    }
    public mutating func cancel() {
        isCancelled = true
        result = .init(bounds: .init(widget.rect), rect: widget.rect, guides: [], overlappingWidgetIDs: [])
    }
}
