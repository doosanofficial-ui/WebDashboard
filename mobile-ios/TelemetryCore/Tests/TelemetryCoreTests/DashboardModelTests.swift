import Foundation
import XCTest
@testable import TelemetryCore

final class DashboardModelTests: XCTestCase {
    private func widget(id: String = "speed") -> DashboardWidgetDefinition {
        DashboardWidgetDefinition(
            id: id,
            type: .numericGauge,
            signalID: "vehicle.speed",
            rect: DashboardRect(x: 13, y: 17, width: 147, height: 63),
            zIndex: 1,
            configuration: DashboardWidgetConfiguration(
                label: "Speed", unit: "km/h", decimals: 1,
                minimum: 0, maximum: 240, warningThreshold: 180, criticalThreshold: 220
            )
        )
    }

    private func profile() throws -> DashboardProfile {
        try DashboardProfile(
            id: "vehicle-a-normal",
            name: "Vehicle A Normal",
            pages: [DashboardPage(id: "main", name: "Main", orientation: .landscape, widgets: [widget()])]
        )
    }

    func testVersionedProfileAndWidgetBindingRoundTripAsJSON() throws {
        let original = try profile()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DashboardProfile.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.pages[0].widgets[0].signalID, "vehicle.speed")
        XCTAssertEqual(decoded.pages[0].widgets[0].configuration.warningThreshold, 180)
    }

    func testUnsupportedSchemaVersionIsRejected() throws {
        let json = Data("""
        {"schema_version":2,"id":"x","name":"X","pages":[]}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DashboardProfile.self, from: json)) { error in
            XCTAssertEqual(error as? DashboardModelError, .unsupportedSchemaVersion(2))
        }
    }

    func testDuplicateAndDeleteKeepWidgetIDsExplicit() throws {
        var page = DashboardPage(id: "main", name: "Main", orientation: .portrait, widgets: [widget()])
        try page.duplicateWidget(id: "speed", newID: "speed-copy")
        XCTAssertEqual(page.widgets.map(\.id), ["speed", "speed-copy"])
        XCTAssertTrue(page.deleteWidget(id: "speed"))
        XCTAssertFalse(page.deleteWidget(id: "missing"))
        XCTAssertEqual(page.widgets.map(\.id), ["speed-copy"])
    }

    func testProfileCanAddEverySupportedWidgetType() throws {
        var profile = try profile()
        for type in DashboardWidgetType.allCases {
            try profile.addWidget(
                DashboardWidgetDefinition(
                    id: "added-\(type.rawValue)",
                    type: type,
                    signalID: nil,
                    rect: DashboardRect(x: 0, y: 0, width: 1, height: 1),
                    zIndex: 10,
                    configuration: DashboardWidgetConfiguration(
                        label: type.rawValue, unit: "", decimals: 1,
                        minimum: nil, maximum: nil, warningThreshold: nil, criticalThreshold: nil
                    )
                ),
                toPage: "main"
            )
        }
        XCTAssertEqual(profile.pages[0].widgets.count, 1 + DashboardWidgetType.allCases.count)
    }

    func testSnapToGridRoundsPositionAndSizeWithoutDroppingMinimums() throws {
        var page = DashboardPage(id: "main", name: "Main", orientation: .landscape, widgets: [widget()])
        page.snapToGrid(8)
        XCTAssertEqual(page.widgets[0].rect, DashboardRect(x: 16, y: 16, width: 144, height: 64))
    }

    func testWidgetRectAndZOrderCanBeUpdatedByID() throws {
        var page = DashboardPage(id: "main", name: "Main", orientation: .landscape,
                                 widgets: [widget(), widget(id: "rpm")])
        try page.updateWidgetRect(id: "speed", rect: DashboardRect(x: 24, y: 16, width: 0, height: 0))
        XCTAssertEqual(page.widgets[0].rect, DashboardRect(x: 24, y: 16, width: 1, height: 1))
        try page.bringWidgetToFront(id: "speed")
        XCTAssertGreaterThan(page.widgets[0].zIndex, page.widgets[1].zIndex)
    }

    func testWidgetBindingAndConfigurationCanBeUpdatedByID() throws {
        var profile = try profile()
        let configuration = DashboardWidgetConfiguration(
            label: "Yaw rate", unit: "deg/s", decimals: 2,
            minimum: -50, maximum: 50, warningThreshold: 30, criticalThreshold: 45
        )
        try profile.updateWidgetBinding(
            pageID: "main",
            widgetID: "speed",
            signalID: "yaw",
            configuration: configuration
        )
        let widget = try XCTUnwrap(profile.pages[0].widgets.first)
        XCTAssertEqual(widget.signalID, "yaw")
        XCTAssertEqual(widget.configuration, configuration)
    }

    func testProfilePageLifecycleProtectsLastPage() throws {
        var profile = try profile()
        try profile.addPage(DashboardPage(id: "debug", name: "Debug", orientation: .portrait, widgets: []))
        XCTAssertEqual(profile.pages.map(\.id), ["main", "debug"])
        try profile.setPageOrientation(pageID: "main", orientation: .portrait)
        XCTAssertEqual(profile.pages[0].orientation, .portrait)
        XCTAssertTrue(try profile.deletePage(id: "debug"))
        XCTAssertThrowsError(try profile.deletePage(id: "main")) { error in
            XCTAssertEqual(error as? DashboardModelError, .cannotDeleteLastPage)
        }
    }

    func testLegacyDefaultGridMigrationOnlyTouchesSharedDefaultRects() throws {
        var first = widget(id: "ws-fl")
        var second = widget(id: "ws-fr")
        var third = widget(id: "ws-rl")
        first.rect = DashboardRect(x: 0, y: 0, width: 2, height: 1)
        second.rect = first.rect
        third.rect = first.rect
        var profile = try DashboardProfile(
            id: "legacy", name: "Legacy", pages: [DashboardPage(
                id: "main", name: "Main", orientation: .landscape,
                widgets: [first, second, third]
            )]
        )
        XCTAssertTrue(profile.migrateLegacyDefaultGrid())
        let rects = profile.pages[0].widgets.map(\.rect)
        XCTAssertEqual(rects, [
            DashboardRect(x: 0, y: 0, width: 2, height: 1),
            DashboardRect(x: 2, y: 0, width: 2, height: 1),
            DashboardRect(x: 4, y: 0, width: 2, height: 1)
        ])
        XCTAssertFalse(profile.migrateLegacyDefaultGrid())
    }
}
