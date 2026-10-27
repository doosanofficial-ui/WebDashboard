import Foundation
import SwiftUI
import TelemetryCore

/// Explicit headless ownership seam, not an emulation of native SwiftUI lifetime.
/// Each newly constructed child gets fresh local storage; injected Binding
/// values keep their owner's storage. No view/window/run loop is rendered.
@propertyWrapper
struct HeadlessState<Value> {
    final class Storage {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    private let storage: Storage
    init(wrappedValue: Value) { storage = Storage(wrappedValue) }
    var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }
    var projectedValue: Binding<Value> {
        Binding(get: { storage.value }, set: { storage.value = $0 })
    }
}

enum AppLanguage { case english, korean }
@MainActor final class AppLanguageStore {
    static let shared = AppLanguageStore()
    let language = AppLanguage.english
}
struct SessionEnergySummaryView {
    // ACTUAL_SUMMARY_LABELS
}
// ACTUAL_ENERGY_PROJECTION

@MainActor final class ModelBoundary {
    let replayController: ReplayController
    init(_ controller: ReplayController) { replayController = controller }
}

@MainActor final class SessionsOwner {
    let model: ModelBoundary
    // ACTUAL_OWNER_FIELDS
    init(_ controller: ReplayController) { model = ModelBoundary(controller) }

    func makeEnergy() -> ReplayEnergyView {
        // ACTUAL_ENERGY_CALL
    }

    // ACTUAL_ENERGY_CANDIDATES

    /// Deliver a changed session identity to the actual parent's onChange body.
    /// SwiftUI's observer delivery itself remains a native UI test concern.
    func sessionChanged(from oldID: String?) {
        guard oldID != model.replayController.sessionID else { return }
        // ACTUAL_SESSION_RESET
    }
}

@main enum Run {
    @MainActor static var checks = 0
    @MainActor static var failures = 0

    @MainActor static func expect(_ value: Bool, _ title: String) {
        checks += 1
        if !value { failures += 1; print("FAIL: " + title) }
    }

    @MainActor static func selected(_ view: ReplayEnergyView, _ title: String) {
        expect(view.selectedVoltageSignalID == "hv_voltage", title + " retains explicit voltage")
        expect(view.selectedCurrentSignalID == "hv_current", title + " retains explicit current")
        expect(view.selectedCurrentSignConventionRawValue == "positiveCurrentMeansConsumption",
               title + " retains explicit sign")
    }

    @MainActor static func unselected(_ view: ReplayEnergyView, _ title: String) {
        expect(view.selectedVoltageSignalID == nil && view.selectedCurrentSignalID == nil &&
               view.selectedCurrentSignConventionRawValue == nil, title + " clears all selections")
    }

    @MainActor static func energy(_ view: ReplayEnergyView, _ expected: Double, _ title: String) {
        switch view.projectionState {
        case .ready(let projection):
            expect(projection.summary.availability == .available &&
                   abs(projection.summary.consumedKWh - expected) < 1e-12, title)
        case .unavailable(let reason): expect(false, title + ": " + reason)
        }
    }

    @MainActor static func choose(_ view: ReplayEnergyView) {
        view.selectedVoltageSignalID = "hv_voltage"
        view.selectedCurrentSignalID = "hv_current"
        view.selectedCurrentSignConventionRawValue = "positiveCurrentMeansConsumption"
    }

