import Foundation

public enum DashboardModelError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidProfile
    case duplicatePageID(String)
    case duplicateWidgetID(String)
    case missingWidgetID(String)
    case missingPageID(String)
    case cannotDeleteLastPage
}

public enum DashboardOrientation: String, Codable, Equatable, Sendable {
    case portrait
    case landscape
}

public enum DashboardAlignment: String, CaseIterable, Equatable, Sendable {
    case left
    case centerHorizontal
    case right
    case top
    case centerVertical
    case bottom
}

public enum DashboardWidgetType: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case numericGauge
    case circularGauge
    case semiCircularGauge
    case horizontalBar
    case verticalBar
    case led
    case statusIcon
    case rawCANHex
    case bitView
    case timeSeries
    case gps
    case map
}

public enum DashboardConditionOperator: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case equals
    case greaterThan
    case lessThan
    case withinRange
    case bitSet
}

public struct DashboardCondition: Codable, Equatable, Sendable {
    public let op: DashboardConditionOperator
    public let threshold: Double?
    public let upperThreshold: Double?
    public let bit: Int?
    public let hysteresis: Double
    public let holdTime: Double
    public let staleIsActive: Bool

    public init(
        op: DashboardConditionOperator,
        threshold: Double?,
        upperThreshold: Double? = nil,
        bit: Int? = nil,
        hysteresis: Double = 0,
        holdTime: Double = 0,
        staleIsActive: Bool = false
    ) {
        self.op = op
        self.threshold = threshold
        self.upperThreshold = upperThreshold
        self.bit = bit.map { max(0, min($0, 63)) }
        self.hysteresis = hysteresis.isFinite ? max(0, hysteresis) : 0
        self.holdTime = holdTime.isFinite ? max(0, holdTime) : 0
        self.staleIsActive = staleIsActive
    }
}

/// Stateful evaluator for LED/status conditions. It never transmits CAN data.
public struct DashboardConditionRuntime: Equatable, Sendable {
    public private(set) var isActive = false
    private var candidateSince: Double?

    public init() {}

    @discardableResult
    public mutating func update(
        condition: DashboardCondition,
        value: Double?,
        rawValue: UInt64?,
        stale: Bool,
        now: Double
    ) -> Bool {
        guard now.isFinite else { return isActive }
        if stale {
            candidateSince = nil
            isActive = condition.staleIsActive
            return isActive
        }
        guard let value, value.isFinite else {
            candidateSince = nil
            isActive = false
            return false
        }
        let candidate = matches(condition: condition, value: value, rawValue: rawValue)
        guard candidate else {
            candidateSince = nil
            isActive = false
            return false
        }
        guard !isActive else { return true }
        guard condition.holdTime > 0 else {
            isActive = true
            return true
        }
        if candidateSince == nil { candidateSince = now }
        if let candidateSince, now - candidateSince >= condition.holdTime {
            isActive = true
        }
        return isActive
    }

    private func matches(condition: DashboardCondition, value: Double, rawValue: UInt64?) -> Bool {
        switch condition.op {
        case .equals:
            guard let threshold = condition.threshold else { return false }
            return abs(value - threshold) <= max(condition.hysteresis, 0.000_001)
        case .greaterThan:
            guard let threshold = condition.threshold else { return false }
            return value > threshold - (isActive ? condition.hysteresis : 0)
        case .lessThan:
            guard let threshold = condition.threshold else { return false }
            return value < threshold + (isActive ? condition.hysteresis : 0)
        case .withinRange:
            guard let lower = condition.threshold, let upper = condition.upperThreshold else { return false }
            let margin = isActive ? condition.hysteresis : 0
            return value >= lower - margin && value <= upper + margin
        case .bitSet:
            guard let bit = condition.bit, let rawValue else { return false }
            return rawValue & (UInt64(1) << UInt64(bit)) != 0
        }
    }
}

public struct DashboardRect: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = max(0, x)
        self.y = max(0, y)
        self.width = max(1, width)
        self.height = max(1, height)
    }

    func snapped(to grid: Int) -> DashboardRect {
        guard grid > 0 else { return self }
        func snap(_ value: Int) -> Int {
            Int((Double(value) / Double(grid)).rounded()) * grid
        }
        return DashboardRect(x: snap(x), y: snap(y), width: snap(width), height: snap(height))
    }
}

public struct DashboardWidgetConfiguration: Codable, Equatable, Sendable {
    public let label: String
    public let unit: String
    public let decimals: Int
    public let minimum: Double?
    public let maximum: Double?
    public let warningThreshold: Double?
    public let criticalThreshold: Double?
    public let condition: DashboardCondition?

    public init(
        label: String,
        unit: String,
        decimals: Int,
        minimum: Double?,
        maximum: Double?,
        warningThreshold: Double?,
        criticalThreshold: Double?,
        condition: DashboardCondition? = nil
    ) {
        self.label = label
        self.unit = unit
        self.decimals = max(0, min(decimals, 6))
        self.minimum = minimum
        self.maximum = maximum
        self.warningThreshold = warningThreshold
        self.criticalThreshold = criticalThreshold
        self.condition = condition
    }
}

