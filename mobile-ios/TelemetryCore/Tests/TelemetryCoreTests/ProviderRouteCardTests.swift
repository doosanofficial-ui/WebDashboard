import XCTest
@testable import TelemetryCore

// AUTHORED ONLY: Swift/XCTest deliberately UNRUN per user instruction.
final class ProviderRouteCardTests: XCTestCase {
    private func identity(_ generation: UInt64 = 1) -> ProviderRouteCard.Identity {
        .init(scopeID: "session", providerID: "provider", routeID: "subject", destinationID: "destination", generation: generation)
    }
    func testStaleCancellationAndGenerationIsolation() {
        var state = ProviderRouteCard(maximumAge: 10)!
        XCTAssertTrue(state.activate(identity(), now: 100))
        XCTAssertTrue(state.accept(identity: identity(), sequence: 0, observedMonotonic: 100,
                                   now: 100, attribution: "Provider", values: .init()))
        XCTAssertNotNil(state.render(now: 109))
        XCTAssertNil(state.render(now: 110))
        state.cancel()
        XCTAssertFalse(state.activate(identity(), now: 110))
        XCTAssertTrue(state.activate(identity(2), now: 110))
        XCTAssertFalse(state.accept(identity: identity(), sequence: 1, observedMonotonic: 110,
                                    now: 110, attribution: "Provider", values: .init()))
        XCTAssertNil(state.render(now: 110))
    }
    func testFutureReplayAndInvalidClock() {
        var state = ProviderRouteCard(maximumAge: 10)!
        XCTAssertTrue(state.activate(identity(), now: 100))
        XCTAssertFalse(state.accept(identity: identity(), sequence: 0, observedMonotonic: 101,
                                    now: 100, attribution: "Provider", values: .init()))
        XCTAssertTrue(state.accept(identity: identity(), sequence: 0, observedMonotonic: 100,
                                   now: 100, attribution: "Provider", values: .init()))
        XCTAssertFalse(state.accept(identity: identity(), sequence: 0, observedMonotonic: 100,
                                    now: 100, attribution: "Provider", values: .init()))
        XCTAssertNil(state.render(now: .nan))
        XCTAssertFalse(state.accept(identity: identity(), sequence: 1, observedMonotonic: 100,
                                    now: 100, attribution: "Provider", values: .init()))
    }
    func testIndependentOptionalEstimatesAndBounds() {
        let values = ProviderRouteCard.Values(currentStreet: "<b>Main</b>", remainingMeters: 0,
            remainingSeconds: -.infinity, providerObservedUnix: 100, estimatedArrivalUnix: 99)
        XCTAssertEqual(values.currentStreet, "<b>Main</b>")
        XCTAssertEqual(values.remainingMeters, 0)
        XCTAssertNil(values.remainingSeconds)
        XCTAssertNil(values.estimatedArrivalUnix)
        XCTAssertNil(ProviderRouteCard.Values(estimatedArrivalUnix: 200).estimatedArrivalUnix)
        XCTAssertNil(ProviderRouteCard.Values(currentStreet: "x\u{202E}y").currentStreet)
    }
}
