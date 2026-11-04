import XCTest
@testable import TelemetryCore

final class GuidancePresentationTests: XCTestCase {
    typealias G = GuidancePresentation
    func enabled() -> G {
        var g = G(policy: G.Policy()!)
        _ = g.configure(voice: true, layout: true)
        _ = g.activate(session: "s", generation: 1, route: "r", now: 0)
        return g
    }
    func p(session: String = "s", generation: UInt64 = 1, route: String = "r", maneuver: String = "m",
           sequence: Int = 1, at: Double = 10, verified: Bool = true, distance: Double = 40,
           confidence: Double = 1, stage: G.Stage = .approach) -> G.Progress {
        G.Progress(session: session, generation: generation, route: route, maneuver: maneuver,
                   sequence: sequence, observedAt: at, verified: verified, distanceMeters: distance,
                   confidence: confidence, stage: stage, direction: .left)
    }
    func testDefaultOptOut() {
        var g = G(policy: G.Policy()!); _ = g.activate(session: "s", generation: 1, route: "r", now: 0)
        XCTAssertEqual(g.update(p(), now: 10), [])
    }
    func testSuggestionsLocalizable() {
        var g = enabled()
        XCTAssertEqual(g.update(p(), now: 10), [.focusMap(maneuver: "m", expiresAt: 18), .prompt(localizationKey: "guidance.turn.approach.left", distanceMeters: 40)])
    }
    func testDedupAndCooldown() {
        var g = enabled(); _ = g.update(p(), now: 10)
        XCTAssertEqual(g.update(p(sequence: 2, at: 11), now: 11), [])
        XCTAssertEqual(g.update(p(sequence: 3, at: 12, stage: .atTurn), now: 12), [])
        XCTAssertEqual(g.update(p(sequence: 4, at: 16, stage: .atTurn), now: 16), [.prompt(localizationKey: "guidance.turn.now.left", distanceMeters: 40)])
    }
    func testInvalidEvidence() {
        let samples = [p(verified: false), p(session: "x"), p(generation: 2), p(route: "x"), p(maneuver: ""),
                       p(sequence: -1), p(at: 0), p(at: 11), p(at: .nan), p(distance: -1), p(distance: .infinity),
                       p(confidence: 0.2), p(confidence: .nan)]
        for sample in samples { var g = enabled(); XCTAssertEqual(g.update(sample, now: 10), []) }
        // Unknown stages/directions are unrepresentable. Adapter must reject unknown provider values.
    }
    func testRestoreOnInvalid() {
        var g = enabled(); _ = g.update(p(), now: 10)
        XCTAssertEqual(g.update(p(sequence: 2, at: 11, verified: false), now: 11), [.restoreLayout])
    }
    func testExpiryNoExtend() {
        var g = enabled(); _ = g.update(p(), now: 10)
        XCTAssertEqual(g.tick(now: 18), [.restoreLayout])
        XCTAssertEqual(g.update(p(sequence: 2, at: 19), now: 19), [])
    }
    func testCompletionExactNoDistanceInference() {
        var g = enabled(); XCTAssertFalse(g.update(p(distance: 0), now: 10).isEmpty)
        XCTAssertEqual(g.update(p(sequence: 2, at: 11, stage: .completed), now: 11), [.restoreLayout])
        XCTAssertEqual(g.update(p(sequence: 3, at: 12), now: 12), [])
    }
    func testStopAndReactivation() {
        var g = enabled(); _ = g.update(p(), now: 10); XCTAssertEqual(g.stop(), [.restoreLayout])
        _ = g.activate(session: "s", generation: 1, route: "r", now: 11)
        XCTAssertEqual(g.update(p(at: 12), now: 12), [])
        _ = g.activate(session: "s", generation: 2, route: "r", now: 12)
        XCTAssertFalse(g.update(p(generation: 2, at: 13), now: 13).isEmpty)
    }
    func testReorderAndClock() {
        var g = enabled(); _ = g.update(p(), now: 10)
        XCTAssertEqual(g.update(p(sequence: 1, at: 11), now: 11), [.restoreLayout])
        XCTAssertEqual(g.update(p(sequence: 2, at: 9), now: 9), [])
    }
    func testNewRouteRestoresAndOldSuppressed() {
        var g = enabled(); _ = g.update(p(), now: 10)
        XCTAssertEqual(g.activate(session: "s", generation: 2, route: "r2", now: 11), [.restoreLayout])
        XCTAssertEqual(g.update(p(sequence: 2, at: 12), now: 12), [])
    }
    func testDistantNoFocusOrPrompt() { var g = enabled(); XCTAssertEqual(g.update(p(distance: 1000), now: 10), []) }
    func testPolicyRevoke() {
        var g = enabled(); _ = g.update(p(), now: 10)
        XCTAssertEqual(g.configure(voice: false, layout: false), [.restoreLayout])
        XCTAssertEqual(g.update(p(sequence: 2, at: 11), now: 11), [])
    }
    func testTickStaleRestores() {
        var g = enabled(); _ = g.update(p(), now: 10); XCTAssertEqual(g.tick(now: 16), [.restoreLayout])
    }
    func testPolicyValidation() {
        for value in [-1.0, Double.nan, Double.infinity] { XCTAssertNil(G.Policy(maximumAge: value)) }
    }
    func testManeuverTransitionRestores() {
        var g = enabled(); _ = g.update(p(), now: 10)
        XCTAssertEqual(g.update(p(maneuver: "m2", sequence: 2, at: 11), now: 11), [.restoreLayout, .focusMap(maneuver: "m2", expiresAt: 19)])
    }
    func testStageCannotRegress() {
        var g = enabled(); _ = g.update(p(stage: .atTurn), now: 10)
        XCTAssertEqual(g.update(p(sequence: 2, at: 16), now: 16), [.restoreLayout])
    }
    func testCapacityIsBounded() {
        var g = enabled()
        for n in 0..<256 {
            let time = Double(10 + n * 6)
            _ = g.update(p(maneuver: "m\(n)", sequence: n + 1, at: time), now: time)
        }
        XCTAssertEqual(g.update(p(maneuver: "overflow", sequence: 257, at: 1546), now: 1546), [.restoreLayout])
    }
}
