import Foundation
import XCTest
@testable import TelemetryCore

// UNRUN: Swift compilation and execution deferred by user instruction.
final class AppearanceSchedulePolicyTests: XCTestCase {
    typealias P = AppearanceSchedulePolicy
    private func minute(_ text: String) -> Int {
        Int(ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970 / 60)
    }
    private func result(_ time: String, day: Int = 420, night: Int = 1140,
                        zone: String = "UTC") -> P.Decision {
        P.decide(selectedThemeID: "slateDark", systemPhase: .dark,
                 mode: .scheduled(dayMinute: day, nightMinute: night),
                 epochMinute: minute(time), timeZoneIdentifier: zone)
    }
    func testDefaultPreservesExistingSelection() {
        let d = P.decide(selectedThemeID: "slateDark", systemPhase: .light)
        XCTAssertEqual(d.phase, .light); XCTAssertEqual(d.themeID, "slateDark")
        XCTAssertEqual(d.reason, .system); XCTAssertNil(d.nextBoundaryEpochMinute)
    }
    func testExplicitMappingAndManualIgnoreClock() {
        let d = P.decide(selectedThemeID: "slateDark", systemPhase: .dark,
                         mode: .manual(.light), timeZoneIdentifier: "invalid", lightThemeID: "paperLight")
        XCTAssertEqual(d.phase, .light); XCTAssertEqual(d.themeID, "paperLight")
        XCTAssertEqual(d.reason, .manual); XCTAssertNil(d.nextBoundaryEpochMinute)
        XCTAssertEqual(P.decide(selectedThemeID: "slateDark", systemPhase: .dark,
                                darkThemeID: "amberDark").themeID, "amberDark")
    }
    func testHalfOpenBounds() {
        for (time, phase, next) in [("06:59",P.Phase.dark,"07:00"), ("07:00",.light,"19:00"), ("18:59",.light,"19:00")] {
            let d = result("2026-11-04T\(time):00Z")
            XCTAssertEqual(d.phase, phase); XCTAssertEqual(d.reason, .scheduled)
            XCTAssertEqual(d.nextBoundaryEpochMinute, minute("2026-11-04T\(next):00Z"))
        }
    }
    func testReverseMidnightAndYearRollover() {
        let d = result("2026-12-31T23:59:00Z",day: 1200,night: 300)
        XCTAssertEqual(d.phase,.light)
        XCTAssertEqual(d.nextBoundaryEpochMinute, minute("2027-01-01T05:00:00Z"))
        XCTAssertEqual(result("2026-11-04T12:00:00Z",day: 0,night: 720).phase,.dark)
    }
    func testInvalidScheduleDoesNotApplyMappings() {
        for (day,night) in [(0,0),(-1,100),(0,1440),(Int.max,100)] {
            let d = P.decide(selectedThemeID: "slateDark", systemPhase: .dark,
                             mode: .scheduled(dayMinute: day,nightMinute: night),darkThemeID: "amberDark")
            XCTAssertEqual(d.reason,.invalidSchedule); XCTAssertEqual(d.themeID,"slateDark")
            XCTAssertNil(d.nextBoundaryEpochMinute)
        }
    }
    func testInvalidClock() {
        let clocks: [Int?] = [nil,Int.min,Int.max,P.minimumEpochMinute-1,P.exclusiveMaximumEpochMinute]
        for now in clocks {
            let d = P.decide(selectedThemeID:"slateDark",systemPhase:.dark,
                             mode:.scheduled(dayMinute:420,nightMinute:1140),epochMinute:now)
            XCTAssertEqual(d.reason,.invalidClock); XCTAssertNil(d.nextBoundaryEpochMinute)
        }
        XCTAssertEqual(result("2026-11-04T12:00:00Z",zone:"invalid").reason,.invalidClock)
    }
    func testSpringGapAndEntireSkippedWindow() {
        XCTAssertEqual(result("2026-03-08T01:59:00-05:00",day:150,zone:"America/New_York").nextBoundaryEpochMinute,
                       minute("2026-03-08T03:00:00-04:00"))
        XCTAssertEqual(result("2026-03-08T01:59:00-05:00",day:130,night:160,zone:"America/New_York").nextBoundaryEpochMinute,
                       minute("2026-03-09T02:10:00-04:00"))
    }
    func testNonHourDSTAndSkippedLocalDate() {
        XCTAssertEqual(result("2026-10-04T01:59:00+10:30",day:135,zone:"Australia/Lord_Howe").nextBoundaryEpochMinute,
                       minute("2026-10-04T02:30:00+11:00"))
        XCTAssertEqual(result("2011-12-29T23:59:00-10:00",zone:"Pacific/Apia").nextBoundaryEpochMinute,
                       minute("2011-12-31T07:00:00+14:00"))
        XCTAssertEqual(result("2028-02-29T23:59:00Z").nextBoundaryEpochMinute,
                       minute("2028-03-01T07:00:00Z"))
    }
    func testFallClockReversalCanChangePhaseTwice() {
        XCTAssertEqual(result("2026-11-01T01:45:00-04:00",day:90,night:180,zone:"America/New_York").nextBoundaryEpochMinute,
                       minute("2026-11-01T01:00:00-05:00"))
        XCTAssertEqual(result("2026-11-01T01:00:00-05:00",day:90,night:180,zone:"America/New_York").nextBoundaryEpochMinute,
                       minute("2026-11-01T01:30:00-05:00"))
    }
    func testNonHourZoneAndZoneChange() {
        XCTAssertEqual(result("2026-11-04T06:59:00+05:45",zone:"Asia/Kathmandu").nextBoundaryEpochMinute,
                       minute("2026-11-04T07:00:00+05:45"))
        XCTAssertNotEqual(result("2026-11-04T12:00:00Z",zone:"Pacific/Auckland").phase,
                          result("2026-11-04T12:00:00Z").phase)
    }
    func testRangeEndNoBoundary() {
        XCTAssertNil(result("2099-12-31T23:59:00Z").nextBoundaryEpochMinute)
    }
}
