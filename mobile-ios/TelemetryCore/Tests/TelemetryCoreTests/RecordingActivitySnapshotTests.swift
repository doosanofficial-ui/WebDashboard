import XCTest
@testable import TelemetryCore

final class RecordingActivitySnapshotTests: XCTestCase {
    private func reading(_ value: Double? = 0, at: Double? = 101, timeout: Double = 3) -> RecordingActivitySnapshot.Input {
        .init(id: "coolant", name: "Coolant", unit: "C", value: value, receivedAt: at, timeout: timeout)
    }

    func testRealZeroIsPreservedAndEarliestExpiryWins() {
        let value = RecordingActivitySnapshot.make(selectedIDs: ["coolant", "rpm"], inputs: [reading(),
            .init(id: "rpm", name: "RPM", unit: "rpm", value: 1200, receivedAt: 102, timeout: 8)], startedAt: 100, now: 102)
        XCTAssertEqual(value.readings.map(\.value), ["0", "1200"])
        XCTAssertEqual(value.validUntil, 104)
        XCTAssertEqual(value.phase, .recording)
    }

    func testMissingStaleFutureInvalidAndPreSessionReadingsNeverBecomeZero() {
        for input in [reading(nil), reading(at: nil), reading(at: 98), reading(at: 105),
                      reading(at: 99.9, timeout: 20), reading(.nan), reading(.infinity),
                      reading(timeout: 0), reading(timeout: .nan), reading(at: .infinity)] {
            let value = RecordingActivitySnapshot.make(selectedIDs: ["coolant"], inputs: [input], startedAt: 100, now: 102)
            XCTAssertNil(value.readings.first?.value)
            XCTAssertLessThanOrEqual(value.validUntil, 117)
        }
    }

    func testSelectionIsExplicitUniqueBoundedAndUnselectedValuesNeverLeak() throws {
        let values = [reading(), .init(id: "private", name: "Private", unit: "secret", value: 777, receivedAt: 101, timeout: 3)]
        let empty = RecordingActivitySnapshot.make(selectedIDs: [], inputs: values, startedAt: 100, now: 102)
        XCTAssertTrue(empty.readings.isEmpty)
        let bounded = RecordingActivitySnapshot.make(selectedIDs: ["coolant", "coolant", "missing", "private"], inputs: values, startedAt: 100, now: 102)
        XCTAssertEqual(bounded.readings.count, 2)
        XCTAssertEqual(bounded.readings.first?.value, "0")
        XCTAssertNil(bounded.readings.last?.value)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(bounded), as: UTF8.self).contains("777"))
    }

    func testPayloadBoundsAndCodableRoundTrip() throws {
        let huge = "A" + String(repeating: "\u{0301}", count: 10000) + String(repeating: "🚘", count: 2000)
        let value = RecordingActivitySnapshot.make(selectedIDs: ["coolant"], inputs: [
            .init(id: "coolant", name: huge + "\n", unit: huge, value: Double.greatestFiniteMagnitude, receivedAt: 101, timeout: 3)
        ], startedAt: 100, now: 102)
        let data = try JSONEncoder().encode(value)
        XCTAssertLessThan(data.count, 2000)
        XCTAssertEqual(try JSONDecoder().decode(RecordingActivitySnapshot.self, from: data), value)
        XCTAssertFalse(value.readings[0].name.contains("\n"))
        XCTAssertLessThanOrEqual(value.readings[0].name.count, 32)
        XCTAssertLessThanOrEqual(value.readings[0].unit.count, 12)
    }

    func testTerminalSnapshotsDropAllValuesAndBadClockFailsClosed() throws {
        let stopped = RecordingActivitySnapshot.ended(at: 102, interrupted: false)
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertTrue(stopped.readings.isEmpty)
        XCTAssertEqual(RecordingActivitySnapshot.ended(at: 102, interrupted: true).phase, .interrupted)
        for now in [Double.nan, .infinity, -1] {
            let value = RecordingActivitySnapshot.make(selectedIDs: ["coolant"], inputs: [reading()], startedAt: 100, now: now)
            XCTAssertTrue(value.readings.allSatisfy { $0.value == nil })
            XCTAssertNoThrow(try JSONEncoder().encode(value))
        }
    }

    func testSessionGenerationRejectsLateWorkAndNeverRecreatesDismissedSession() throws {
        var lifecycle = RecordingActivityLifecycle()
        XCTAssertNil(lifecycle.begin(sessionID: "disabled", enabled: false, foreground: true, mode: .live))
        XCTAssertNil(lifecycle.begin(sessionID: "disabled", enabled: true, foreground: true, mode: .live))
        XCTAssertNil(lifecycle.begin(sessionID: "background", enabled: true, foreground: false, mode: .live))
        XCTAssertNil(lifecycle.begin(sessionID: "replay", enabled: true, foreground: true, mode: .replay))
        let first = try XCTUnwrap(lifecycle.begin(sessionID: "first", enabled: true, foreground: true, mode: .demo))
        XCTAssertTrue(lifecycle.isCurrent(first))
        lifecycle.end()
        XCTAssertFalse(lifecycle.isCurrent(first))
        XCTAssertNil(lifecycle.begin(sessionID: "first", enabled: true, foreground: true, mode: .demo))
        let next = try XCTUnwrap(lifecycle.begin(sessionID: "next", enabled: true, foreground: true, mode: .live))
        XCTAssertFalse(lifecycle.isCurrent(first))
        XCTAssertTrue(lifecycle.isCurrent(next))
    }
}
