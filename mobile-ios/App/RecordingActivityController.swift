import ActivityKit
import Foundation
import Observation
import UIKit
import TelemetryCore

/// Optional, local display only. Recording never depends on ActivityKit success.
@MainActor @Observable
final class RecordingActivityController {
    enum Status { case off, ready, active, ending, unavailable, stopped, interrupted, dismissed }
    var enabled = UserDefaults.standard.bool(forKey: "recordingActivity.enabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "recordingActivity.enabled")
            if !enabled { end(interrupted: false); status = .off }
            else if activity == nil { status = .ready }
        }
    }
    var firstSignal = UserDefaults.standard.string(forKey: "recordingActivity.firstSignal") ?? "" {
        didSet { UserDefaults.standard.set(firstSignal, forKey: "recordingActivity.firstSignal") }
    }
    var secondSignal = UserDefaults.standard.string(forKey: "recordingActivity.secondSignal") ?? "" {
        didSet { UserDefaults.standard.set(secondSignal, forKey: "recordingActivity.secondSignal") }
    }
    private(set) var status: Status = .off
    var selectedIDs: [String] { [firstSignal, secondSignal] }
    @ObservationIgnored private var lifecycle = RecordingActivityLifecycle()
    @ObservationIgnored private var activity: Activity<RecordingActivityAttributes>?
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var updateID: UUID?
    @ObservationIgnored private var pendingSnapshot: RecordingActivitySnapshot?
    @ObservationIgnored private var stateObserver: Task<Void, Never>?
    @ObservationIgnored private var recovered = false
    @ObservationIgnored private var endingGeneration = UUID()
    @ObservationIgnored private var lastDelivery: TimeInterval = 0

    init() {
        // The recorder closes interrupted sessions on launch. Never leave a
        // previous process's activity asserting that those sessions are active.
        let orphaned = Activity<RecordingActivityAttributes>.activities
        Task { [weak self] in
            for activity in orphaned {
                await activity.end(ActivityContent(state: .ended(at: Date().timeIntervalSince1970, interrupted: true), staleDate: nil), dismissalPolicy: .immediate)
            }
            guard let self else { return }
            self.recovered = true
            self.status = self.enabled ? .ready : .off
        }
    }

    func begin(sessionID: String, startedAt: Date, mode: TelemetryRunMode, snapshot: RecordingActivitySnapshot) {
        if let activity, activity.attributes.sessionID != sessionID { end(interrupted: true) }
        guard let generation = lifecycle.begin(sessionID: sessionID, enabled: enabled && recovered,
                foreground: UIApplication.shared.applicationState == .active, mode: mode) else { return }
        endingGeneration = UUID()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { status = .unavailable; lifecycle.end(); return }
        do {
            let attributes = RecordingActivityAttributes(sessionID: sessionID, startedAt: startedAt,
                isDemo: mode == .demo, korean: AppLanguageStore.shared.language == .korean)
            let size = try JSONEncoder().encode(attributes).count + JSONEncoder().encode(snapshot).count
            guard size < 3_000 else { lifecycle.end(); status = .unavailable; return }
            let activity = try Activity.request(
                attributes: attributes,
                content: content(snapshot), pushType: nil)
            self.activity = activity
            token = generation
            status = .active
            lastDelivery = ProcessInfo.processInfo.systemUptime
            stateObserver?.cancel()
            stateObserver = Task { [weak self] in
                for await state in activity.activityStateUpdates {
                    guard let self, self.lifecycle.isCurrent(generation) else { return }
                    if state == .dismissed || state == .ended {
                        self.lifecycle.end()
                        self.activity = nil
                        self.token = nil
                        self.status = .dismissed
                        return
                    }
                }
            }
        } catch {
            lifecycle.end()
            status = .unavailable
        }
    }

    func update(_ snapshot: RecordingActivitySnapshot, force: Bool = false) {
        guard let activity, let token, lifecycle.isCurrent(token),
              activity.activityState == .active || activity.activityState == .stale else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastDelivery >= 2 else { return }
        lastDelivery = now
        // Coalesce while the OS is busy; never let update work grow unbounded.
        pendingSnapshot = snapshot
        guard updates == nil else { return }
        let id = UUID()
        updateID = id
        updates = Task { [weak self] in
            guard let self else { return }
            while self.lifecycle.isCurrent(token), let next = self.pendingSnapshot {
                self.pendingSnapshot = nil
                await activity.update(self.content(next))
            }
            if self.updateID == id { self.updates = nil; self.updateID = nil }
        }
    }

    func end(interrupted: Bool) {
        lifecycle.end()
        token = nil
        stateObserver?.cancel()
        stateObserver = nil
        guard let old = activity else { return }
        activity = nil
        status = .ending
        let closing = UUID()
        endingGeneration = closing
        let pending = updates
        updates = nil
        updateID = nil
        pendingSnapshot = nil
        Task { [weak self] in
            await pending?.value
            await old.end(ActivityContent(state: .ended(at: Date().timeIntervalSince1970, interrupted: interrupted), staleDate: nil), dismissalPolicy: .immediate)
            guard let self, self.endingGeneration == closing, self.activity == nil else { return }
            self.status = self.enabled ? (interrupted ? .interrupted : .stopped) : .off
        }
    }

    private func content(_ snapshot: RecordingActivitySnapshot) -> ActivityContent<RecordingActivitySnapshot> {
        ActivityContent(state: snapshot, staleDate: Date(timeIntervalSince1970: snapshot.validUntil), relevanceScore: 0)
    }
}
