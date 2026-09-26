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

    func testSnapToGridRoundsPositionAndSizeWithoutDroppingMinimums() throws {
        var page = DashboardPage(id: "main", name: "Main", orientation: .landscape, widgets: [widget()])
        page.snapToGrid(8)
        XCTAssertEqual(page.widgets[0].rect, DashboardRect(x: 16, y: 16, width: 144, height: 64))
    }
}
