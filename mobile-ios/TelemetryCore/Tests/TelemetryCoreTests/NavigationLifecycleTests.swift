import XCTest
@testable import TelemetryCore

final class NavigationLifecycleTests: XCTestCase {
    typealias N = NavigationLifecycle
    func make() -> N { N(policy: N.Policy(maximumProgressAge: 5, rerouteCooldown: 20, resumeTTL: 60)!) }
    func active() -> N {
        var n = make()
        _ = n.send(.request(destinationID: "synthetic-destination"), now: 0)
        _ = n.send(.accepted(token: 1, routeID: "route-a"), now: 0)
        _ = n.send(.start(token: 1), now: 0)
        XCTAssertNotNil(n.active)
        return n
    }
    func progress(_ n: inout N, now: Double = 1, token: UInt64 = 1, route: String = "route-a", sequence: Int = 1,
                  at: Double? = nil, quality: N.Quality = .verified, arrival: Bool = false, offRoute: Bool? = false) -> [N.Effect] {
        n.send(.progress(token: token, routeID: route, sequence: sequence, observedAt: at ?? now,
                         quality: quality, arrival: arrival, offRoute: offRoute), now: now)
    }
    func testRequestIsDeclarative() {
        var n = make()
        XCTAssertEqual(n.send(.request(destinationID: "d"), now: 0), [.requestRoute(token: 1, destinationID: "d")])
        XCTAssertNil(n.active)
    }
    func testStartRequiresAcceptedCurrentToken() {
        var n = make(); _ = n.send(.request(destinationID: "d"), now: 0)
        _ = n.send(.start(token: 1), now: 0); XCTAssertNil(n.active)
        _ = n.send(.accepted(token: 1, routeID: "r"), now: 0)
        _ = n.send(.start(token: 0), now: 0); XCTAssertNil(n.active)
        _ = n.send(.start(token: 1), now: 0); XCTAssertEqual(n.active?.routeID, "r")
    }
    func testStaleResponse() {
        var n = make(); _ = n.send(.request(destinationID: "old"), now: 0)
        _ = n.send(.request(destinationID: "new"), now: 0)
        _ = n.send(.accepted(token: 1, routeID: "old-route"), now: 0); XCTAssertNil(n.candidate)
    }
    func testReplacementNeedsStart() {
        var n = active(); _ = n.send(.request(destinationID: "new"), now: 0)
        _ = n.send(.accepted(token: 2, routeID: "b"), now: 0); XCTAssertEqual(n.active?.routeID, "route-a")
        _ = n.send(.start(token: 2), now: 0); XCTAssertEqual(n.active?.routeID, "b")
    }
    func testFailedCanceledReplacementPreservesGuidance() {
        for event in [N.Event.failed(token: 2), .cancel(token: 2)] {
            var n = active(); _ = n.send(.request(destinationID: "new"), now: 0)
            _ = n.send(event, now: 0); XCTAssertEqual(n.active?.routeID, "route-a"); XCTAssertNil(n.pending)
            _ = n.send(.accepted(token: 2, routeID: "late"), now: 0); XCTAssertNil(n.candidate)
        }
    }
    func testStopInvalidatesEverything() {
        var n = active(); _ = n.send(.request(destinationID: "new"), now: 0)
        _ = n.send(.stop, now: 0); _ = n.send(.accepted(token: 2, routeID: "late"), now: 0)
        XCTAssertNil(n.active); XCTAssertNil(n.pending); XCTAssertNil(n.candidate)
    }
    func testUnqualifiedAndOutOfOrderNeverArrive() {
        var n = active()
        XCTAssertEqual(progress(&n, quality: .unknown, arrival: true), [])
        XCTAssertEqual(progress(&n, at: -10, arrival: true), [])
        XCTAssertEqual(progress(&n, at: 2, arrival: true), [])
        XCTAssertEqual(progress(&n, token: 0, arrival: true), [])
        XCTAssertEqual(progress(&n, route: "wrong", arrival: true), [])
        _ = progress(&n, sequence: 5)
        XCTAssertEqual(progress(&n, sequence: 4, arrival: true), []); XCTAssertNotNil(n.active)
    }
    func testExplicitArrivalSingle() {
        var n = active(); XCTAssertEqual(progress(&n, arrival: true), [.arrived]); XCTAssertNil(n.active)
        XCTAssertEqual(progress(&n, now: 2, arrival: true), [])
    }
    func testUnknownFixPreservesGuidance() {
        var n = active(); XCTAssertEqual(progress(&n, quality: .unknown, offRoute: true), []); XCTAssertNotNil(n.active)
    }
    func testRerouteCooldownAndRearm() {
        var n = active(); XCTAssertEqual(progress(&n, offRoute: true), [.suggestReroute])
        XCTAssertEqual(progress(&n, now: 30, sequence: 2, offRoute: true), [])
        _ = progress(&n, now: 31, sequence: 3)
        XCTAssertEqual(progress(&n, now: 32, sequence: 4, offRoute: true), [.suggestReroute])
        _ = progress(&n, now: 33, sequence: 5)
        XCTAssertEqual(progress(&n, now: 34, sequence: 6, offRoute: true), [])
    }
    func testResumeConfirmationAndRevalidation() {
        var n = active(); _ = n.send(.suspend, now: 1)
        XCTAssertEqual(n.send(.resume(confirmed: false), now: 2), []); XCTAssertNil(n.active)
        XCTAssertEqual(n.send(.resume(confirmed: true), now: 3), [.requestRoute(token: 2, destinationID: "synthetic-destination")])
        XCTAssertNil(n.active)
    }
    func testExpiredResume() {
        var n = active(); _ = n.send(.suspend, now: 1)
        XCTAssertEqual(n.send(.resume(confirmed: true), now: 62), [.resumeExpired]); XCTAssertNil(n.pending)
    }
    func testInvalidClockPolicy() {
        XCTAssertNil(N.Policy(maximumProgressAge: .nan, rerouteCooldown: 1, resumeTTL: 2))
        XCTAssertNil(N.Policy(maximumProgressAge: -1, rerouteCooldown: 1, resumeTTL: 2))
        XCTAssertNil(N.Policy(maximumProgressAge: 1, rerouteCooldown: .infinity, resumeTTL: 2))
        var n = active(); _ = n.send(.stop, now: .nan); XCTAssertNotNil(n.active)
        _ = progress(&n, now: 2); _ = n.send(.stop, now: 1); XCTAssertNotNil(n.active)
    }
    func testOldPositiveFixNeverArrives() {
        var n = active(); XCTAssertEqual(progress(&n, now: 10, at: 1, arrival: true), [])
        XCTAssertNotNil(n.active)
    }
    func testNegativeObservationIsNeverArrival() {
        var n = active(); XCTAssertEqual(progress(&n, now: 0, at: -0.5, arrival: true), [])
        XCTAssertNotNil(n.active)
    }
    func testInvalidIdentifiersAndSequence() {
        var n = make()
        for id in ["", String(repeating: "x", count: 129), "https://example.com", "with space"] {
            _ = n.send(.request(destinationID: id), now: 0); XCTAssertNil(n.pending)
        }
        n = active(); XCTAssertEqual(progress(&n, sequence: -1, arrival: true), [])
    }
}
