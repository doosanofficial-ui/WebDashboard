import Foundation
import XCTest
@testable import TelemetryCore

final class ProtocolReuseAdvisoryTests: XCTestCase {
    typealias P = ProtocolReuseAdvisory
    func binding(profile: String = "full-profile", transport: String = "observed-endpoint",
                 vehicle: String = "selected-context", proto: String = "observed-protocol",
                 session: String = "session-a", generation: UInt64? = 4,
                 clock: String = "epoch-a") -> P.Binding {
        P.Binding(profileSnapshot: Data(profile.utf8), transportFingerprint: transport,
                  vehicleContext: vehicle, protocolEvidence: proto, sessionID: session,
                  generation: generation, clockEpoch: clock)
    }
    func observation(_ b: P.Binding? = nil, at: UInt64 = 100, verified: Bool = true) -> P.Observation {
        P.Observation(binding: b ?? binding(), observedAtMonotonicNanos: at,
                      isVerifiedNegotiatedObservation: verified)
    }
    func request(_ b: P.Binding? = nil, now: UInt64 = 110, age: UInt64 = 30,
                 reset: Bool? = false, error: Bool? = false, ambiguity: Bool? = false) -> P.Request {
        P.Request(binding: b ?? binding(), nowMonotonicNanos: now, maximumAgeNanos: age,
                  resetSinceObservation: reset, errorSinceObservation: error,
                  ambiguitySinceObservation: ambiguity)
    }
    func testMatchingIsOnlyAdvisory() {
        let d = P.evaluate(observation(), request: request())
        XCTAssertEqual(d.reason, .candidateRequiresFreshVerification)
        XCTAssertTrue(d.requiresFullInitialization)
        XCTAssertTrue(d.requiresFreshVerificationBeforeOptimization)
        XCTAssertFalse(d.authorizesOptimization)
    }
    func testMissing() {
        XCTAssertEqual(P.evaluate(nil, request: request()).reason, .missingObservation)
    }
    func testEachBindingMismatch() {
        for b in [binding(profile: "changed"), binding(transport: "other"), binding(vehicle: "other"),
                  binding(proto: "other"), binding(session: "other"), binding(generation: 5), binding(clock: "other")] {
            XCTAssertEqual(P.evaluate(observation(), request: request(b)).reason, .bindingMismatch)
        }
    }
    func testEachUnknownBinding() {
        for b in [binding(profile: ""), binding(transport: ""), binding(vehicle: " "),
                  binding(proto: ""), binding(session: ""), binding(generation: nil), binding(clock: "")] {
            XCTAssertEqual(P.evaluate(observation(b), request: request(b)).reason, .unknownBinding)
        }
    }
    func testUnverified() {
        XCTAssertEqual(P.evaluate(observation(verified: false), request: request()).reason, .unverifiedObservation)
    }
    func testAllHazardsAndUnknownsInvalidate() {
        for r in [request(reset: true), request(reset: nil), request(error: true), request(error: nil),
                  request(ambiguity: true), request(ambiguity: nil)] {
            XCTAssertEqual(P.evaluate(observation(), request: r).reason, .invalidated)
        }
    }
    func testDefaultHazardsFailClosed() {
        let r = P.Request(binding: binding(), nowMonotonicNanos: 110, maximumAgeNanos: 30)
        XCTAssertEqual(P.evaluate(observation(), request: r).reason, .invalidated)
    }
    func testExpiryBoundaryAndRollback() {
        XCTAssertEqual(P.evaluate(observation(), request: request(now: 130)).reason, .candidateRequiresFreshVerification)
        XCTAssertEqual(P.evaluate(observation(), request: request(now: 131)).reason, .stale)
        XCTAssertEqual(P.evaluate(observation(), request: request(now: 99)).reason, .invalidTime)
        XCTAssertEqual(P.evaluate(observation(), request: request(age: 0)).reason, .invalidTime)
    }
    func testMaximumTimestampDoesNotOverflow() {
        XCTAssertEqual(P.evaluate(observation(at: UInt64.max - 1),
                                  request: request(now: UInt64.max, age: 1)).reason, .candidateRequiresFreshVerification)
    }
    func testProtocolCaseDifferenceIsMismatch() {
        XCTAssertEqual(P.evaluate(observation(), request: request(binding(proto: "OBSERVED-PROTOCOL"))).reason, .bindingMismatch)
    }
    func testFailuresStillRequireCanonicalStartup() {
        for d in [P.evaluate(nil, request: request()), P.evaluate(observation(), request: request(reset: true)),
                  P.evaluate(observation(), request: request(now: 500))] {
            XCTAssertTrue(d.requiresFullInitialization)
            XCTAssertTrue(d.requiresFreshVerificationBeforeOptimization)
            XCTAssertFalse(d.authorizesOptimization)
        }
    }
}
