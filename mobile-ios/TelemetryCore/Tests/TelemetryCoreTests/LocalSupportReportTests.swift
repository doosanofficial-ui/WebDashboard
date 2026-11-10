import Foundation
import XCTest
@testable import TelemetryCore
final class LocalSupportReportTests: XCTestCase {
    private func fixture() throws -> LocalSupportReport {
        try LocalSupportReport(appVersion: [1,2,3], osVersion: [18,0], platform: .iOS,
            transport: .ble, state: .connected,
            counters: SupportCounters(requests: 4, succeeded: 1, failed: 1, cancelled: 1, pending: 1),
            latency: SupportLatency(samples: 2, minimumMs: 0, meanMs: 15, maximumMs: 30))
    }
    private func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixture().jsonData()) as? [String: Any])
    }
    private func decode(_ object: [String: Any]) throws -> LocalSupportReport {
        try JSONDecoder().decode(LocalSupportReport.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testDeterministicAllowlistAndRoundTrip() throws {
        let a = try fixture()
        XCTAssertEqual(try a.jsonData(), try a.jsonData())
        XCTAssertEqual(try JSONDecoder().decode(LocalSupportReport.self, from: a.jsonData()), a)
        XCTAssertEqual(Set(try object().keys), Set(["appVersion","osVersion","platform","transport","state","counters","latency","schemaVersion","scope","disclosure","allowsRemoteDelivery"]))
        XCTAssertEqual(a.schemaVersion, 1); XCTAssertFalse(a.allowsRemoteDelivery)
        XCTAssertEqual(a.scope,"localAggregateOnly")
        XCTAssertEqual(a.disclosure,"versionsConnectionStateAndCountersOnly")
    }
    func testUnavailableIsNotZero() throws {
        let a = try LocalSupportReport(appVersion: [1,0], osVersion: [18,0], platform: .iOS,
            transport: .none, state: .disconnected, counters: nil, latency: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: a.jsonData()) as? [String: Any])
        XCTAssertTrue(obj["counters"] is NSNull); XCTAssertTrue(obj["latency"] is NSNull)
        let zero = try SupportCounters(requests: 0, succeeded: 0, failed: 0, cancelled: 0, pending: 0)
        XCTAssertEqual(zero.requests,0)
    }
    func testInvalidCountersAndOverflow() throws {
        for value in [Int64(-1), 1_000_000_001, Int64.max] {
            XCTAssertThrowsError(try SupportCounters(requests: value, succeeded: value, failed: 0, cancelled: 0, pending: 0))
        }
        XCTAssertThrowsError(try SupportCounters(requests: 4, succeeded: 1, failed: 1, cancelled: 1, pending: 2))
        for value in [true, 0.1, "1"] as [Any] {
            var a = try object(); var c = try XCTUnwrap(a["counters"] as? [String: Any]); c["requests"] = value; a["counters"] = c
            XCTAssertThrowsError(try decode(a))
        }
    }
    func testInvalidLatencyAndCoverage() throws {
        for value in [Double.nan, Double.infinity, -1, 86_400_001] {
            XCTAssertThrowsError(try SupportLatency(samples: 2, minimumMs: 0, meanMs: value, maximumMs: 30))
        }
        XCTAssertThrowsError(try SupportLatency(samples: 1, minimumMs: 0, meanMs: 15, maximumMs: 30))
        XCTAssertThrowsError(try SupportLatency(samples: 0, minimumMs: 0, meanMs: 15, maximumMs: 30))
        XCTAssertThrowsError(try SupportLatency(samples: 2, minimumMs: 16, meanMs: 15, maximumMs: 30))
        XCTAssertThrowsError(try SupportLatency(samples: 2, minimumMs: 0, meanMs: 15, maximumMs: 14))
        var a = try object(); a["counters"] = NSNull()
        XCTAssertThrowsError(try decode(a))
        a = try object(); var latency = try XCTUnwrap(a["latency"] as? [String: Any]); latency["samples"] = 5; a["latency"] = latency
        XCTAssertThrowsError(try decode(a))
    }
    func testPrivacyInjectionRejectedAtAllLevels() throws {
        let secrets = ["1HGCM82633A004352","51.5074,-0.1278","AA:BB:CC:DD:EE:FF","192.168.1.1","secret-token","https://private.example","raw frame 7E8","personal note"]
        for secret in secrets {
            for field in ["platform","transport","state","appVersion","osVersion"] {
                var a = try object(); a[field] = secret; XCTAssertThrowsError(try decode(a))
            }
            var a = try object(); a["private"] = secret; XCTAssertThrowsError(try decode(a))
            for field in ["counters","latency"] {
                a = try object(); var nested = try XCTUnwrap(a[field] as? [String: Any]); nested["private"] = secret; a[field] = nested
                XCTAssertThrowsError(try decode(a))
            }
        }
    }
    func testInvalidVersions() throws {
        for value in [[],[1],[1,2,3,4],[-1,0],[65536,0]] {
            XCTAssertThrowsError(try LocalSupportReport(appVersion: value, osVersion: [18,0], platform: .iOS,
                transport: .none, state: .disconnected, counters: nil, latency: nil))
        }
    }
    func testMissingFieldsAndPolicyOverridesRejected() throws {
        let original = try object()
        for key in original.keys {
            var a = original; a.removeValue(forKey: key); XCTAssertThrowsError(try decode(a))
        }
        for key in ["scope","disclosure","schemaVersion","allowsRemoteDelivery"] {
            var a = original; a[key] = "override"; XCTAssertThrowsError(try decode(a))
        }
        var a = original; a["allowsRemoteDelivery"] = true; XCTAssertThrowsError(try decode(a))
    }
}
