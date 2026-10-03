import Foundation
import XCTest
import TelemetryCore
@testable import TelemetryLifecycleHost

final class TelemetryDisplayStateTests: XCTestCase {
    func testModeLabelsDistinguishSyntheticAndRecordedOrigins() {
        XCTAssertEqual(TelemetryDisplayState.modeTitle(.demo, recordingMode: nil), "DEMO · synthetic CAN data")
        XCTAssertEqual(TelemetryDisplayState.modeTitle(.live, recordingMode: nil), "LIVE · vehicle data")
        XCTAssertEqual(TelemetryDisplayState.modeTitle(.replay, recordingMode: .demo), "REPLAY · DEMO recording")
        XCTAssertEqual(TelemetryDisplayState.modeTitle(.replay, recordingMode: .live), "REPLAY · vehicle recording")
    }
    func testMissingInvalidAndKnownZeroDoNotCollapseIntoStale() {
        XCTAssertEqual(TelemetryDisplayState.signalLabel(nil, liveFresh: true), "NO SAMPLE")
        XCTAssertEqual(TelemetryDisplayState.signalLabel(.nan, liveFresh: true), "INVALID")
        XCTAssertEqual(TelemetryDisplayState.signalLabel(.infinity, liveFresh: false), "INVALID")
        XCTAssertEqual(TelemetryDisplayState.signalLabel(0, liveFresh: true), "VALID")
        XCTAssertEqual(TelemetryDisplayState.signalLabel(53, liveFresh: false), "STALE")
    }
    func testOriginalReplayQualityRemainsSeparateFromUnknownFreshness() {
        XCTAssertEqual(TelemetryDisplayState.signalLabel(48.5, liveFresh: false, replayQuality: .valid), "VALID RECORDED")
        XCTAssertEqual(TelemetryDisplayState.signalLabel(48.5, liveFresh: true, replayQuality: .invalid), "INVALID RECORDED")
        XCTAssertEqual(TelemetryDisplayState.freshnessLabel(nil), "FRESHNESS UNKNOWN")
        XCTAssertEqual(TelemetryDisplayState.freshnessLabel(.fresh), "FRESHNESS FRESH")
        XCTAssertEqual(TelemetryDisplayState.freshnessLabel(.stale), "FRESHNESS STALE")
    }
    func testStaleFilterExcludesMissingInvalidAndUnknownRecordedFreshness() {
        XCTAssertFalse(TelemetryDisplayState.matchesStaleFilter(nil, liveFresh: false, isReplay: false, replayFreshness: nil))
        XCTAssertFalse(TelemetryDisplayState.matchesStaleFilter(.nan, liveFresh: false, isReplay: false, replayFreshness: nil))
        XCTAssertFalse(TelemetryDisplayState.matchesStaleFilter(48.5, liveFresh: false, isReplay: true, replayFreshness: .unknown))
        XCTAssertFalse(TelemetryDisplayState.matchesStaleFilter(48.5, liveFresh: false, isReplay: true, replayFreshness: .fresh))
        XCTAssertTrue(TelemetryDisplayState.matchesStaleFilter(48.5, liveFresh: true, isReplay: true, replayFreshness: .stale))
        XCTAssertTrue(TelemetryDisplayState.matchesStaleFilter(0, liveFresh: false, isReplay: false, replayFreshness: nil))
    }
    func testGPSRetainsDistinctMissingStaleFreshAndRecordedMeanings() {
        XCTAssertEqual(TelemetryDisplayState.gpsLabel(hasSample: false, isReplay: false, age: nil), "NO FIX")
        XCTAssertEqual(TelemetryDisplayState.gpsLabel(hasSample: true, isReplay: false, age: 0), "FRESH FIX")
        XCTAssertEqual(TelemetryDisplayState.gpsLabel(hasSample: true, isReplay: false, age: 10), "STALE FIX")
        XCTAssertEqual(TelemetryDisplayState.gpsLabel(hasSample: true, isReplay: true, age: 0), "RECORDED FIX")
        XCTAssertEqual(TelemetryDisplayState.gpsLabel(hasSample: true, isReplay: true, age: 10), "RECORDED FIX")
        XCTAssertEqual(TelemetryDisplayState.gpsLabel(hasSample: false, isReplay: true, age: nil), "NO RECORDED FIX")
    }
    func testGPSWithUnusableAgeCannotClaimFreshness() {
        XCTAssertEqual(TelemetryDisplayState.gpsLabel(hasSample: true, isReplay: false, age: .nan), "AGE UNKNOWN")
        XCTAssertEqual(TelemetryDisplayState.gpsLabel(hasSample: true, isReplay: false, age: -.infinity), "AGE UNKNOWN")
        XCTAssertEqual(TelemetryDisplayState.gpsLabel(hasSample: true, isReplay: false, age: -0.5), "AGE UNKNOWN")
        XCTAssertEqual(TelemetryDisplayState.gpsLabel(hasSample: true, isReplay: false, age: nil), "AGE UNKNOWN")
    }
    func testMissingAndHistoricalConditionEvaluationCannotBecomeClear() {
        XCTAssertEqual(TelemetryDisplayState.conditionLabel(isReplay: true, evaluatedActive: nil, fresh: true), "NOT EVALUATED")
        XCTAssertEqual(TelemetryDisplayState.conditionLabel(isReplay: true, evaluatedActive: false, fresh: true), "NOT EVALUATED")
        XCTAssertEqual(TelemetryDisplayState.conditionLabel(isReplay: false, evaluatedActive: nil, fresh: true), "NOT EVALUATED")
        XCTAssertEqual(TelemetryDisplayState.conditionLabel(isReplay: false, evaluatedActive: false, fresh: true), "CLEAR")
        XCTAssertEqual(TelemetryDisplayState.conditionLabel(isReplay: false, evaluatedActive: true, fresh: false), "STALE")
    }

}
