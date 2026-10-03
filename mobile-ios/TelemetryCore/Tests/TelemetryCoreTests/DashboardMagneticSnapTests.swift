import XCTest
@testable import TelemetryCore

final class DashboardMagneticSnapTests: XCTestCase {
    private let geometry = DashboardSnapGeometry(columnWidth: 60, rowHeight: 120)
    private func widget(_ id: String = "neighbor", x: Int, y: Int = 0, width: Int = 2, height: Int = 1) -> DashboardWidgetDefinition {
        .init(id: id, type: .numericGauge, signalID: nil,
              rect: .init(x: x, y: y, width: width, height: height), zIndex: 0,
              configuration: .init(label: id, unit: "%", decimals: 1, minimum: nil, maximum: nil,
                                   warningThreshold: nil, criticalThreshold: nil))
    }
    private func preview(_ original: DashboardRect, x: Double, y: Double,
                         width: Double? = nil, height: Double? = nil,
                         neighbors: [DashboardWidgetDefinition], resize: Bool = false,
                         geometry: DashboardSnapGeometry? = nil) -> DashboardSnapResult {
        DashboardMagneticSnap.preview(original: original,
            proposed: .init(x: x, y: y, width: width ?? Double(original.width), height: height ?? Double(original.height)),
            neighbors: neighbors, operation: resize ? .resize : .move, geometry: geometry ?? self.geometry)
    }

    func testNearbyEdgeCorrectsPreviewAndReportsRealGuide() {
        let original = DashboardRect(x: 0, y: 5, width: 2, height: 1)
        let result = preview(original, x: 2.65, y: 5, neighbors: [widget(x: 2)],
                             geometry: .init(columnWidth: 10, rowHeight: 100))
        XCTAssertEqual(result.bounds.x, 2)
        XCTAssertEqual(result.rect.x, 2, "A magnetic target differs from ordinary rounding to 3")
        XCTAssertTrue(result.guides.contains { $0.axis == .x && $0.kind == .edge && $0.position == 2 })
    }

    func testBeyondScreenThresholdKeepsContinuousPreview() {
        let result = preview(.init(x: 0, y: 5, width: 2, height: 1), x: 2.2, y: 5, neighbors: [widget(x: 2)])
        XCTAssertEqual(result.bounds.x, 2.2, accuracy: 0.0001)
        XCTAssertFalse(result.guides.contains { $0.axis == .x })
        XCTAssertEqual(result.rect.x, 2, "Integer quantization happens only for the eventual stored rect")
    }

    func testCenterSnapsWhenIntegerStorageCanRepresentIt() {
        let result = preview(.init(x: 0, y: 5, width: 2, height: 1), x: 4.9, y: 5,
                             neighbors: [widget(x: 4, width: 4)])
        XCTAssertEqual(result.bounds.x, 5)
        XCTAssertTrue(result.guides.contains { $0.axis == .x && $0.kind == .center && $0.position == 6 })
    }

    func testUnrepresentableHalfCellDoesNotShowFalseExactCenter() {
        let result = preview(.init(x: 0, y: 5, width: 2, height: 1), x: 4.5, y: 5,
                             neighbors: [widget(x: 4, width: 3)])
        XCTAssertEqual(result.bounds.x, 4.5)
        XCTAssertFalse(result.guides.contains { $0.axis == .x })
    }

    func testEqualGapBetweenNeighbors() {
        let result = preview(.init(x: 0, y: 0, width: 2, height: 1), x: 3.1, y: 0,
                             neighbors: [widget("left", x: 0), widget("right", x: 6)])
        XCTAssertEqual(result.bounds.x, 3)
        XCTAssertTrue(result.guides.contains { $0.axis == .x && $0.kind == .spacing })
        XCTAssertEqual(result.rect.x - 2, 6 - (result.rect.x + result.rect.width))
        XCTAssertTrue(result.overlappingWidgetIDs.isEmpty)
    }

    func testEqualGapExtendsExistingSequence() {
        let result = preview(.init(x: 0, y: 0, width: 2, height: 1), x: 7.91, y: 0,
                             neighbors: [widget("left", x: 0), widget("right", x: 4)])
        XCTAssertEqual(result.bounds.x, 8)
        XCTAssertTrue(result.guides.contains { $0.kind == .spacing && $0.axis == .x })
    }