    static func recording(_ id: String, firstSample: Int = 0) throws -> MeasurementExport {
        struct Sample: Encodable {
            let signalID: String
            let value: Double
            let rawValue: UInt64
            let unit: String
            let frameSequence: UInt64
            let receivedAtEpoch: Double
            let receivedAtMonotonicNanos: UInt64
            let source = TelemetrySource.rawCAN
            let recordedQuality = SignalQuality.valid
        }
        var rows = [PersistedMeasurement(sequence: 1, sessionID: id, kind: "SYSTEM",
            sourceTimestamp: 100, receivedAtEpoch: 100, receivedAtMonotonicNanos: 0,
            payloadJSON: "{\"name\":\"recording_started\"}")]
        for second in firstSample...10 {
            for (signal, value, unit) in [("hv_voltage", 360.0, "V"), ("hv_current", 10.0, "A")] {
                let sample = Sample(signalID: signal, value: value, rawValue: UInt64(value), unit: unit,
                    frameSequence: UInt64(rows.count + 1), receivedAtEpoch: 100 + Double(second),
                    receivedAtMonotonicNanos: UInt64(second) * 1_000_000_000)
                rows.append(PersistedMeasurement(sequence: Int64(rows.count + 1), sessionID: id,
                    kind: "SIGNAL", sourceTimestamp: sample.receivedAtEpoch,
                    receivedAtEpoch: sample.receivedAtEpoch,
                    receivedAtMonotonicNanos: sample.receivedAtMonotonicNanos,
                    payloadJSON: String(decoding: try JSONEncoder().encode(sample), as: UTF8.self)))
            }
        }
        return MeasurementExport(session: .init(sessionID: id, startedAt: 100, endedAt: 110, mode: .demo),
                                 measurements: rows)
    }

    @MainActor static func main() async throws {
        let controller = ReplayController()
        let owner = SessionsOwner(controller)
        let saved = try recording("qualified")
        _ = try await controller.load(sessionID: saved.session.sessionID) { saved }
        owner.sessionChanged(from: nil)
        let initial = owner.makeEnergy()
        unselected(initial, "new session requires explicit choices")
        initial.selectedVoltageSignalID = "hv_voltage"
        initial.selectedCurrentSignalID = "hv_current"
        if case .unavailable = initial.projectionState {} else {
            expect(false, "two selected signals must not infer a sign convention")
        }
        initial.selectedCurrentSignConventionRawValue = "positiveCurrentMeansConsumption"
        energy(initial, 0.0100, "qualified 360 V × 10 A for 10s is 0.0100 kWh")
        selected(owner.makeEnergy(), "recreated child at same cursor")

        let originalID = controller.sessionID
        _ = try await controller.seek(at: 5)
        owner.sessionChanged(from: originalID)
        expect(controller.sessionID == "qualified" && controller.position == 5,
               "real seek accepts 5s in the same session")
        let sought = owner.makeEnergy()
        selected(sought, "child recreated after same-session seek")
        energy(sought, 0.0050, "same explicit selection at 5s is 0.0050 kWh without reselection")

        let late = try recording("late-signals", firstSample: 5)
        let previousID = controller.sessionID
        _ = try await controller.load(sessionID: late.session.sessionID) { late }
        owner.sessionChanged(from: previousID)
        unselected(owner.makeEnergy(), "different session")
        choose(owner.makeEnergy())
        let lateID = controller.sessionID
        _ = try await controller.seek(at: 0)
        owner.sessionChanged(from: lateID)
        let absent = owner.makeEnergy()
        expect(absent.recordedVoltageSignalIDs.isEmpty && absent.recordedCurrentSignalIDs.isEmpty,
               "real earlier cursor has no voltage/current candidates")
        selected(absent, "temporarily missing candidates")
        if case .unavailable = absent.projectionState {} else {
            expect(false, "missing recorded candidates stay unavailable")
        }
        _ = try await controller.seek(at: 10)
        owner.sessionChanged(from: lateID)
        energy(owner.makeEnergy(), 0.0050, "returning recorded candidates reuse explicit selection")

        // No child participates in either identity transition below.
        let replacement = try recording("replacement")
        let lateSessionID = controller.sessionID
        _ = try await controller.load(sessionID: replacement.session.sessionID) { replacement }
        owner.sessionChanged(from: lateSessionID)
        unselected(owner.makeEnergy(), "session replacement while child absent")
        choose(owner.makeEnergy())
        selected(owner.makeEnergy(), "replacement selection")
        let replacementID = controller.sessionID
        controller.stop()
        owner.sessionChanged(from: replacementID)
        unselected(owner.makeEnergy(), "Stop while child absent")
        _ = try await controller.load(sessionID: replacement.session.sessionID) { replacement }
        owner.sessionChanged(from: nil)
        unselected(owner.makeEnergy(), "reopening stopped session does not restore prior choices")

        print("REPLAY ENERGY SELECTION SOURCE HARNESS: \(checks) assertions, \(failures) failures; headless state seam, no native UI lifetime evidence")
        if failures > 0 { exit(1) }
    }
}
