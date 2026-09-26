import Foundation

public enum DashboardModelError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidProfile
    case duplicatePageID(String)
    case duplicateWidgetID(String)
    case missingWidgetID(String)
}

public enum DashboardOrientation: String, Codable, Equatable, Sendable {
    case portrait
    case landscape
}

public enum DashboardWidgetType: String, Codable, Equatable, Sendable {
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

public struct DashboardRect: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
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

    public init(
        label: String,
        unit: String,
        decimals: Int,
        minimum: Double?,
        maximum: Double?,
        warningThreshold: Double?,
        criticalThreshold: Double?
    ) {
        self.label = label
        self.unit = unit
        self.decimals = max(0, min(decimals, 6))
        self.minimum = minimum
        self.maximum = maximum
        self.warningThreshold = warningThreshold
        self.criticalThreshold = criticalThreshold
    }
}

public struct DashboardWidgetDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let type: DashboardWidgetType
    public let signalID: String?
    public var rect: DashboardRect
    public var zIndex: Int
    public let configuration: DashboardWidgetConfiguration

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
    public let pages: [DashboardPage]

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
}
