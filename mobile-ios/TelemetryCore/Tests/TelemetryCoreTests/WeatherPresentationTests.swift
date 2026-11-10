import XCTest
@testable import TelemetryCore

// Mirrored acceptance cases only. Swift execution is explicitly deferred.
final class WeatherPresentationTests: XCTestCase {
    private func state() -> WeatherPresentationState {
        var s = WeatherPresentationState(); XCTAssertTrue(s.select(locationKey: "opaque-A")); return s
    }
    @discardableResult private func response(_ s: inout WeatherPresentationState,
        token: WeatherRequest? = nil, now: Double = 10, observed: Double? = 1000,
        wall: Double? = 1000, conditions: WeatherConditions = WeatherConditions()) -> Bool {
        guard let t = token ?? s.request(now: 0) else { XCTFail("missing request"); return false }
        return s.accept(t, conditions: conditions,
            metadata: WeatherMetadata(providerID: "test-provider", attribution: "Required attribution"),
            providerObservedUnix: observed, retrievedUnix: wall, now: now)
    }
    func testRequestIsDeclarative() {
        var s = state(); let t = s.request(now: 0)
        XCTAssertEqual(t?.locationKey, "opaque-A"); XCTAssertEqual(s.status, .loading); XCTAssertNil(s.snapshot)
    }
    func testPreviousLocationReplyRejected() {
        var s = state(); let t = s.request(now: 0); s.select(locationKey: "B")
        XCTAssertFalse(response(&s, token: t)); XCTAssertNil(s.snapshot)
    }
    func testSupersededReplyRejected() {
        var s = state(); let a = s.request(now: 0); let b = s.request(now: 1)
        XCTAssertFalse(response(&s, token: a)); XCTAssertTrue(response(&s, token: b))
    }
    func testCancelRejectsReply() {
        var s = state(); let t = s.request(now: 0); s.cancel()
        XCTAssertFalse(response(&s, token: t)); XCTAssertEqual(s.status, .cancelled)
    }
    func testFailureRejectsReply() {
        var s = state(); let t = s.request(now: 0)!
        XCTAssertTrue(s.fail(t, now: 1)); XCTAssertFalse(response(&s, token: t)); XCTAssertEqual(s.status, .failed)
    }
    func testMissingTemperatureStaysMissing() {
        var s = state(); response(&s); XCTAssertNil(s.snapshot?.conditions.temperatureCelsius)
    }
    func testMissingDiffersFromZero() {
        var s = state(); XCTAssertTrue(response(&s, conditions: WeatherConditions(temperatureCelsius: 0)))
        XCTAssertEqual(s.snapshot?.conditions.temperatureCelsius, 0); XCTAssertNil(s.snapshot?.conditions.pressureHectopascals)
    }
    func testInvalidValuesRejected() {
        let invalid = [WeatherConditions(temperatureCelsius: .nan), WeatherConditions(temperatureCelsius: .infinity),
            WeatherConditions(temperatureCelsius: -101), WeatherConditions(relativeHumidityFraction: 1.01),
            WeatherConditions(pressureHectopascals: 0), WeatherConditions(windMetersPerSecond: -1)]
        for conditions in invalid {
            var s = state(); XCTAssertFalse(response(&s, conditions: conditions)); XCTAssertEqual(s.status, .failed)
        }
    }
    func testFreshThenStaleThenPurged() {
        var s = state(); response(&s)
        XCTAssertEqual(s.presentation(now: 10), .fresh); XCTAssertEqual(s.presentation(now: 610), .stale)
        XCTAssertEqual(s.presentation(now: 1810), .unavailable); XCTAssertNil(s.snapshot)
    }
    func testOldObservationNotFresh() {
        var s = state(); response(&s, observed: 300); XCTAssertEqual(s.presentation(now: 10), .stale)
    }
    func testUnknownFutureInvalidTimestampNotFresh() {
        let pairs: [(Double?, Double?)] = [(nil, 1000), (1001, 1000), (.nan, 1000), (1000, .nan), (-1, 1000)]
        for (observed, wall) in pairs {
            var s = state(); response(&s, observed: observed, wall: wall); XCTAssertEqual(s.presentation(now: 10), .stale)
        }
    }
    func testOfflinePreservesLabeledSnapshot() {
        var s = state(); response(&s); XCTAssertEqual(s.presentation(now: 11, offline: true), .offline); XCTAssertNotNil(s.snapshot)
    }
    func testMonotonicRollbackPurges() {
        var s = state(); response(&s); XCTAssertEqual(s.presentation(now: 9), .unavailable); XCTAssertNil(s.snapshot)
    }
    func testNonfiniteClockPurges() {
        var s = state(); response(&s); XCTAssertEqual(s.presentation(now: .nan), .unavailable); XCTAssertNil(s.snapshot)
    }
    func testMetadataBoundIncludesPaddingAndUTF8() {
        let invalid = [WeatherMetadata(providerID: "p" + String(repeating: " ", count: 128), attribution: "a"),
            WeatherMetadata(providerID: "p", attribution: "a" + String(repeating: " ", count: 2048)),
            WeatherMetadata(providerID: String(repeating: "é", count: 65), attribution: "a")]
        for metadata in invalid {
            var s = state(); let t = s.request(now: 0)!
            XCTAssertFalse(s.accept(t, conditions: WeatherConditions(), metadata: metadata,
                providerObservedUnix: 1000, retrievedUnix: 1000, now: 10))
        }
    }
    func testLocationBoundIsUTF8Bytes() {
        var s = state(); XCTAssertFalse(s.select(locationKey: String(repeating: "é", count: 65))); XCTAssertNil(s.request(now: 10))
    }
    func testInvalidMetadataRejected() {
        var s = state(); let t = s.request(now: 0)!
        XCTAssertFalse(s.accept(t, conditions: WeatherConditions(), metadata: WeatherMetadata(providerID: "", attribution: ""),
            providerObservedUnix: 1000, retrievedUnix: 1000, now: 10)); XCTAssertNil(s.snapshot)
    }
    func testFailurePreservesPriorSnapshot() {
        var s = state(); response(&s); let t = s.request(now: 11)!; s.fail(t, now: 12)
        XCTAssertEqual(s.presentation(now: 12), .failed); XCTAssertNotNil(s.snapshot)
    }
    func testSelectClearsCurrentSnapshot() {
        var s = state(); response(&s); s.select(locationKey: "B"); XCTAssertNil(s.snapshot)
    }
    func testInvalidLocationRejected() {
        var s = state(); XCTAssertFalse(s.select(locationKey: String(repeating: "x", count: 129))); XCTAssertNil(s.request(now: 10))
    }
    func testReplyCannotRefreshTwice() {
        var s = state(); let t = s.request(now: 0); XCTAssertTrue(response(&s, token: t)); XCTAssertFalse(response(&s, token: t, now: 11))
    }
    func testPendingRequestDoesNotMakeOldSnapshotFresh() {
        var s = state(); response(&s); _ = s.request(now: 611); XCTAssertEqual(s.presentation(now: 612), .stale)
    }
    func testClearInvalidatesOldReplyEvenAfterReselection() {
        var s = state(); let t = s.request(now: 0); s.clear(); s.select(locationKey: "opaque-A"); _ = s.request(now: 1)
        XCTAssertFalse(response(&s, token: t)); XCTAssertNil(s.snapshot)
    }
    func testSourceIsExplicitProviderCurrentConditions() {
        var s = state(); response(&s); XCTAssertEqual(s.snapshot?.metadata.source, .providerCurrentConditions)
    }
}