    func testResizeMatchesNeighborDimensionsWithoutMovingOrigin() {
        let original = DashboardRect(x: 1, y: 1, width: 2, height: 1)
        let result = preview(original, x: 9, y: 9, width: 3.1, height: 2.04,
                             neighbors: [widget(x: 8, y: 5, width: 3, height: 2)], resize: true)
        XCTAssertEqual(result.rect, .init(x: 1, y: 1, width: 3, height: 2))
        XCTAssertEqual(result.bounds.x, 1); XCTAssertEqual(result.bounds.y, 1)
        XCTAssertTrue(result.guides.contains { $0.kind == .size && $0.axis == .x })
        XCTAssertTrue(result.guides.contains { $0.kind == .size && $0.axis == .y })
    }

    func testResizeTrailingEdgeAlignment() {
        let result = preview(.init(x: 1, y: 5, width: 2, height: 1), x: 1, y: 5, width: 4.9,
                             neighbors: [widget(x: 4, width: 2)], resize: true)
        XCTAssertEqual(result.rect.width, 5)
        XCTAssertTrue(result.guides.contains { $0.axis == .x && $0.kind == .edge && $0.position == 6 })
    }

    func testOverlapPreviewPreservesAllNeighbors() throws {
        let neighbors = [widget("keep-a", x: 4), widget("keep-b", x: 4)]
        let before = neighbors
        let result = preview(.init(x: 0, y: 0, width: 2, height: 1), x: 4, y: 0, neighbors: neighbors)
        XCTAssertEqual(result.overlappingWidgetIDs, ["keep-a", "keep-b"])
        XCTAssertEqual(neighbors, before, "Intentional existing overlaps cannot trigger neighbor pushing")
    }

    func testAdjacentPaddedCardsAreNotReportedAsColliding() {
        let result = preview(.init(x: 0, y: 0, width: 2, height: 1), x: 0, y: 0, neighbors: [widget(x: 2)])
        XCTAssertTrue(result.overlappingWidgetIDs.isEmpty)
    }

    func testZoomAndUnequalRowHeightUseScreenDistances() {
        let original = DashboardRect(x: 0, y: 0, width: 2, height: 1)
        let neighbors = [widget(x: 2, y: 2)]
        let ordinary = preview(original, x: 2.1, y: 2.1, neighbors: neighbors)
        XCTAssertEqual(ordinary.bounds.x, 2)
        XCTAssertEqual(ordinary.bounds.y, 2.1, accuracy: 0.0001)
        XCTAssertTrue(ordinary.guides.contains { $0.axis == .x })
        XCTAssertFalse(ordinary.guides.contains { $0.axis == .y })
        let zoomed = preview(original, x: 2.1, y: 2.1, neighbors: neighbors,
                             geometry: .init(columnWidth: 60, rowHeight: 120, zoom: 2))
        XCTAssertEqual(zoomed.bounds.x, 2.1, accuracy: 0.0001)
        XCTAssertTrue(zoomed.guides.isEmpty)
    }

    func testTieChoiceDoesNotDependOnNeighborArrayOrder() {
        let original = DashboardRect(x: 0, y: 5, width: 1, height: 1)
        let neighbors = [widget("a", x: 2, y: 0, width: 1), widget("z", x: 4, y: 2, width: 1)]
        let g = DashboardSnapGeometry(columnWidth: 6, rowHeight: 60)
        let first = preview(original, x: 3, y: 5, neighbors: neighbors, geometry: g)
        let second = preview(original, x: 3, y: 5, neighbors: neighbors.reversed(), geometry: g)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.bounds.x, 2)
    }

    func testInvalidGeometryOrNonfiniteProposalIsRejected() {
        let original = DashboardRect(x: 1, y: 2, width: 2, height: 1)
        for g in [DashboardSnapGeometry(columnWidth: 0, rowHeight: 60),
                  .init(columnWidth: .infinity, rowHeight: 60), .init(columnWidth: 60, rowHeight: 60, zoom: 0)] {
            let result = preview(original, x: 4, y: 5, neighbors: [widget(x: 4)], geometry: g)
            XCTAssertEqual(result.rect, original); XCTAssertTrue(result.guides.isEmpty)
        }
        let result = preview(original, x: .nan, y: 5, neighbors: [widget(x: 4)])
        XCTAssertEqual(result.rect, original); XCTAssertTrue(result.guides.isEmpty)
    }
}
