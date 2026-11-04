import XCTest
@testable import TelemetryCore

final class ConditionAlertPresentationTests: XCTestCase {
    typealias P = ConditionAlertPresentation
    let scope = P.Scope(domain: .vehicle, source: 1, session: 10, configuration: 1)
    func make() -> P { P(scope: scope, definitions: [
        .init(id: .condition1, severity: .warning, category: .condition),
        .init(id: .condition2, severity: .attention, category: .diagnostic),
        .init(id: .condition3, severity: .warning, category: .telemetry)])! }
    func testInitialUnknown() { let p = make(); XCTAssertEqual(p.snapshot().unavailableCount, 3); XCTAssertEqual(p.snapshot().activeEvidenceCount, 0) }
    func testPriorityDedup() {
        var p = make(); XCTAssertTrue(p.apply(scope: scope, version: 1, changes: [.init(id: .condition2, state: .active), .init(id: .condition3, state: .active), .init(id: .condition1, state: .active)]))
        XCTAssertEqual(p.snapshot().rows.map { $0.definition.id }, [.condition1, .condition3, .condition2])
        XCTAssertTrue(p.apply(scope: scope, version: 2, changes: [.init(id: .condition1, state: .active)])); XCTAssertEqual(p.snapshot().rows.count, 3)
    }
    func testExplicitResolution() { var p = make(); p.apply(scope: scope, version: 1, changes: [.init(id: .condition1, state: .active)]); p.apply(scope: scope, version: 2, changes: [.init(id: .condition1, state: .resolved)]); XCTAssertEqual(p.snapshot().activeEvidenceCount, 0); XCTAssertEqual(p.snapshot().unavailableCount, 2) }
    func testUnavailableRetainsActive() {
        for state: P.State in [.unknown, .stale, .disconnected] {
            var p = make(); p.apply(scope: scope, version: 1, changes: [.init(id: .condition1, state: .active)]); p.apply(scope: scope, version: 2, changes: [.init(id: .condition1, state: state)])
            XCTAssertEqual(p.snapshot().activeEvidenceCount, 1); XCTAssertEqual(p.snapshot().unavailableCount, 3)
            XCTAssertEqual(p.snapshot().rows.first?.state, state); XCTAssertEqual(p.snapshot().rows.first?.lastConfirmedActive, true)
        }
    }
    func testUnavailableAfterResolved() { var p = make(); p.apply(scope: scope, version: 1, changes: [.init(id: .condition1, state: .resolved)]); p.apply(scope: scope, version: 2, changes: [.init(id: .condition1, state: .stale)]); XCTAssertEqual(p.snapshot().rows.first?.lastConfirmedActive, false); XCTAssertEqual(p.snapshot().unavailableCount, 3) }
    func testMissingDeltaPreserves() { var p = make(); p.apply(scope: scope, version: 1, changes: [.init(id: .condition1, state: .active)]); p.apply(scope: scope, version: 2, changes: [.init(id: .condition2, state: .resolved)]); XCTAssertEqual(p.snapshot().rows.first?.state, .active) }
    func testOldVersionsRejected() { var p = make(); p.apply(scope: scope, version: 5, changes: [.init(id: .condition1, state: .active)]); for v: UInt64 in [4,5] { XCTAssertFalse(p.apply(scope: scope, version: v, changes: [.init(id: .condition1, state: .resolved)])); XCTAssertEqual(p.snapshot().activeEvidenceCount, 1); XCTAssertEqual(p.snapshot().version, 5) } }
    func testScopeBoundaries() {
        var p = make(); p.apply(scope: scope, version: 1, changes: [.init(id: .condition1, state: .active)])
        for s in [P.Scope(domain: .synthetic, source: 1, session: 10, configuration: 1), P.Scope(domain: .vehicle, source: 2, session: 10, configuration: 1), P.Scope(domain: .vehicle, source: 1, session: 11, configuration: 1), P.Scope(domain: .vehicle, source: 1, session: 10, configuration: 2)] {
            XCTAssertFalse(p.apply(scope: s, version: 100, changes: [.init(id: .condition1, state: .resolved)])); XCTAssertEqual(p.snapshot().activeEvidenceCount, 1)
        }
        XCTAssertTrue(p.apply(scope: scope, version: 2, changes: [.init(id: .condition1, state: .resolved)]))
    }
    func testAtomicDuplicateRejection() { var p = make(); XCTAssertFalse(p.apply(scope: scope, version: 1, changes: [.init(id: .condition1, state: .active), .init(id: .condition1, state: .resolved)])); XCTAssertEqual(p.snapshot().activeEvidenceCount, 0); XCTAssertTrue(p.apply(scope: scope, version: 1, changes: [.init(id: .condition1, state: .active)])) }
    func testAtomicUnmonitoredRejection() { var p = make(); XCTAssertFalse(p.apply(scope: scope, version: 1, changes: [.init(id: .condition1, state: .active), .init(id: .condition8, state: .active)])); XCTAssertEqual(p.snapshot().activeEvidenceCount, 0); XCTAssertEqual(p.snapshot().version, 0) }
    func testVisibilityNotResolution() { var p = make(); p.apply(scope: scope, version: 1, changes: [.init(id: .condition1, state: .active)]); XCTAssertTrue(p.setVisible(false, for: .condition1)); XCTAssertFalse(p.snapshot().rows.contains { $0.definition.id == .condition1 }); XCTAssertEqual(p.snapshot().activeEvidenceCount, 1); XCTAssertTrue(p.setVisible(true, for: .condition1)); XCTAssertEqual(p.snapshot().rows.first?.state, .active) }
    func testInvalidVisibility() { var p = make(); XCTAssertFalse(p.setVisible(false, for: .condition8)); XCTAssertEqual(p.snapshot().rows.count, 3) }
    func testHiddenNotAllSafe() { var p = make(); for id: P.ID in [.condition1, .condition2, .condition3] { p.setVisible(false, for: id) }; XCTAssertTrue(p.snapshot().rows.isEmpty); XCTAssertEqual(p.snapshot().unavailableCount, 3) }
    func testVersionBoundsAndEmpty() { var p = make(); XCTAssertFalse(p.apply(scope: scope, version: 0, changes: [.init(id: .condition1, state: .active)])); XCTAssertFalse(p.apply(scope: scope, version: 1, changes: [])); XCTAssertTrue(p.apply(scope: scope, version: UInt64.max, changes: [.init(id: .condition1, state: .active)])) }
    func testInvalidDefinitions() { XCTAssertNil(P(scope: scope, definitions: [])); let d = P.Definition(id: .condition1, severity: .warning, category: .condition); XCTAssertNil(P(scope: scope, definitions: [d,d])) }
    func testInvalidScope() { for s in [P.Scope(domain: .vehicle, source: 0, session: 10, configuration: 1), P.Scope(domain: .vehicle, source: 1, session: 0, configuration: 1), P.Scope(domain: .vehicle, source: 1, session: 10, configuration: 0)] { XCTAssertNil(P(scope: s, definitions: [.init(id: .condition1, severity: .warning, category: .condition)])) } }
    func testResolvedRowsOmitted() { var p = make(); p.apply(scope: scope, version: 1, changes: [.init(id: .condition1, state: .resolved), .init(id: .condition2, state: .resolved), .init(id: .condition3, state: .resolved)]); XCTAssertTrue(p.snapshot().rows.isEmpty); XCTAssertEqual(p.snapshot().unavailableCount, 0) }
}
