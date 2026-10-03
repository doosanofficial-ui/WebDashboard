import SwiftUI
import TelemetryCore

struct DashboardGridRectKey: LayoutValueKey {
    static let defaultValue = DashboardRect(x: 0, y: 0, width: 1, height: 1)
}

struct DashboardGridPreviewKey: LayoutValueKey {
    static let defaultValue: DashboardSnapBounds? = nil
}

/// Keeps saved grid coordinates intact while letting a row grow to fit its cards.
struct DashboardGridLayout: Layout {
    let columns: Int
    let rows: Int
    var frozenRowHeight: CGFloat? = nil
    private let gap: CGFloat = 8

    private func metrics(width: CGFloat?, subviews: Subviews) -> (width: CGFloat, cell: CGFloat, row: CGFloat) {
        // SwiftUI may probe with an infinite proposal. Return a finite ideal
        // width instead of allowing infinity * zero in placement coordinates.
        let offeredWidth = width.flatMap { $0.isFinite ? $0 : nil }
        let width = max(1, offeredWidth ?? subviews.compactMap { view -> CGFloat? in
            let ideal = view.sizeThatFits(.unspecified).width
            let candidate = ideal * CGFloat(columns) / CGFloat(view[DashboardGridRectKey.self].width)
            return candidate.isFinite ? candidate : nil
        }.max() ?? 0)
        let cell = width / CGFloat(columns)
        if let frozenRowHeight, frozenRowHeight.isFinite, frozenRowHeight > 0 {
            return (width, cell, frozenRowHeight)
        }
        var row = cell
        for view in subviews {
            let rect = view[DashboardGridRectKey.self]
            let cardWidth = max(36, cell * CGFloat(rect.width) - gap)
            let needed = view.sizeThatFits(.init(width: cardWidth, height: nil)).height
            if needed.isFinite {
                row = max(row, (max(36, needed) + gap) / CGFloat(rect.height))
            }
        }
        return (width, cell, row)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let grid = metrics(width: proposal.width, subviews: subviews)
        return CGSize(width: grid.width, height: grid.row * CGFloat(rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = metrics(width: bounds.width, subviews: subviews)
        for view in subviews {
            let rect = view[DashboardGridPreviewKey.self] ?? DashboardSnapBounds(view[DashboardGridRectKey.self])
            view.place(at: CGPoint(x: bounds.minX + grid.cell * CGFloat(rect.x) + gap / 2,
                                   y: bounds.minY + grid.row * CGFloat(rect.y) + gap / 2),
                       anchor: .topLeading,
                       proposal: .init(width: max(36, grid.cell * CGFloat(rect.width) - gap),
                                       height: max(36, grid.row * CGFloat(rect.height) - gap)))
        }
    }
}
