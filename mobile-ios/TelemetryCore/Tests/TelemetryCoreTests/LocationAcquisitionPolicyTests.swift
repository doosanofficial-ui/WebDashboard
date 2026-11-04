import XCTest
@testable import TelemetryCore

final class LocationAcquisitionPolicyTests: XCTestCase {
    func evidence(_ t: Double, speed: Double = 0, accuracy: Double = 3,
                  motionTime: Double? = nil, original: Bool = true) -> LocationPolicyEvidence {
        .init(scope: "live", generation: 1, producer: "native", time: t,
              speed: speed, speedAccuracy: 0.1, horizontalAccuracy: accuracy,
              motion: .low, confidence: 0.99, original: original,
              motionTime: motionTime ?? t, qualityAccepted: true)
    }
    let inactive = LocationPolicyRequirements(recording: .inactive, navigation: .inactive, critical: .inactive)
    func armed() -> LocationAcquisitionPolicy {
        var p = LocationAcquisitionPolicy(scope: "live", generation: 1, producer: "native")
        XCTAssertTrue(p.arm(epoch: 1, now: 0, permission: true)); return p
    }
    func settle(_ p: inout LocationAcquisitionPolicy) {
        for t in stride(from: 0.0, through: 30.0, by: 2) {
            let d = p.evaluate(now: t, evidence: evidence(t), requirements: inactive, permission: true, epoch: 1)
            XCTAssertEqual(d.profile, t == 30 ? .lowMotionAdvisory : .preserve)
        }
    }
    func testDefaultAndUnknownRequirementsPreserve() {
        var p = LocationAcquisitionPolicy(scope: "live", generation: 1, producer: "native")
        XCTAssertEqual(p.evaluate(now: 0, evidence: evidence(0), requirements: inactive, permission: true, epoch: 0).profile, .preserve)
        p = armed(); settle(&p)
        XCTAssertEqual(p.evaluate(now: 32, evidence: evidence(32), requirements: .init(), permission: true, epoch: 1).profile, .preserve)
    }
    func testDwellBoundsAndHysteresis() {
        var p = armed(); settle(&p)
        let d = p.evaluate(now: 32, evidence: evidence(32, speed: 0.8), requirements: inactive, permission: true, epoch: 1)
        XCTAssertEqual(d.profile, .lowMotionAdvisory)
        XCTAssertEqual(d.maximumInterval, 2); XCTAssertEqual(d.distance, 5)
        XCTAssertEqual(d.accuracy, 10); XCTAssertEqual(d.expires, 34)
        XCTAssertEqual(p.evaluate(now: 34, evidence: evidence(34, speed: 1.4), requirements: inactive, permission: true, epoch: 1).profile, .preserve)
        XCTAssertEqual(p.evaluate(now: 36, evidence: evidence(36, speed: 0.8), requirements: inactive, permission: true, epoch: 1).profile, .preserve)
    }
    func testRevokeRequiresFreshExplicitArming() {
        var p = armed(); settle(&p)
        _ = p.evaluate(now: 32, evidence: evidence(32), requirements: inactive, permission: false, epoch: 1)
        for t in stride(from: 34.0, through: 70.0, by: 2) {
            XCTAssertEqual(p.evaluate(now: t, evidence: evidence(t), requirements: inactive, permission: true, epoch: 1).profile, .preserve)
        }
        XCTAssertFalse(p.arm(epoch: 1, now: 70, permission: true))
        XCTAssertTrue(p.arm(epoch: 2, now: 70, permission: true))
    }
    func testClockRegressionAndNonfiniteFenceInstance() {
        for bad in [10.0, -.infinity, .nan] {
            var p = armed(); settle(&p)
            XCTAssertEqual(p.evaluate(now: bad, evidence: nil, requirements: inactive, permission: true, epoch: 1).profile, .preserve)
            XCTAssertFalse(p.arm(epoch: 2, now: 40, permission: true))
        }
    }
    func testInvalidMissingStaleAndDuplicateEvidence() {
        for e in [nil, evidence(32, accuracy: 11), evidence(29.9), evidence(32.1), evidence(32, speed: -1), evidence(32, speed: .nan), evidence(32, motionTime: 30), evidence(32, original: false)] as [LocationPolicyEvidence?] {
            var p = armed(); settle(&p)
            XCTAssertEqual(p.evaluate(now: 32, evidence: e, requirements: inactive, permission: true, epoch: 1).profile, .preserve)
        }
    }
    func testActiveRecordingNavigationAndCriticalUsePreserve() {
        for r in [LocationPolicyRequirements(recording: .active, navigation: .inactive, critical: .inactive), .init(recording: .inactive, navigation: .active, critical: .inactive), .init(recording: .inactive, navigation: .inactive, critical: .active)] {
            var p = armed(); settle(&p)
            XCTAssertEqual(p.evaluate(now: 32, evidence: evidence(32), requirements: r, permission: true, epoch: 1).profile, .preserve)
        }
    }
    func testGapAndDisarmClearDwell() {
        var p = armed(); settle(&p)
        XCTAssertEqual(p.evaluate(now: 36, evidence: evidence(36), requirements: inactive, permission: true, epoch: 1).profile, .preserve)
        p.disarm()
        XCTAssertEqual(p.evaluate(now: 38, evidence: evidence(38), requirements: inactive, permission: true, epoch: 1).profile, .preserve)
    }
}
