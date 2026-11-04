import XCTest
@testable import TelemetryCore

// Prepared only. Swift compiler and XCTest have NOT been run.
final class UpdateNoticePolicyTests: XCTestCase {
    typealias P = UpdateNoticePolicy
    let identity = P.Identity(app: "app-1", bundle: "com.example.car", channel: .appStore, store: "store-1")
    let token = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    func metadata(version: String = "1.3.0", generation: UInt64 = 2,
                  identity: P.Identity? = nil, destinationIdentity: P.Identity? = nil,
                  destinationVersion: String? = nil, issued: UInt64 = 100,
                  expires: UInt64 = 200, schema: String = "releaseTripleV1") -> P.Metadata {
        P.Metadata(identity: identity ?? self.identity, schema: schema, version: version,
                   generation: generation, issuedAt: issued, expiresAt: expires,
                   destination: P.VerifiedDestinationReference(opaqueID: token,
                       identity: destinationIdentity ?? self.identity,
                       version: destinationVersion ?? version))
    }
    func evaluate(_ data: P.Metadata? = nil, current: String = "1.2.3",
                  generation: UInt64 = 2, cancelled: Bool = false, manual: Bool = true,
                  now: UInt64 = 150, motion: P.Motion = .parked,
                  preferences: P.Preferences = .init(noticesEnabled: true)) -> P.Result {
        P.evaluate(installedIdentity: identity, installedVersion: current,
                   metadata: data ?? metadata(), request: .init(generation: generation,
                     userInitiated: manual, cancelled: cancelled),
                   now: now, motion: motion, preferences: preferences)
    }
    func testAvailableCarriesOnlyOpaqueReference() {
        XCTAssertEqual(evaluate(), .available(version: P.ReleaseVersion("1.3.0")!, destination: metadata().destination))
    }
    func testStrictVersionSchemaAndNumericOrdering() {
        for value in ["", "1", "1.2", "1.2.3.4", "1.02.3", "1.2.3-beta", "1.2.3+4", "１.2.3", " 1.2.3", "1.2.-1", "1000000.0.0", String(repeating: "9", count: 10000)] {
            XCTAssertNil(P.ReleaseVersion(value), value)
        }
        XCTAssertNotNil(P.ReleaseVersion("999999.0.1"))
        XCTAssertNotNil(P.ReleaseVersion("0.0.0"))
        XCTAssertTrue(P.ReleaseVersion("1.9.0")! < P.ReleaseVersion("1.10.0")!)
        XCTAssertEqual(evaluate(metadata(schema: "semver")), .rejected)
        XCTAssertEqual(evaluate(current: "v1.0.0"), .rejected)
        XCTAssertEqual(evaluate(metadata(version: "1.2")), .rejected)
    }
    func testEqualOlderAndSameMarketingVersionDoNotNotify() {
        for version in ["1.2.3", "1.2.2", "0.9.9"] {
            XCTAssertEqual(evaluate(metadata(version: version)), .noUpdate)
        }
    }
    func testExactIdentityForMetadataAndDestination() {
        let wrong = [
            P.Identity(app: "app-2", bundle: identity.bundle, channel: .appStore, store: identity.store),
            P.Identity(app: identity.app, bundle: "com.example.other", channel: .appStore, store: identity.store),
            P.Identity(app: identity.app, bundle: identity.bundle, channel: .testFlight, store: identity.store),
            P.Identity(app: identity.app, bundle: identity.bundle, channel: .appStore, store: "store-2")]
        for id in wrong {
            XCTAssertEqual(evaluate(metadata(identity: id)), .rejected)
            XCTAssertEqual(evaluate(metadata(destinationIdentity: id)), .rejected)
        }
        XCTAssertEqual(evaluate(metadata(destinationVersion: "1.4.0")), .rejected)
        XCTAssertFalse(P.Identity(app: "", bundle: identity.bundle, channel: .appStore, store: identity.store).isValid)
        XCTAssertFalse(P.Identity(app: "https://example.com", bundle: identity.bundle, channel: .appStore, store: identity.store).isValid)
    }
    func testGenerationCancellationAndManualOnly() {
        XCTAssertEqual(evaluate(generation: 3), .rejected)
        XCTAssertEqual(evaluate(metadata(generation: 0), generation: 0), .rejected)
        XCTAssertEqual(evaluate(cancelled: true), .rejected)
        XCTAssertEqual(evaluate(manual: false), .rejected)
    }
    func testFreshnessAndExclusiveExpiry() {
        XCTAssertEqual(evaluate(now: 99), .rejected)
        XCTAssertEqual(evaluate(now: 200), .rejected)
        XCTAssertEqual(evaluate(metadata(expires: 100)), .rejected)
        XCTAssertEqual(evaluate(metadata(expires: 86501)), .rejected)
        XCTAssertEqual(evaluate(metadata(issued: UInt64.max, expires: 0)), .rejected)
        XCTAssertEqual(evaluate(now: 100), evaluate())
        XCTAssertEqual(evaluate(now: 199), evaluate())
    }
    func testDrivingAndUnknownAreDeferredWithoutDestination() {
        XCTAssertEqual(evaluate(motion: .driving), .deferred)
        XCTAssertEqual(evaluate(motion: .unknown), .deferred)
    }
    func testExplicitPreferencesSkipAndReset() {
        var preferences = P.Preferences()
        XCTAssertFalse(preferences.noticesEnabled)
        XCTAssertFalse(P.automaticChecksAllowed)
        XCTAssertFalse(P.automaticInstallationAllowed)
        XCTAssertEqual(evaluate(preferences: preferences), .suppressed)
        preferences.noticesEnabled = true
        XCTAssertTrue(preferences.skip(identity: identity, version: "1.3.0"))
        XCTAssertEqual(evaluate(preferences: preferences), .suppressed)
        XCTAssertFalse(preferences.skip(identity: identity, version: "invalid"))
        XCTAssertEqual(evaluate(preferences: preferences), .suppressed) // Invalid input preserves existing choice.
        preferences.resetSkippedVersion()
        XCTAssertEqual(evaluate(preferences: preferences), evaluate())
        XCTAssertTrue(preferences.skip(identity: identity, version: "1.2.9"))
        XCTAssertEqual(evaluate(preferences: preferences), evaluate())
        let other = P.Identity(app: identity.app, bundle: identity.bundle, channel: .testFlight, store: identity.store)
        XCTAssertTrue(preferences.skip(identity: other, version: "1.3.0"))
        XCTAssertEqual(evaluate(preferences: preferences), evaluate())
    }
}