public struct DashboardWidgetDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let type: DashboardWidgetType
    public var signalID: String?
    public var rect: DashboardRect
    public var zIndex: Int
    public var configuration: DashboardWidgetConfiguration

    public init(
        id: String,
        type: DashboardWidgetType,
        signalID: String?,
        rect: DashboardRect,
        zIndex: Int,
        configuration: DashboardWidgetConfiguration
    ) {
        self.id = id
        self.type = type
        self.signalID = signalID
        self.rect = rect
        self.zIndex = zIndex
        self.configuration = configuration
    }
}

public struct DashboardPage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let orientation: DashboardOrientation
    public private(set) var widgets: [DashboardWidgetDefinition]

    public init(id: String, name: String, orientation: DashboardOrientation,
                widgets: [DashboardWidgetDefinition]) {
        self.id = id
        self.name = name
        self.orientation = orientation
        self.widgets = widgets
    }

    public mutating func duplicateWidget(id: String, newID: String) throws {
        guard !widgets.contains(where: { $0.id == newID }) else {
            throw DashboardModelError.duplicateWidgetID(newID)
        }
        guard let original = widgets.first(where: { $0.id == id }) else {
            throw DashboardModelError.missingWidgetID(id)
        }
        var copy = original
        copy = DashboardWidgetDefinition(
            id: newID,
            type: copy.type,
            signalID: copy.signalID,
            rect: DashboardRect(x: copy.rect.x + 8, y: copy.rect.y + 8,
                                width: copy.rect.width, height: copy.rect.height),
            zIndex: copy.zIndex + 1,
            configuration: copy.configuration
        )
        widgets.append(copy)
    }

    public mutating func addWidget(_ widget: DashboardWidgetDefinition) throws {
        guard !widgets.contains(where: { $0.id == widget.id }) else {
            throw DashboardModelError.duplicateWidgetID(widget.id)
        }
        widgets.append(widget)
    }

    public mutating func updateWidgetRect(id: String, rect: DashboardRect) throws {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else {
            throw DashboardModelError.missingWidgetID(id)
        }
        widgets[index].rect = rect
    }

    public mutating func alignWidget(id: String, alignment: DashboardAlignment, columns: Int) throws {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else {
            throw DashboardModelError.missingWidgetID(id)
        }
        let widget = widgets[index]
        let canvasColumns = max(columns, widget.rect.width)
        let maxRow = widgets.map { $0.rect.y + $0.rect.height }.max() ?? widget.rect.height
        let newRect: DashboardRect
        switch alignment {
        case .left:
            newRect = DashboardRect(x: 0, y: widget.rect.y, width: widget.rect.width, height: widget.rect.height)
        case .centerHorizontal:
            newRect = DashboardRect(x: (canvasColumns - widget.rect.width) / 2, y: widget.rect.y,
                                    width: widget.rect.width, height: widget.rect.height)
        case .right:
            newRect = DashboardRect(x: canvasColumns - widget.rect.width, y: widget.rect.y,
                                    width: widget.rect.width, height: widget.rect.height)
        case .top:
            newRect = DashboardRect(x: widget.rect.x, y: 0, width: widget.rect.width, height: widget.rect.height)
        case .centerVertical:
            newRect = DashboardRect(x: widget.rect.x, y: max(0, (maxRow - widget.rect.height) / 2),
                                    width: widget.rect.width, height: widget.rect.height)
        case .bottom:
            newRect = DashboardRect(x: widget.rect.x, y: max(0, maxRow - widget.rect.height),
                                    width: widget.rect.width, height: widget.rect.height)
        }
        widgets[index].rect = newRect
    }

    public mutating func updateWidgetBinding(
        id: String,
        signalID: String?,
        configuration: DashboardWidgetConfiguration
    ) throws {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else {
            throw DashboardModelError.missingWidgetID(id)
        }
        widgets[index].signalID = signalID
        widgets[index].configuration = configuration
    }

    public mutating func bringWidgetToFront(id: String) throws {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else {
            throw DashboardModelError.missingWidgetID(id)
        }
        let top = widgets.map(\.zIndex).max() ?? 0
        widgets[index].zIndex = top + 1
    }

    public mutating func setWidgetLayout(id: String, rect: DashboardRect, zIndex: Int) throws {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else {
            throw DashboardModelError.missingWidgetID(id)
        }
        widgets[index].rect = rect
        widgets[index].zIndex = zIndex
    }

    @discardableResult
    public mutating func deleteWidget(id: String) -> Bool {
        let oldCount = widgets.count
        widgets.removeAll { $0.id == id }
        return widgets.count != oldCount
    }

    public mutating func snapToGrid(_ grid: Int) {
        guard grid > 0 else { return }
        widgets = widgets.map { widget in
            var snapped = widget
            snapped.rect = widget.rect.snapped(to: grid)
            return snapped
        }
    }
}

