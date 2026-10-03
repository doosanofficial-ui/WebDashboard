import XCTest
@testable import TelemetryCore

final class DashboardEditDraftTests: XCTestCase {
    private func page() -> DashboardPage {
        .init(id: "page", name: "Page", orientation: .portrait, widgets: [
            .init(id: "active", type: .numericGauge, signalID: nil, rect: .init(x: 0, y: 0, width: 2, height: 1), zIndex: 0,
                  configuration: .init(label: "Active", unit: "%", decimals: 1, minimum: nil, maximum: nil, warningThreshold: nil, criticalThreshold: nil))])
    }
    func testTranslationUsesFrozenAnisotropicGeometryAndOnlyPreviewChanges() throws {
        let original = page()
        var draft = try XCTUnwrap(DashboardEditDraft(profileID: "profile", page: original, widgetID: "active", operation: .move,
                                                    geometry: .init(columnWidth: 50, rowHeight: 150)))
        draft.update(translationX: 75, translationY: 150)
        XCTAssertEqual(draft.result.bounds.x, 1.5); XCTAssertEqual(draft.result.bounds.y, 1)
        XCTAssertEqual(draft.page, original)
        XCTAssertEqual(draft.releaseRect, .init(x: 2, y: 1, width: 2, height: 1))
    }
    func testCancellationCannotRestartOrCommitEvenAfterLaterTranslation() throws {
        var draft = try XCTUnwrap(DashboardEditDraft(profileID: "profile", page: page(), widgetID: "active", operation: .resize,
                                                    geometry: .init(columnWidth: 50, rowHeight: 150)))
        draft.update(translationX: 50, translationY: 150)
        XCTAssertEqual(draft.releaseRect?.width, 3)
        draft.cancel(); draft.update(translationX: 200, translationY: 300)
        XCTAssertTrue(draft.isCancelled); XCTAssertNil(draft.releaseRect)
        XCTAssertEqual(draft.result.bounds, .init(draft.widget.rect))
        XCTAssertTrue(draft.result.guides.isEmpty)
    }
    func testInvalidGeometryAndMissingWidgetCannotBegin() {
        XCTAssertNil(DashboardEditDraft(profileID: "profile", page: page(), widgetID: "missing", operation: .move,
                                      geometry: .init(columnWidth: 50, rowHeight: 150)))
        XCTAssertNil(DashboardEditDraft(profileID: "profile", page: page(), widgetID: "active", operation: .move,
                                      geometry: .init(columnWidth: .infinity, rowHeight: 150)))
    }
}
