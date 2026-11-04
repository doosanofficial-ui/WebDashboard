import XCTest
@testable import TelemetryCore

final class OfflineFuelCalibrationTests: XCTestCase {
    private typealias C = OfflineFuelCalibration
    private func evidence(verified: Bool = true, end: Double = 300,
                          measured: Double = 32, complete: Bool = true) -> C.Evidence {
        let context = C.Context(vehicleID: "v", tankID: "t", epochID: "e", timelineID: "clock", rawSourceID: "raw")
        return .init(adapterID: "synthetic-adapter", proofReference: "synthetic-proof", externallyVerified: verified,
            context: context, claims: .init(postFillAnchors: true, completeHistory: complete,
                completeCoverage: true, compatibleUnadjustedConsumedLiters: true, originalProvenance: true),
            fills: [.init(id: "a", postFillSeconds: 100, litersAdded: nil, full: true, completeSincePrevious: false),
                    .init(id: "b", postFillSeconds: 200, litersAdded: 10, full: false, completeSincePrevious: true),
                    .init(id: "c", postFillSeconds: 300, litersAdded: 30, full: true, completeSincePrevious: true)],
            pieces: [.init(id: "p", originalProofReference: "original:0", startSeconds: 100,
                           endSeconds: end, consumedLiters: measured)],
            reviewerMinimumFactor: 0.5, reviewerMaximumFactor: 2)
    }
    func testDefaultUnavailable() { XCTAssertNil(C.propose()) }
    func testProposalRetainsOriginalEvidence() throws {
        let e = evidence(); let p = try XCTUnwrap(C.propose(e))
        XCTAssertEqual(p.factor, 1.25); XCTAssertEqual(p.referenceLiters, 40)
        XCTAssertEqual(p.measuredLiters, 32); XCTAssertEqual(p.evidence, e)
    }
    func testUnverifiedAndIncompleteStayUnavailable() {
        XCTAssertNil(C.propose(evidence(verified: false)))
        XCTAssertNil(C.propose(evidence(complete: false)))
    }
    func testCoverageMustEndExactlyAtAnchor() {
        XCTAssertNil(C.propose(evidence(end: 299)))
        XCTAssertNil(C.propose(evidence(end: 301)))
    }
    func testInvalidMeasuredVolumesStayUnavailable() {
        for value in [0, -1, Double.nan, .infinity, .leastNonzeroMagnitude, .greatestFiniteMagnitude] {
            XCTAssertNil(C.propose(evidence(measured: value)))
        }
    }
}