public struct DashboardProfile: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public private(set) var pages: [DashboardPage]

    public init(id: String, name: String, pages: [DashboardPage]) throws {
        guard !id.isEmpty, !name.isEmpty, !pages.isEmpty else {
            throw DashboardModelError.invalidProfile
        }
        var pageIDs = Set<String>()
        for page in pages {
            guard pageIDs.insert(page.id).inserted else {
                throw DashboardModelError.duplicatePageID(page.id)
            }
            var widgetIDs = Set<String>()
            for widget in page.widgets {
                guard widgetIDs.insert(widget.id).inserted else {
                    throw DashboardModelError.duplicateWidgetID(widget.id)
                }
            }
        }
        schemaVersion = 1
        self.id = id
        self.name = name
        self.pages = pages
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id, name, pages
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw DashboardModelError.unsupportedSchemaVersion(version) }
        try self.init(
            id: values.decode(String.self, forKey: .id),
            name: values.decode(String.self, forKey: .name),
            pages: values.decode([DashboardPage].self, forKey: .pages)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(pages, forKey: .pages)
    }

    public mutating func addWidget(_ widget: DashboardWidgetDefinition, toPage pageID: String) throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw DashboardModelError.invalidProfile
        }
        try pages[index].addWidget(widget)
    }

    public mutating func addPage(_ page: DashboardPage) throws {
        guard !pages.contains(where: { $0.id == page.id }) else {
            throw DashboardModelError.duplicatePageID(page.id)
        }
        pages.append(page)
    }

    @discardableResult
    public mutating func deletePage(id: String) throws -> Bool {
        guard pages.contains(where: { $0.id == id }) else {
            throw DashboardModelError.missingPageID(id)
        }
        guard pages.count > 1 else { throw DashboardModelError.cannotDeleteLastPage }
        pages.removeAll { $0.id == id }
        return true
    }

    public mutating func setPageOrientation(pageID: String, orientation: DashboardOrientation) throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw DashboardModelError.missingPageID(pageID)
        }
        let page = pages[index]
        pages[index] = DashboardPage(id: page.id, name: page.name, orientation: orientation,
                                     widgets: page.widgets)
    }

    public mutating func updateWidgetRect(pageID: String, widgetID: String, rect: DashboardRect) throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw DashboardModelError.missingPageID(pageID)
        }
        try pages[index].updateWidgetRect(id: widgetID, rect: rect)
    }

    public mutating func alignWidget(
        pageID: String,
        widgetID: String,
        alignment: DashboardAlignment,
        columns: Int
    ) throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw DashboardModelError.missingPageID(pageID)
        }
        try pages[index].alignWidget(id: widgetID, alignment: alignment, columns: columns)
    }

    public mutating func updateWidgetBinding(
        pageID: String,
        widgetID: String,
        signalID: String?,
        configuration: DashboardWidgetConfiguration
    ) throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw DashboardModelError.missingPageID(pageID)
        }
        try pages[index].updateWidgetBinding(
            id: widgetID,
            signalID: signalID,
            configuration: configuration
        )
    }

    public mutating func bringWidgetToFront(pageID: String, widgetID: String) throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw DashboardModelError.missingPageID(pageID)
        }
        try pages[index].bringWidgetToFront(id: widgetID)
    }

    public mutating func duplicateWidget(pageID: String, widgetID: String, newID: String) throws {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            throw DashboardModelError.invalidProfile
        }
        try pages[index].duplicateWidget(id: widgetID, newID: newID)
    }

    @discardableResult
    public mutating func deleteWidget(pageID: String, widgetID: String) -> Bool {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return false }
        return pages[index].deleteWidget(id: widgetID)
    }

    public mutating func snapToGrid(pageID: String, grid: Int) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].snapToGrid(grid)
    }

    /// Migrates the original MVP default, where every built-in widget shared one rect.
    /// Custom overlapping layouts are left untouched because they may be intentional.
    @discardableResult
    public mutating func migrateLegacyDefaultGrid() -> Bool {
        var changed = false
        let legacyWidgetIDs: Set<String> = ["ws-fl", "ws-fr", "ws-rl", "ws-rr", "yaw", "ay"]
        for pageIndex in pages.indices {
            let widgets = pages[pageIndex].widgets
            let defaultRect = DashboardRect(x: 0, y: 0, width: 2, height: 1)
            let legacyWidgets = widgets.filter {
                legacyWidgetIDs.contains($0.id) && $0.rect == defaultRect
            }
            guard legacyWidgets.count > 1 else { continue }
            var page = pages[pageIndex]
            for (widgetIndex, widget) in legacyWidgets.enumerated() {
                let rect = DashboardRect(x: (widgetIndex % 3) * 2,
                                         y: (widgetIndex / 3) * 1,
                                         width: 2, height: 1)
                try? page.setWidgetLayout(id: widget.id, rect: rect, zIndex: widgetIndex)
            }
            pages[pageIndex] = page
            changed = true
        }
        return changed
    }
}
