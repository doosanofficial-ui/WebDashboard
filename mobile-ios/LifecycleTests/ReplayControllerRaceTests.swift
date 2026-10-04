import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
import TelemetryCore
@testable import TelemetryLifecycleHost

/// Hosted tests. Fixtures contain invented measurements only; no device or disk access.
@MainActor
final class ReplayControllerRaceTests: XCTestCase {
    func testOlderLoadCannotReplaceNewerSession() async throws {
        let controller = ReplayController()
        let gate = ReplayGate()
        let a = try fixture("synthetic-A")
        let b = try fixture("synthetic-B", firstValue: 70)
        let old = Task { try await controller.load(sessionID: a.session.sessionID) {
            await gate.suspend()
            return a
        } }
        await gate.waitUntilEntered()
        _ = try await controller.load(sessionID: b.session.sessionID) { b }
        await gate.release()
        let oldResult = await old.result
        assertDiscarded(oldResult)
        XCTAssertEqual(controller.sessionID, b.session.sessionID)
        XCTAssertEqual(controller.snapshot?.signals.first?.value, 71)
        XCTAssertEqual(controller.recordedHistory(for: "soc")?.samples.map(\.value), [70, 71])
        XCTAssertTrue(controller.recordedHistory(for: "soc")?.samples.allSatisfy { $0.measurement.sessionID == b.session.sessionID } == true)
        XCTAssertEqual(controller.position, 4)
        XCTAssertFalse(controller.loading)
    }

    func testStopDuringLoadDiscardsLateResult() async throws {
        let controller = ReplayController()
        let gate = ReplayGate()
        let recording = try fixture("synthetic-stop-load")
        let task = Task { try await controller.load(sessionID: recording.session.sessionID) {
            await gate.suspend()
            return recording
        } }
        await gate.waitUntilEntered()
        controller.stop()
        await gate.release()
        let result = await task.result
        assertDiscarded(result)
        assertStopped(controller)
    }

