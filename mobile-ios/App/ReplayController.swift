import Foundation
import Observation
import TelemetryCore

/// Navigation of immutable recorded time. No acquisition, timer or writer.
@MainActor @Observable
final class ReplayController {
    private(set) var sessionID: String?
    private(set) var snapshot: MeasurementReplay.Snapshot?
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var loading = false
    private(set) var seeking = false
    private(set) var recordingMode: TelemetryRunMode?
    private(set) var measurementCount = 0
    private(set) var isPlaying = false
    private(set) var playbackRate = 1.0
    @ObservationIgnored private var playbackGeneration = UUID()
    @ObservationIgnored private var playbackAnchorTime = 0.0
    @ObservationIgnored private var playbackAnchorPosition = 0.0
    @ObservationIgnored private var lastPlaybackTime = 0.0
    @ObservationIgnored private var timeline: MeasurementReplay.Timeline?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var seekGeneration = UUID()
    @ObservationIgnored private let snapshotProvider: @Sendable (MeasurementReplay.Timeline, Double) async throws -> MeasurementReplay.Snapshot

    init(snapshotProvider: @escaping @Sendable (MeasurementReplay.Timeline, Double) async throws -> MeasurementReplay.Snapshot = { try await $0.snapshot(at: $1) }) {
        self.snapshotProvider = snapshotProvider
    }

    func recordedHistory(for signalID: String) -> MeasurementReplay.SignalHistory? {
        guard let timeline, snapshot != nil, !loading else { return nil }
        // Accepted position and snapshot publish together after generation checks.
        return try? timeline.signalHistory(signalID: signalID, at: position)
    }

    func recordedLocations() -> MeasurementReplay.LocationHistory? {
        guard let timeline, snapshot != nil, !loading else { return nil }
        return try? timeline.locationHistory(at: position)
    }

    func load(sessionID: String, loader: @escaping () async throws -> MeasurementExport) async throws -> MeasurementReplay.Snapshot? {
        stop()
        let token = generation
        self.sessionID = sessionID
        loading = true
        defer { if generation == token { loading = false } }
        do {
            let saved = try await loader()
            try Task.checkCancellation()
            guard generation == token else { return nil }
            guard saved.session.sessionID == sessionID else { throw MeasurementReplayError.sessionMismatch }
            // Existing recordings do not persist a timeout policy. Never reuse
            // today's adapter profile as if it belonged to this recording.
            let candidate = try await MeasurementReplay.timeline(saved, signalTimeouts: [:])
            let state = try await snapshotProvider(candidate, candidate.duration)
            try Task.checkCancellation()
            guard generation == token else { return nil }
            timeline = candidate
            snapshot = state
            position = candidate.duration
            duration = candidate.duration
            recordingMode = saved.session.mode
            measurementCount = candidate.measurementCount
            return state
        } catch {
            guard generation == token else { return nil }
            stop()
            throw error
        }
    }

    func seek(at seconds: Double) async throws -> MeasurementReplay.Snapshot? {
        guard seconds.isFinite else { throw MeasurementReplayError.invalidExport }
        pause()
        return try await seekSnapshot(at: seconds)
    }

    private func seekSnapshot(at seconds: Double) async throws -> MeasurementReplay.Snapshot? {
        guard seconds.isFinite else { throw MeasurementReplayError.invalidExport }
        guard let timeline, !loading else { return nil }
        let token = generation, request = UUID()
        seekGeneration = request
        seeking = true
        defer { if generation == token && seekGeneration == request { seeking = false } }
        let state = try await snapshotProvider(timeline, seconds)
        try Task.checkCancellation()
        guard generation == token, seekGeneration == request else { return nil }
        position = min(duration, max(0, seconds))
        snapshot = state
        return state
    }

    /// Caller supplies monotonic uptime, never a wall clock or recording timestamp.
    @discardableResult func play(at uptime: Double) -> Bool {
        guard uptime.isFinite, timeline != nil, !loading, position < duration else { return false }
        pause()
        playbackAnchorTime = uptime
        lastPlaybackTime = uptime
        playbackAnchorPosition = position
        isPlaying = true
        return true
    }

    func pause() {
        playbackGeneration = UUID()
        seekGeneration = UUID()
        seeking = false
        isPlaying = false
    }

    @discardableResult func setPlaybackRate(_ rate: Double, at uptime: Double) -> Bool {
        guard [0.5, 1.0, 2.0].contains(rate), uptime.isFinite,
              !isPlaying || uptime >= lastPlaybackTime else { return false }
        // Preserve elapsed time under the old rate even if a decode/tick has
        // not finished. Published position remains tied to its accepted snapshot.
        let logicalPosition = isPlaying
            ? playbackAnchorPosition + (uptime - playbackAnchorTime) * playbackRate : position
        guard logicalPosition.isFinite else { return false }
        seekGeneration = UUID()
        seeking = false
        playbackGeneration = UUID()
        playbackRate = rate
        playbackAnchorPosition = min(duration, max(position, logicalPosition))
        playbackAnchorTime = uptime
        lastPlaybackTime = uptime
        return true
    }

    func advancePlayback(at uptime: Double) async throws -> MeasurementReplay.Snapshot? {
        guard isPlaying, uptime.isFinite, uptime >= lastPlaybackTime else { return nil }
        let token = playbackGeneration
        let target = playbackAnchorPosition + (uptime - playbackAnchorTime) * playbackRate
        guard target.isFinite else { return nil }
        lastPlaybackTime = uptime
        guard let state = try await seekSnapshot(at: target), playbackGeneration == token else { return nil }
        if target >= duration { pause() }
        return state
    }

    func stop() {
        pause()
        playbackRate = 1
        generation = UUID()
        seekGeneration = UUID()
        sessionID = nil
        snapshot = nil
        timeline = nil
        position = 0
        duration = 0
        measurementCount = 0
        recordingMode = nil
        loading = false
        seeking = false
    }
}
