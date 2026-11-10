import XCTest
@testable import TelemetryCore

// AUTHORED ONLY: Swift/XCTest deliberately UNRUN per user instruction.
final class ProviderWeatherDisplayTests: XCTestCase {
    private func identity(_ generation: UInt64 = 1) -> ProviderWeatherDisplay.Identity {
        .init(scopeID: "session", providerID: "provider", locationID: "subject", requestID: "destination", generation: generation)
    }
    func testStaleCancellationAndGenerationIsolation() {
        var state = ProviderWeatherDisplay(maximumAge: 10)!
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
        var state = ProviderWeatherDisplay(maximumAge: 10)!
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
    func testProviderFactsAndUnknownDefaults() {
        XCTAssertEqual(ProviderWeatherDisplay.Values().condition, .unknown)
        XCTAssertEqual(ProviderWeatherDisplay.Values().daylight, .unknown)
        let values = ProviderWeatherDisplay.Values(condition: .snow, daylight: .night)
        XCTAssertEqual(values.condition.localizationKey, "weather.condition.snow")
        XCTAssertEqual(values.daylight.localizationKey, "weather.daylight.night")
    }
}
