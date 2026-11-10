import XCTest
@testable import TelemetryCore

final class PlaceSearchPreparationTests: XCTestCase {
    typealias Search = PlaceSearchPreparation
    typealias Row = Search.Suggestion
    func ready() -> Search { var s = Search(); s.configure(enabled: true, provider: "provider", authorized: true); return s }
    func request(_ s: inout Search, _ query: String = "서울 카페", at now: Int64 = 0) throws -> Search.Token {
        XCTAssertTrue(s.edit(query, at: now, userInitiated: true))
        return try XCTUnwrap(s.poll(at: now + 300))
    }
    func testDisabledAndPermission() {
        var s = Search(); XCTAssertTrue(s.edit("cafe", at: 0, userInitiated: true)); XCTAssertNil(s.poll(at: 1000))
        s.configure(enabled: true, provider: "provider", authorized: false)
        XCTAssertTrue(s.edit("cafe", at: 1000, userInitiated: true)); XCTAssertNil(s.poll(at: 2000))
    }
    func testExplicitEditAndDebounce() {
        var s = ready(); XCTAssertFalse(s.edit("cafe", at: 0, userInitiated: false)); XCTAssertNil(s.poll(at: 500))
        XCTAssertTrue(s.edit("cafe", at: 500, userInitiated: true)); XCTAssertNil(s.poll(at: 799)); XCTAssertNotNil(s.poll(at: 800)); XCTAssertNil(s.poll(at: 900))
    }
    func testRateLimitSurvivesCancel() throws {
        var s = ready(); _ = try request(&s); s.cancel()
        XCTAssertTrue(s.edit("shop", at: 400, userInitiated: true)); XCTAssertNil(s.poll(at: 700)); XCTAssertNotNil(s.poll(at: 1300))
    }
    func testLateAndDuplicateResponse() throws {
        var s = ready(); let old = try request(&s); let new = try request(&s, "shop", at: 1300)
        XCTAssertFalse(s.receive(old, rows: [Row(id: "x", label: "Old")]))
        XCTAssertTrue(s.receive(new, rows: [Row(id: "y", label: "New")]))
        XCTAssertFalse(s.receive(new, rows: [Row(id: "z", label: "Again")]))
        XCTAssertEqual(s.results, [Row(id: "y", label: "New")])
    }
    func testExactSelection() throws {
        var s = ready(); let t = try request(&s); XCTAssertTrue(s.receive(t, rows: [Row(id: "a", label: "서울 카페")]))
        XCTAssertNil(s.select(.init(generation: t.generation + 1, provider: t.provider), resultID: "a"))
        XCTAssertNil(s.select(t, resultID: "missing")); XCTAssertEqual(s.select(t, resultID: "a")?.token, t)
        XCTAssertTrue(s.edit("new", at: 1000, userInitiated: true)); XCTAssertNil(s.select(t, resultID: "a"))
    }
    func testReconfigurationInvalidates() throws {
        for (enabled, provider, authorized) in [(false,"provider",true),(true,"provider",false),(true,"other",true)] {
            var s = ready(); let t = try request(&s); s.configure(enabled: enabled, provider: provider, authorized: authorized)
            XCTAssertFalse(s.receive(t, rows: [Row(id: "a", label: "old")])); XCTAssertNil(s.poll(at: 2000))
        }
    }
    func testInvalidQueryClearsEvidence() throws {
        for q in ["", "   ", String(repeating:"x", count:129),String(repeating:"😀", count:129),"a\nq","a\u{202E}q"] {
            var s = ready(); let t = try request(&s); XCTAssertTrue(s.receive(t, rows: [Row(id: "a", label: "ok")]))
            XCTAssertFalse(s.edit(q, at: 1000, userInitiated: true)); XCTAssertTrue(s.results.isEmpty)
            XCTAssertNil(s.select(t, resultID: "a")); XCTAssertNil(s.poll(at: 2000))
        }
    }
    func testUnicodeBoundaries() throws {
        var s = ready(); let t = try request(&s, String(repeating:"😀", count:128))
        XCTAssertTrue(s.receive(t, rows:[Row(id:"a", label:"한글😀")]))
        XCTAssertEqual(s.results.first?.label,"한글😀")
    }
    func testAtomicValidation() throws {
        let cases = [[Row(id:"x",label:"ok"),Row(id:"x",label:"dup")], [Row(id:"x",label:String(repeating:"a",count:257))], [Row(id:"https://bad",label:"bad")], [Row(id:"x",label:"\u{2066}bad")], (0..<11).map { Row(id:String($0), label:"ok") }]
        for rows in cases {
            var s = ready(); let t = try request(&s); XCTAssertFalse(s.receive(t, rows:rows)); XCTAssertTrue(s.results.isEmpty); XCTAssertTrue(s.receive(t, rows:[]))
        }
    }
    func testCancelAndFailure() throws {
        var s = ready(); let t = try request(&s); s.cancel(); XCTAssertFalse(s.receive(t, rows:[Row(id:"x",label:"old")]))
        let new = try request(&s,"new",at:1300); XCTAssertTrue(s.fail(new)); XCTAssertFalse(s.receive(new,rows:[])); XCTAssertNil(s.poll(at:5000))
    }
    func testClockRegressionAndBounds() {
        var s = ready(); XCTAssertFalse(s.edit("cafe",at:-1,userInitiated:true))
        XCTAssertFalse(s.edit("cafe",at:Search.maximum + 1,userInitiated:true))
        XCTAssertTrue(s.edit("cafe",at:100,userInitiated:true)); XCTAssertNil(s.poll(at:99)); XCTAssertNotNil(s.poll(at:400)); XCTAssertFalse(s.edit("old",at:399,userInitiated:true))
    }
    func testProviderValidation() {
        var s = Search(); s.configure(enabled:true,provider:"https://provider",authorized:true)
        XCTAssertTrue(s.edit("cafe",at:0,userInitiated:true)); XCTAssertNil(s.poll(at:1000))
    }
}