    func testCancelledLoadNeverPublishesOrReturnsSnapshot() async throws {
        let controller = ReplayController()
        let gate = ReplayGate()
        let recording = try fixture("synthetic-cancel-load")
        let task = Task { try await controller.load(sessionID: recording.session.sessionID) {
            await gate.suspend() // Deliberately ignores cancellation to expose caller checks.
            return recording
        } }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        let result = await task.result
        assertDiscarded(result)
        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.recordedHistory(for: "soc"))
        XCTAssertNil(controller.recordedLocations())
        XCTAssertFalse(controller.loading)
    }

    func testLatestSeekWinsWhenOlderEndSeekFinishesLast() async throws {
        let gate = ReplayGate()
        let controller = gatedController(gate)
        let recording = try fixture("synthetic-seek-order")
        _ = try await controller.load(sessionID: recording.session.sessionID) { recording }
        await gate.arm()
        let end = Task { try await controller.seek(at: 4) }
        await gate.waitUntilEntered()
        let start = try await controller.seek(at: 0)
        XCTAssertEqual(start?.signals.first?.value, 40)
        await gate.release()
        let result = await end.result
        assertDiscarded(result)
        XCTAssertEqual(controller.position, 0)
        XCTAssertNil(controller.snapshot?.markTimestamp)
        XCTAssertEqual(controller.snapshot?.signals.first?.value, 40)
        XCTAssertEqual(controller.recordedHistory(for: "soc")?.samples.map(\.value), [40])
        XCTAssertFalse(controller.seeking)
    }

    func testStopDuringSeekDiscardsLateResult() async throws {
        let gate = ReplayGate()
        let controller = gatedController(gate)
        let recording = try fixture("synthetic-stop-seek")
        _ = try await controller.load(sessionID: recording.session.sessionID) { recording }
        await gate.arm()
        let seek = Task { try await controller.seek(at: 4) }
        await gate.waitUntilEntered()
        controller.stop()
        await gate.release()
        let result = await seek.result
        assertDiscarded(result)
        assertStopped(controller)
    }

    func testNewSessionDuringSeekDiscardsOldSnapshot() async throws {
        let gate = ReplayGate()
        let controller = gatedController(gate)
        let originalA = try fixture("synthetic-seek-A")
        let location = LocationSample(originalTimestamp: 103.9, receivedAtEpoch: 104,
            receivedAtMonotonicNanos: 4_000_000_000, latitude: 0, longitude: 0,
            altitude: nil, speed: nil, course: nil, horizontalAccuracy: 5, verticalAccuracy: nil, source: .demo)
        let gpsRow = PersistedMeasurement(sequence: 4, sessionID: originalA.session.sessionID, kind: "LOCATION",
            sourceTimestamp: location.originalTimestamp, receivedAtEpoch: location.receivedAtEpoch,
            receivedAtMonotonicNanos: location.receivedAtMonotonicNanos,
            payloadJSON: String(decoding: try JSONEncoder().encode(location), as: UTF8.self))
        let a = MeasurementExport(session: originalA.session, measurements: originalA.measurements + [gpsRow])
        let b = try fixture("synthetic-seek-B", firstValue: 80)
        _ = try await controller.load(sessionID: a.session.sessionID) { a }
        XCTAssertEqual(controller.recordedLocations()?.samples.map(\.measurement), [gpsRow])
        await gate.arm()
        let seek = Task { try await controller.seek(at: 4) }
        await gate.waitUntilEntered()
        _ = try await controller.load(sessionID: b.session.sessionID) { b }
        await gate.release()
        let result = await seek.result
        assertDiscarded(result)
        XCTAssertEqual(controller.sessionID, b.session.sessionID)
        XCTAssertEqual(controller.snapshot?.signals.first?.value, 81)
        XCTAssertEqual(controller.recordedHistory(for: "soc")?.samples.map(\.value), [80, 81])
        XCTAssertTrue(controller.recordedLocations()?.samples.isEmpty == true)
        XCTAssertEqual(controller.position, 4)
        XCTAssertFalse(controller.seeking)
    }

    func testCancelledSeekPreservesLastSuccessfulPositionAndSnapshot() async throws {
        let gate = ReplayGate()
        let controller = gatedController(gate)
        let recording = try fixture("synthetic-cancel-seek")
        _ = try await controller.load(sessionID: recording.session.sessionID) { recording }
        _ = try await controller.seek(at: 0)
        await gate.arm()
        let seek = Task { try await controller.seek(at: 4) }
        await gate.waitUntilEntered()
        seek.cancel()
        await gate.release()
        let result = await seek.result
        assertDiscarded(result)
        XCTAssertEqual(controller.position, 0)
        XCTAssertEqual(controller.snapshot?.signals.first?.value, 40)
        XCTAssertEqual(controller.recordedHistory(for: "soc")?.samples.map(\.value), [40])
        XCTAssertNil(controller.snapshot?.markTimestamp)
        XCTAssertFalse(controller.seeking)
    }

    func testBoundsNonfiniteAndBackwardsSeekPreserveRecordedEvidence() async throws {
        let controller = ReplayController()
        let recording = try fixture("synthetic-bounds")
        _ = try await controller.load(sessionID: recording.session.sessionID) { recording }
        XCTAssertEqual(controller.duration, 4)
        XCTAssertEqual(controller.position, 4)
        XCTAssertEqual(controller.snapshot?.markTimestamp, 102)
        _ = try await controller.seek(at: 999)
        XCTAssertEqual(controller.position, 4)
        _ = try await controller.seek(at: 2)
        XCTAssertEqual(controller.snapshot?.markTimestamp, 102)
        XCTAssertEqual(controller.snapshot?.signals.first?.value, 40)
        XCTAssertEqual(controller.recordedHistory(for: "soc")?.samples.map(\.value), [40])
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            do {
                let result = try await controller.seek(at: invalid)
                XCTAssertNil(result, "Invalid seek must throw or be discarded")
            } catch { }
            XCTAssertEqual(controller.position, 2)
            XCTAssertEqual(controller.snapshot?.markTimestamp, 102)
            XCTAssertEqual(controller.snapshot?.signals.first?.value, 40)
        XCTAssertEqual(controller.recordedHistory(for: "soc")?.samples.map(\.value), [40])
            XCTAssertFalse(controller.seeking)
        }
        _ = try await controller.seek(at: -99)
        XCTAssertEqual(controller.position, 0)
        XCTAssertNil(controller.snapshot?.markTimestamp)
        let signal = try XCTUnwrap(controller.snapshot?.signals.first)
        XCTAssertEqual(signal.value, 40)
        XCTAssertEqual(signal.receivedAtEpoch, 100)
        XCTAssertEqual(signal.receivedAtMonotonicNanos, 0)
        XCTAssertEqual(signal.quality, .valid)
        XCTAssertEqual(signal.frameSequence, 1)
        XCTAssertEqual(controller.snapshot?.signalAges["soc"], 0)
        XCTAssertEqual(controller.snapshot?.signalFreshness["soc"], .unknown)
    }

    private func gatedController(_ gate: ReplayGate) -> ReplayController {
        ReplayController(snapshotProvider: { timeline, position in
            if position == 4 { await gate.suspendIfArmed() }
            return try await timeline.snapshot(at: position)
        })
    }

    private func assertDiscarded(_ result: Result<MeasurementReplay.Snapshot?, Error>,
                                 file: StaticString = #filePath, line: UInt = #line) {
        if case .success(let snapshot) = result {
            XCTAssertNil(snapshot, "Superseded/cancelled work must not return accepted evidence", file: file, line: line)
        }
    }

    private func assertStopped(_ controller: ReplayController,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(controller.sessionID, file: file, line: line)
        XCTAssertNil(controller.snapshot, file: file, line: line)
        XCTAssertNil(controller.recordedHistory(for: "soc"), file: file, line: line)
        XCTAssertNil(controller.recordedLocations(), file: file, line: line)
        XCTAssertEqual(controller.position, 0, file: file, line: line)
        XCTAssertEqual(controller.duration, 0, file: file, line: line)
        XCTAssertFalse(controller.loading, file: file, line: line)
        XCTAssertFalse(controller.seeking, file: file, line: line)
    }

    func testPlaybackUsesMonotonicElapsedAndOriginalRecordedEvidence() async throws {
        let c = ReplayController(); let saved = try fixture("synthetic-play")
        _ = try await c.load(sessionID: saved.session.sessionID) { saved }
        _ = try await c.seek(at: 0)
        XCTAssertTrue(c.play(at: 100))
        let mid = try await c.advancePlayback(at: 102.5)
        XCTAssertEqual(c.position, 2.5); XCTAssertEqual(mid?.signals.first?.value, 40)
        XCTAssertEqual(mid?.signals.first?.receivedAtEpoch, 100)
        XCTAssertEqual(mid?.markTimestamp, 102); XCTAssertEqual(mid?.signalFreshness["soc"], .unknown)
        let end = try await c.advancePlayback(at: 110)
        XCTAssertEqual(c.position, 4); XCTAssertEqual(end?.signals.first?.value, 41)
        XCTAssertFalse(c.isPlaying)
    }

    func testPlaybackRateChangeReanchorsWithoutJumpAndRejectsInvalidClock() async throws {
        let c = ReplayController(); let saved = try fixture("synthetic-speed")
        _ = try await c.load(sessionID: saved.session.sessionID) { saved }; _ = try await c.seek(at: 0)
        XCTAssertTrue(c.play(at: 10)); _ = try await c.advancePlayback(at: 11)
        XCTAssertTrue(c.setPlaybackRate(2, at: 11)); XCTAssertEqual(c.position, 1)
        _ = try await c.advancePlayback(at: 12); XCTAssertEqual(c.position, 3)
        XCTAssertFalse(c.setPlaybackRate(.nan, at: 12)); XCTAssertFalse(c.setPlaybackRate(0, at: 12))
        let invalid = try await c.advancePlayback(at: .infinity); XCTAssertNil(invalid)
        let backwards = try await c.advancePlayback(at: 10); XCTAssertNil(backwards)
        XCTAssertEqual(c.position, 3); XCTAssertEqual(c.playbackRate, 2)
    }

    func testRateChangeIncludesElapsedTimeSinceLastCompletedTick() async throws {
        let c = ReplayController(); let seed = try fixture("synthetic-delayed-speed")
        let saved = MeasurementExport(session: PersistedMeasurementSession(sessionID: seed.session.sessionID,
            startedAt: 100, endedAt: 110), measurements: seed.measurements + [
            PersistedMeasurement(sequence: 4, sessionID: seed.session.sessionID, kind: "SYSTEM",
                sourceTimestamp: 110, receivedAtEpoch: 110, receivedAtMonotonicNanos: 10_000_000_000,
                payloadJSON: "{\"name\":\"recording_stopped\"}")])
        _ = try await c.load(sessionID: saved.session.sessionID) { saved }; _ = try await c.seek(at: 0)
        XCTAssertTrue(c.play(at: 100)); _ = try await c.advancePlayback(at: 101)
        XCTAssertEqual(c.position, 1)
        XCTAssertTrue(c.setPlaybackRate(2, at: 103))
        XCTAssertEqual(c.position, 1, "Published position still belongs to the last accepted snapshot")
        _ = try await c.advancePlayback(at: 104)
        XCTAssertEqual(c.position, 5, "Three seconds at1× then one second at2×")
        XCTAssertEqual(c.snapshot?.signals.first?.receivedAtEpoch, 104)
        XCTAssertEqual(c.snapshot?.signals.first?.value, 41)
    }

    func testPauseManualSeekAndStopPreventFurtherPlayback() async throws {
        let c = ReplayController(); let saved = try fixture("synthetic-pause")
        _ = try await c.load(sessionID: saved.session.sessionID) { saved }; _ = try await c.seek(at: 0)
        XCTAssertTrue(c.play(at: 10)); _ = try await c.advancePlayback(at: 12)
        c.pause(); let paused = try await c.advancePlayback(at: 13); XCTAssertNil(paused)
        XCTAssertEqual(c.position, 2); XCTAssertTrue(c.play(at: 20))
        _ = try await c.seek(at: 0); XCTAssertFalse(c.isPlaying)
        XCTAssertNil(c.snapshot?.markTimestamp); XCTAssertEqual(c.snapshot?.signals.first?.value, 40)
        XCTAssertTrue(c.play(at: 30)); c.stop()
        let stopped = try await c.advancePlayback(at: 40); XCTAssertNil(stopped); assertStopped(c)
    }

    func testPausedOldTickCannotOverwriteNewPlay() async throws {
        let gate = ReplayGate(); let c = gatedController(gate); let saved = try fixture("synthetic-tick-race")
        _ = try await c.load(sessionID: saved.session.sessionID) { saved }; _ = try await c.seek(at: 0)
        XCTAssertTrue(c.play(at: 100)); await gate.arm()
        let old = Task { try await c.advancePlayback(at: 104) }; await gate.waitUntilEntered()
        c.pause(); XCTAssertTrue(c.play(at: 200)); _ = try await c.advancePlayback(at: 201)
        await gate.release(); assertDiscarded(await old.result)
        XCTAssertTrue(c.isPlaying); XCTAssertEqual(c.position, 1)
        XCTAssertEqual(c.snapshot?.signals.first?.value, 40); XCTAssertNil(c.snapshot?.markTimestamp)
    }

    func testPlayingTickCannotPublishIntoReplacementSession() async throws {
        let gate = ReplayGate(); let c = gatedController(gate); let a = try fixture("synthetic-tick-A")
        _ = try await c.load(sessionID: a.session.sessionID) { a }; _ = try await c.seek(at: 0)
        XCTAssertTrue(c.play(at: 100)); await gate.arm()
        let old = Task { try await c.advancePlayback(at: 104) }; await gate.waitUntilEntered()
        let b = try fixture("synthetic-tick-B", firstValue: 70)
        _ = try await c.load(sessionID: b.session.sessionID) { b }
        await gate.release(); assertDiscarded(await old.result)
        XCTAssertFalse(c.isPlaying); XCTAssertEqual(c.sessionID, b.session.sessionID)
        XCTAssertEqual(c.snapshot?.signals.first?.value, 71)
    }

    func testCancelledComputedManySignalSeekCannotPublish() async throws {
        let budget = ReplayStressBudget(); defer { budget.finish() }
        let gate = ReplayGate()
        let controller = ReplayController(snapshotProvider: { timeline, time in
            let state = try await timeline.snapshot(at:time)
            await gate.suspendIfArmed() // Handshake proves real computation completed before publication.
            return state
        })
        let recording = try manySignalFixture()
        _ = try await controller.load(sessionID:recording.session.sessionID) {recording}
        _ = try await controller.seek(at:0)
        let previous = try XCTUnwrap(controller.snapshot)
        await gate.arm()
        let task = Task {try await controller.seek(at:4)}
        await gate.waitUntilEntered();task.cancel();await gate.release()
        let result = await task.result
        switch result {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("Cancelled computed seek must reject its result")
        }
        XCTAssertEqual(controller.position,0)
        XCTAssertEqual(controller.snapshot?.signals,previous.signals)
        XCTAssertEqual(controller.snapshot?.timestamp,previous.timestamp)
        XCTAssertEqual(controller.snapshot?.signalAges,previous.signalAges)
        XCTAssertEqual(controller.snapshot?.signalFreshness,previous.signalFreshness)
        XCTAssertEqual(controller.snapshot?.signals.count,512)
        XCTAssertFalse(controller.seeking)
        budget.checkpoint()
    }

    func testStopAfterComputedManySignalSeekDiscardsResultAndAllOwnedState() async throws {
        let budget = ReplayStressBudget(); defer { budget.finish() }
        let gate = ReplayGate()
        let controller = ReplayController(snapshotProvider: { timeline, time in
            let state = try await timeline.snapshot(at:time)
            await gate.suspendIfArmed()
            return state
        })
        let recording = try manySignalFixture()
        _ = try await controller.load(sessionID:recording.session.sessionID) {recording}
        await gate.arm()
        let task = Task {try await controller.seek(at:0)}
        await gate.waitUntilEntered();controller.stop();await gate.release()
        let result = await task.result
        switch result {
        case .success(let snapshot): XCTAssertNil(snapshot)
        case .failure(let error): XCTFail("Stop should discard this uncancelled result: \(error)")
        }
        assertStopped(controller)
        XCTAssertFalse(controller.isPlaying);XCTAssertEqual(controller.playbackRate,1)
        budget.checkpoint()
    }

    private func manySignalFixture() throws -> MeasurementExport {
        var rows:[PersistedMeasurement]=[]
        for layer in 0..<3 {for id in 0..<512 {
            let sequence=Int64(rows.count+1),epoch=300-Double(layer),nanos=UInt64(layer)*2_000_000_000
            let signal=DecodedSignalSample(signalID:String(format:"signal-%04d",id),value:Double(id+layer),rawValue:UInt64(id+10),enumName:"layer-\(layer)",unit:layer == 1 ? "V":"%",frameSequence:UInt64(sequence),receivedAtEpoch:epoch,receivedAtMonotonicNanos:nanos,source:layer == 1 ? .diagnostic:.rawCAN)
            rows.append(.init(sequence:sequence,sessionID:"many-races",kind:"SIGNAL",sourceTimestamp:epoch,receivedAtEpoch:epoch,receivedAtMonotonicNanos:nanos,payloadJSON:String(decoding:try JSONEncoder().encode(signal),as:UTF8.self)))
        }}
        return .init(session:.init(sessionID:"many-races",startedAt:290,endedAt:310,mode:.live),measurements:rows)
    }

    private func fixture(_ id: String, firstValue: Double = 40) throws -> MeasurementExport {
        func signal(_ sequence: Int64, _ epoch: Double, _ mono: UInt64, _ value: Double) throws -> PersistedMeasurement {
            let sample = DecodedSignalSample(signalID: "soc", value: value,
                rawValue: UInt64(value), enumName: nil, unit: "%", frameSequence: UInt64(sequence),
                receivedAtEpoch: epoch, receivedAtMonotonicNanos: mono)
            let payload = String(decoding: try JSONEncoder().encode(sample), as: UTF8.self)
            return PersistedMeasurement(sequence: sequence, sessionID: id, kind: "SIGNAL",
                sourceTimestamp: epoch, receivedAtEpoch: epoch, receivedAtMonotonicNanos: mono,
                payloadJSON: payload)
        }
        return MeasurementExport(session: PersistedMeasurementSession(sessionID: id, startedAt: 100, endedAt: 105),
            measurements: [try signal(1, 100, 0, firstValue),
                PersistedMeasurement(sequence: 2, sessionID: id, kind: "SYSTEM", sourceTimestamp: 102,
                    receivedAtEpoch: 102, receivedAtMonotonicNanos: 2_000_000_000,
                    payloadJSON: "{\"name\":\"MARK\"}"),
                try signal(3, 104, 4_000_000_000, firstValue + 1)])
    }
}

