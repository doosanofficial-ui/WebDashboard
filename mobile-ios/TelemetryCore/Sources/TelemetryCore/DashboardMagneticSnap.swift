import Foundation

public struct DashboardSnapBounds: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ rect: DashboardRect) {
        self.init(x: Double(rect.x), y: Double(rect.y), width: Double(rect.width), height: Double(rect.height))
    }
}
public struct DashboardSnapGeometry: Equatable, Sendable {
    public let columnWidth: Double
    public let rowHeight: Double
    public let zoom: Double
    public let thresholdPoints: Double
    public init(columnWidth: Double, rowHeight: Double, zoom: Double = 1, thresholdPoints: Double = 8) {
        self.columnWidth = columnWidth; self.rowHeight = rowHeight
        self.zoom = zoom; self.thresholdPoints = thresholdPoints
    }
}
public enum DashboardSnapOperation: Sendable { case move, resize }
public struct DashboardSnapGuide: Equatable, Sendable {
    public enum Axis: Sendable { case x, y }
    public enum Kind: Int, Sendable { case edge, center, spacing, size }
    public enum Anchor: Sendable { case leading, center, trailing }
    public let axis: Axis
    public let kind: Kind
    public let position: Double
    public let anchor: Anchor
}
public struct DashboardSnapResult: Equatable, Sendable {
    public let bounds: DashboardSnapBounds
    public let rect: DashboardRect
    public let guides: [DashboardSnapGuide]
    public let overlappingWidgetIDs: Set<String>
}
public enum DashboardMagneticSnap {
    private struct Candidate {
        let value: Double
        let guide: DashboardSnapGuide
        let id: String
    }

