import XCTest
@testable import TelemetryCore

final class SpeedDisplaySelectionTests: XCTestCase {
    func sample(_ source: SpeedDisplaySource = .obd, value: Double = 36,
                unit: SpeedDisplayUnit = .kilometersPerHour, stamp: Double = 10,
                scope: String = "trip-A", generation: Int = 3, producer: String = "sensor",
                segment: Int = 0, good: Bool = true, accuracy: Double? = 1) -> SpeedDisplayObservation {
        .init(source: source, value: value, unit: unit, monotonicTime: stamp,
              scope: scope, generation: generation, producer: producer, segment: segment,
              qualityAccepted: good, speedAccuracyMetersPerSecond: accuracy)
    }
    func testDefaultDoesNotReplaceExistingAndOnlyNeverSubstitutes() {
        var s = SpeedDisplaySelector(scope: "trip-A", generation: 3)
        XCTAssertEqual(s.select(now: 10, obd: sample(), gps: sample(.gps)).status, .preserveExisting)
        XCTAssertNil(s.select(mode: .obdOnly, now: 10, gps: sample(.gps)).metersPerSecond)
        XCTAssertNil(s.select(mode: .gpsOnly, now: 10, obd: sample()).metersPerSecond)
    }
    func testExplicitFallbackHasSourceAndDisplayOnlyProvenance() {
        var s = SpeedDisplaySelector(scope: "trip-A", generation: 3)
        let r = s.select(mode: .preferOBDWithFallback, now: 10, gps: sample(.gps))
        XCTAssertEqual(r.metersPerSecond, 10); XCTAssertEqual(r.label, "GPS")
        XCTAssertEqual(r.observation?.producer, "sensor"); XCTAssertTrue(r.usedFallback)
        XCTAssertTrue(r.displayOnly)
    }
    func testZeroAndUnitConversion() {
        var s = SpeedDisplaySelector(scope: "trip-A", generation: 3)
        XCTAssertEqual(s.select(mode: .obdOnly, now: 10, obd: sample(value: 0)).metersPerSecond, 0)
        XCTAssertEqual(s.select(mode: .obdOnly, now: 10, obd: sample(value: 10, unit: .metersPerSecond)).metersPerSecond, 10)
        let r = s.select(mode: .obdOnly, now: 10, obd: sample(value: 22.369362920544, unit: .milesPerHour))
        XCTAssertEqual(r.metersPerSecond ?? -1, 10, accuracy: 0.000001)
        XCTAssertNil(s.select(mode: .obdOnly, now: 10).metersPerSecond)
    }
    func testInvalidEvidence() {
        let samples = [sample(value: -1), sample(value: .nan), sample(value: .infinity),
                       sample(stamp: 11), sample(stamp: 7.99), sample(stamp: .nan),
                       sample(scope: "trip-B"), sample(generation: 4), sample(producer: ""),
                       sample(segment: -1), sample(good: false), sample(.gps)]
        for observation in samples {
            var s = SpeedDisplaySelector(scope: "trip-A", generation: 3)
            XCTAssertNil(s.select(mode: .obdOnly, now: 10, obd: observation).metersPerSecond)
        }
    }
    func testGPSAccuracyAndFreshness() {
        let invalid: [Double?] = [nil, -1, .nan, .infinity, 3.001]
        for accuracy in invalid {
            var s = SpeedDisplaySelector(scope: "trip-A", generation: 3)
            XCTAssertNil(s.select(mode: .gpsOnly, now: 10, gps: sample(.gps, accuracy: accuracy)).metersPerSecond)
        }
        var s = SpeedDisplaySelector(scope: "trip-A", generation: 3)
        XCTAssertNotNil(s.select(mode: .gpsOnly, now: 10, gps: sample(.gps, stamp: 8, accuracy: 3)).metersPerSecond)
    }
    func testClockConfigurationAndSourceRegression() {
        var s = SpeedDisplaySelector(scope: "trip-A", generation: 3)
        _ = s.select(mode: .obdOnly, now: 10, obd: sample(segment: 2))
        XCTAssertEqual(s.select(mode: .gpsOnly, now: 9, gps: sample(.gps, stamp: 9)).status, .invalidContextPolicyOrClock)
        XCTAssertNil(s.select(mode: .obdOnly, now: 9.5, obd: sample(stamp: 9.5)).metersPerSecond)
        XCTAssertNil(s.select(mode: .obdOnly, now: 10.1, obd: sample(stamp: 10.1, segment: 1)).metersPerSecond)
        XCTAssertNil(s.select(mode: .obdOnly, now: 10.1, obd: sample(stamp: 9.9, producer: "new")).metersPerSecond)
        XCTAssertNil(s.select(mode: .obdOnly, now: .nan, obd: sample()).metersPerSecond)
        XCTAssertNil(s.select(mode: .obdOnly, now: 10, obd: sample(), maximumAge: -1).metersPerSecond)
        XCTAssertNil(s.select(mode: .obdOnly, now: 10, obd: sample(), maximumGPSAccuracy: .infinity).metersPerSecond)
    }
    func testBoundariesForSourceGapPreferenceAndSegment() {
        var s = SpeedDisplaySelector(scope: "trip-A", generation: 3)
        XCTAssertFalse(s.select(mode: .preferOBDWithFallback, now: 10, obd: sample()).continuityBoundary)
        XCTAssertFalse(s.select(mode: .preferOBDWithFallback, now: 10, obd: sample()).continuityBoundary)
        XCTAssertTrue(s.select(mode: .preferOBDWithFallback, now: 10, gps: sample(.gps)).continuityBoundary)
        XCTAssertTrue(s.select(mode: .preferOBDWithFallback, now: 10).continuityBoundary)
        XCTAssertTrue(s.select(mode: .preferOBDWithFallback, now: 10, obd: sample()).continuityBoundary)
        XCTAssertTrue(s.select(mode: .obdOnly, now: 10, obd: sample()).continuityBoundary)
        XCTAssertTrue(s.select(mode: .obdOnly, now: 10, obd: sample(segment: 1)).continuityBoundary)
    }
    func testPreferenceAndRejectionReasons() {
        var s = SpeedDisplaySelector(scope: "trip-A", generation: 3)
        XCTAssertEqual(s.select(mode: .preferGPSWithFallback, now: 10, obd: sample(), gps: sample(.gps)).observation?.source, .gps)
        XCTAssertEqual(s.select(mode: .preferOBDWithFallback, now: 10, obd: sample(), gps: sample(.gps)).observation?.source, .obd)
        let r = s.select(mode: .preferOBDWithFallback, now: 10, obd: sample(stamp: 7), gps: sample(.gps))
        XCTAssertEqual(r.rejections[.obd], .stale)
        XCTAssertTrue(r.usedFallback)
    }
    func testInvalidContextAndProducerBoundary() {
        var invalid = SpeedDisplaySelector(scope: "", generation: 3)
        XCTAssertNil(invalid.select(mode: .obdOnly, now: 10, obd: sample()).metersPerSecond)
        var s = SpeedDisplaySelector(scope: "trip-A", generation: 3)
        _ = s.select(mode: .obdOnly, now: 10, obd: sample())
        XCTAssertTrue(s.select(mode: .obdOnly, now: 10, obd: sample(producer: "otherECU")).continuityBoundary)
    }

}