/// One-shot gate with an explicit arrival handshake. Release never uses time or sleeps.
private actor ReplayGate {
    private var armed = false
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []

    func arm() { armed = true }

    func suspendIfArmed() async {
        guard armed else { return }
        armed = false // Initial load and subsequent new-session loads pass through.
        await suspend()
    }

    func suspend() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            entered = true
            let arrivals = arrivalContinuations
            arrivalContinuations.removeAll()
            for arrival in arrivals { arrival.resume() }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { arrivalContinuations.append($0) }
    }

    func release() {
        precondition(entered, "Release only after the arrival handshake")
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// Test-only, bounded synthetic workload monitor. A guard aborts this test
/// process, never a device or another job. Sampling cannot catch every spike.
private final class ReplayStressBudget: @unchecked Sendable {
    private let start = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var timer: DispatchSourceTimer?
    init() {
        let timer = DispatchSource.makeTimerSource(queue:DispatchQueue.global())
        timer.schedule(deadline:.now(),repeating:.milliseconds(100))
        timer.setEventHandler { [weak self] in self?.checkpoint() }
        self.timer = timer; timer.resume()
    }
    func checkpoint() {
        let seconds = ProcessInfo.processInfo.systemUptime-start
        var bytes: UInt64 = 0
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue:info)/4)
        let result = withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
            }
        }
        guard result == KERN_SUCCESS else { fatalError("Stress memory monitor unavailable") }
        bytes = info.phys_footprint
        #endif
        lock.lock(); peak=max(peak,bytes);lock.unlock()
        if bytes > 1_073_741_824 || seconds > 60 { fatalError("Stress 1GiB/60s guard exceeded") }
    }
    func finish() {
        checkpoint();timer?.cancel();timer=nil
        lock.lock();let observed=peak;lock.unlock()
        print("STRESS_BUDGET seconds=\(ProcessInfo.processInfo.systemUptime-start) observedPeakFootprint=\(observed)")
    }
    deinit {timer?.cancel()}
}
