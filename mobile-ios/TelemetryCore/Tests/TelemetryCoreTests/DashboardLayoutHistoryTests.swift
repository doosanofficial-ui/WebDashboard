import XCTest
@testable import TelemetryCore

final class DashboardLayoutHistoryTests: XCTestCase {
    private func fixture() throws -> DashboardProfile {
        try .init(id: "profile", name: "Saved", pages: [.init(id: "page", name: "Page", orientation: .portrait,
            widgets: ["active", "neighbor"].enumerated().map { index, id in
                .init(id: id, type: .numericGauge, signalID: nil,
                      rect: .init(x: index * 2, y: 0, width: 2, height: 1), zIndex: index,
                      configuration: .init(label: id, unit: "%", decimals: 1, minimum: nil, maximum: nil,
                                           warningThreshold: nil, criticalThreshold: nil))
            })])
    }
    func testReleaseCommitsOnlyActiveRectAndUndoRedoPreserveLaterNeighborEdit() throws {
        var profile = try fixture(); let original = profile; var history = DashboardLayoutHistory()
        let moved = DashboardRect(x: 1, y: 3, width: 2, height: 1)
        XCTAssertTrue(history.commit(profile: &profile, expectedProfileID: original.id,
            expectedPage: original.pages[0], widgetID: "active", rect: moved))
        XCTAssertEqual(profile.pages[0].widgets[1], original.pages[0].widgets[1])
        let neighbor = DashboardRect(x: 7, y: 4, width: 3, height: 2)
        try profile.updateWidgetRect(pageID: "page", widgetID: "neighbor", rect: neighbor)
        XCTAssertTrue(history.canUndo(in: profile)); XCTAssertTrue(history.undo(profile: &profile))
        XCTAssertEqual(profile.pages[0].widgets[0].rect, original.pages[0].widgets[0].rect)
        XCTAssertEqual(profile.pages[0].widgets[1].rect, neighbor)
        XCTAssertTrue(history.canRedo(in: profile)); XCTAssertTrue(history.redo(profile: &profile))
        XCTAssertEqual(profile.pages[0].widgets[0].rect, moved)
        XCTAssertEqual(profile.pages[0].widgets[1].rect, neighbor)
    }
    func testStalePageRejectsReleaseWithoutChangingProfileOrHistory() throws {
        var profile = try fixture(); let original = profile; var history = DashboardLayoutHistory()
        try profile.updateWidgetRect(pageID: "page", widgetID: "neighbor", rect: .init(x: 3, y: 4, width: 2, height: 1))
        let current = profile
        XCTAssertFalse(history.commit(profile: &profile, expectedProfileID: original.id,
            expectedPage: original.pages[0], widgetID: "active", rect: .init(x: 1, y: 4, width: 2, height: 1)))
        XCTAssertEqual(profile, current); XCTAssertFalse(history.canUndo(in: profile))
    }
    func testNoOpReleaseDoesNotEraseRedo() throws {
        var profile = try fixture(); let original = profile; var history = DashboardLayoutHistory()
        XCTAssertTrue(history.commit(profile: &profile, expectedProfileID: profile.id, expectedPage: profile.pages[0],
            widgetID: "active", rect: .init(x: 1, y: 2, width: 2, height: 1)))
        XCTAssertTrue(history.undo(profile: &profile))
        XCTAssertFalse(history.commit(profile: &profile, expectedProfileID: original.id, expectedPage: original.pages[0],
            widgetID: "active", rect: original.pages[0].widgets[0].rect))
        XCTAssertTrue(history.canRedo(in: profile))
    }
    func testStaleActiveRectDisablesUndoWithoutOverwritingNewEdit() throws {
        var profile = try fixture(); var history = DashboardLayoutHistory()
        XCTAssertTrue(history.commit(profile: &profile, expectedProfileID: profile.id, expectedPage: profile.pages[0],
            widgetID: "active", rect: .init(x: 1, y: 2, width: 2, height: 1)))
        try profile.updateWidgetRect(pageID: "page", widgetID: "active", rect: .init(x: 8, y: 2, width: 2, height: 1))
        let current = profile
        XCTAssertFalse(history.canUndo(in: profile)); XCTAssertFalse(history.undo(profile: &profile))
        XCTAssertEqual(profile, current)
    }
    func testNewReleaseAfterUndoClearsRedoAndHistoryIsBounded() throws {
        var profile = try fixture(); var history = DashboardLayoutHistory()
        for y in 1...55 {
            XCTAssertTrue(history.commit(profile: &profile, expectedProfileID: profile.id, expectedPage: profile.pages[0],
                widgetID: "active", rect: .init(x: 0, y: y, width: 2, height: 1)))
        }
        var count = 0
        while history.undo(profile: &profile) { count += 1 }
        XCTAssertEqual(count, 50)
        XCTAssertTrue(history.commit(profile: &profile, expectedProfileID: profile.id, expectedPage: profile.pages[0],
            widgetID: "active", rect: .init(x: 1, y: 1, width: 2, height: 1)))
        XCTAssertFalse(history.canRedo(in: profile))
    }
}
