import Foundation
import XCTest
import TelemetryCore
@testable import TelemetryLifecycleHost

@MainActor
final class RateChangeRegressionTests: XCTestCase {
    func testRateChangesDuringPendingTickRetainLatestSpeedAndRecordedPosition() async throws {
        let gate = RateTickGate()
        let sample = DecodedSignalSample(signalID: "synthetic.soc", value: 53, rawValue: 106,
            enumName: nil, unit: "%", frameSequence: 1, receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 0, source: .demo)
        let saved = MeasurementExport(session: PersistedMeasurementSession(sessionID: "rate-race",
            startedAt: 100, endedAt: 700, mode: .demo), measurements: [
                PersistedMeasurement(sequence: 1, sessionID: "rate-race", kind: "SIGNAL",
                    sourceTimestamp: 100, receivedAtEpoch: 100, receivedAtMonotonicNanos: 0,
                    payloadJSON: String(decoding: try JSONEncoder().encode(sample), as: UTF8.self)),
                PersistedMeasurement(sequence: 2, sessionID: "rate-race", kind: "SYSTEM",
                    sourceTimestamp: 700, receivedAtEpoch: 700, receivedAtMonotonicNanos: 600_000_000_000,
                    payloadJSON: "{\"name\":\"recording_stopped\"}")])
        let c = ReplayController(snapshotProvider: { timeline, position in
            if position == 4 { await gate.hold() }
            return try await timeline.snapshot(at: position)
        })
        _ = try await c.load(sessionID: "rate-race") { saved }
        _ = try await c.seek(at: 0)
        XCTAssertTrue(c.play(at: 100))
        let old = Task { @MainActor in try await c.advancePlayback(at: 104) }
        await gate.waitForArrival()
        XCTAssertTrue(c.setPlaybackRate(2, at: 105))
        XCTAssertTrue(c.setPlaybackRate(0.5, at: 106))
        XCTAssertTrue(c.setPlaybackRate(2, at: 107))
        await gate.finish()
        let obsolete = try await old.value
        XCTAssertNil(obsolete)
        XCTAssertEqual(c.playbackRate, 2)
        XCTAssertEqual(c.position, 0, "An obsolete tick must not publish its old position")
        _ = try await c.advancePlayback(at: 108)
        XCTAssertEqual(c.position, 9.5, "5s at1x +1s at2x +1s at0.5x +1s at2x")
        XCTAssertTrue(c.isPlaying)
        XCTAssertEqual(c.snapshot?.signals.first?.receivedAtEpoch, 100)
        XCTAssertEqual(c.snapshot?.signals.first?.value, 53)
        XCTAssertFalse(c.setPlaybackRate(0.5, at: 107))
        XCTAssertEqual(c.playbackRate, 2)
        c.stop()
    }
}

private actor RateTickGate {
    private var entered = false
    private var release: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { continuation in
            entered = true
            release = continuation
            arrival?.resume()
            arrival = nil
        }
    }
    func waitForArrival() async {
        guard !entered else { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func finish() { release?.resume(); release = nil }
}