    public static func preview(original: DashboardRect, proposed: DashboardSnapBounds,
                               neighbors: [DashboardWidgetDefinition], operation: DashboardSnapOperation,
                               geometry: DashboardSnapGeometry) -> DashboardSnapResult {
        let scales = [geometry.columnWidth * geometry.zoom, geometry.rowHeight * geometry.zoom]
        let inputs = [proposed.x, proposed.y, proposed.width, proposed.height]
        guard scales.allSatisfy({ $0.isFinite && $0 > 0 }), geometry.zoom > 0,
              geometry.thresholdPoints.isFinite, geometry.thresholdPoints >= 0,
              inputs.allSatisfy({ $0.isFinite && abs($0) < Double(Int.max / 4) }) else {
            return .init(bounds: .init(original), rect: original, guides: [], overlappingWidgetIDs: [])
        }
        var bounds: DashboardSnapBounds
        switch operation {
        case .move:
            bounds = .init(x: max(0, proposed.x), y: max(0, proposed.y),
                           width: Double(original.width), height: Double(original.height))
        case .resize:
            bounds = .init(x: Double(original.x), y: Double(original.y),
                           width: max(1, proposed.width), height: max(1, proposed.height))
        }
        let ordered = neighbors.sorted { $0.id < $1.id }
        var guides: [DashboardSnapGuide] = []
        for axis in [DashboardSnapGuide.Axis.x, .y] {
            let scale = axis == .x ? scales[0] : scales[1]
            let raw: Double
            var candidates: [Candidate] = []
            switch operation {
            case .move:
                raw = axis == .x ? bounds.x : bounds.y
                let extent = axis == .x ? bounds.width : bounds.height
                for neighbor in ordered {
                    let n = DashboardSnapBounds(neighbor.rect)
                    let start = axis == .x ? n.x : n.y
                    let size = axis == .x ? n.width : n.height
                    candidates += [
                        candidate(start, axis, .edge, start, .leading, neighbor.id),
                        candidate(start + size - extent, axis, .edge, start + size, .trailing, neighbor.id),
                        candidate(start + (size - extent) / 2, axis, .center, start + size / 2, .center, neighbor.id)
                    ]
                }
                candidates += spacingCandidates(bounds, ordered, axis)
            case .resize:
                raw = axis == .x ? bounds.width : bounds.height
                let start = axis == .x ? bounds.x : bounds.y
                for neighbor in ordered {
                    let n = DashboardSnapBounds(neighbor.rect)
                    let near = axis == .x ? n.x : n.y
                    let size = axis == .x ? n.width : n.height
                    candidates += [
                        candidate(size, axis, .size, start + size, .trailing, neighbor.id),
                        candidate(near + size - start, axis, .edge, near + size, .trailing, neighbor.id),
                        candidate(2 * (near + size / 2 - start), axis, .center, near + size / 2, .center, neighbor.id)
                    ]
                }
            }
            let minimum: Double = operation == .move ? 0 : 1
            if let best = select(candidates, raw: raw, scale: scale, minimum: minimum,
                                 threshold: geometry.thresholdPoints) {
                switch (operation, axis) {
                case (.move, .x): bounds.x = best.value
                case (.move, .y): bounds.y = best.value
                case (.resize, .x): bounds.width = best.value
                case (.resize, .y): bounds.height = best.value
                }
                guides.append(best.guide)
            }
        }
        let rect = DashboardRect(x: Int(bounds.x.rounded()), y: Int(bounds.y.rounded()),
                                 width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded()))
        let current = displayBounds(bounds, geometry)
        let overlaps = Set(ordered.filter {
            let other = displayBounds(.init($0.rect), geometry)
            return current.x < other.x + other.width && current.x + current.width > other.x
                && current.y < other.y + other.height && current.y + current.height > other.y
        }.map(\.id))
        return .init(bounds: bounds, rect: rect, guides: guides, overlappingWidgetIDs: overlaps)
    }

    private static func candidate(_ value: Double, _ axis: DashboardSnapGuide.Axis,
                                  _ kind: DashboardSnapGuide.Kind, _ position: Double,
                                  _ anchor: DashboardSnapGuide.Anchor, _ id: String) -> Candidate {
        .init(value: value, guide: .init(axis: axis, kind: kind, position: position, anchor: anchor), id: id)
    }

    private static func select(_ candidates: [Candidate], raw: Double, scale: Double,
                               minimum: Double, threshold: Double) -> Candidate? {
        candidates.filter {
            $0.value.isFinite && $0.value >= minimum && $0.value < Double(Int.max / 4)
                && abs($0.value - $0.value.rounded()) < 0.000000001
                && abs($0.value - raw) * scale <= threshold
        }.min {
            let a = abs($0.value - raw) * scale
            let b = abs($1.value - raw) * scale
            if abs(a - b) > 0.000000001 { return a < b }
            if $0.guide.kind != $1.guide.kind { return $0.guide.kind.rawValue < $1.guide.kind.rawValue }
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.value < $1.value
        }
    }

    private static func spacingCandidates(_ bounds: DashboardSnapBounds,
                                          _ neighbors: [DashboardWidgetDefinition],
                                          _ axis: DashboardSnapGuide.Axis) -> [Candidate] {
        let band = neighbors.filter {
            let n = DashboardSnapBounds($0.rect)
            return axis == .x
                ? bounds.y < n.y + n.height && bounds.y + bounds.height > n.y
                : bounds.x < n.x + n.width && bounds.x + bounds.width > n.x
        }.sorted {
            let a = axis == .x ? $0.rect.x : $0.rect.y
            let b = axis == .x ? $1.rect.x : $1.rect.y
            return a == b ? $0.id < $1.id : a < b
        }
        guard band.count > 1 else { return [] }
        let extent = axis == .x ? bounds.width : bounds.height
        var result: [Candidate] = []
        for index in 1..<band.count {
            let a = DashboardSnapBounds(band[index - 1].rect)
            let b = DashboardSnapBounds(band[index].rect)
            let aStart = axis == .x ? a.x : a.y
            let aEnd = aStart + (axis == .x ? a.width : a.height)
            let bStart = axis == .x ? b.x : b.y
            let bEnd = bStart + (axis == .x ? b.width : b.height)
            let gap = bStart - aEnd
            guard gap >= 0 else { continue }
            let id = band[index - 1].id + "/" + band[index].id
            var targets = [aStart - gap - extent, bEnd + gap]
            let middle = (aEnd + bStart - extent) / 2
            if middle >= aEnd && middle + extent <= bStart { targets.append(middle) }
            result += targets.map { candidate($0, axis, .spacing, $0, .leading, id) }
        }
        return result
    }

    private static func displayBounds(_ rect: DashboardSnapBounds,
                                      _ geometry: DashboardSnapGeometry) -> DashboardSnapBounds {
        // Same 8pt gutter and 36pt minimum card extent as the production grid.
        .init(x: (rect.x * geometry.columnWidth + 4) * geometry.zoom,
              y: (rect.y * geometry.rowHeight + 4) * geometry.zoom,
              width: max(36, rect.width * geometry.columnWidth - 8) * geometry.zoom,
              height: max(36, rect.height * geometry.rowHeight - 8) * geometry.zoom)
    }
}
