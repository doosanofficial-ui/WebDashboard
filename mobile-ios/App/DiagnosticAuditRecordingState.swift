import Foundation
import Observation
import TelemetryCore

/// Main-actor admission into the existing synchronous measurement write queue.
/// Acquisition remains independent of recording. Historical UI reads stored rows.
@MainActor @Observable
final class DiagnosticAuditRecordingState {
    private(set) var captureIsIncomplete = false
    @ObservationIgnored private var capture: DiagnosticAuditCapture?
    @ObservationIgnored private var delivery: DiagnosticAuditOrdinalBuffer?
    @ObservationIgnored private var recordedIncomplete = false

    func begin(at timestamp: DiagnosticAuditTimestamp) {
        capture = DiagnosticAuditCapture(recordingID: UUID(), startedAt: timestamp)
        delivery = DiagnosticAuditOrdinalBuffer(startedAt: timestamp)
        recordedIncomplete = false
        captureIsIncomplete = false
    }

    func receive(_ event: DiagnosticAuditEvent) -> [MeasurementEvent] {
        guard var active = capture, var orderedDelivery = delivery else { return [] }
        var result: [MeasurementEvent] = []
        do {
            let ordered = try orderedDelivery.ingest(event)
            delivery = orderedDelivery
            for row in ordered {
                do { result += try active.ingest(row).map(MeasurementEvent.diagnosticAudit) }
                catch { result += incomplete(at: row.timestamp) }
            }
        } catch {
            delivery = orderedDelivery
            result += incomplete(at: event.timestamp)
        }
        // A temporary out-of-order gap is not loss. Persist a marker only on
        // rejection, or if the gap is still unresolved at recording Stop.
        capture = active
        if orderedDelivery.hasRejectedEvents || active.hasRejectedSourceEvents {
            result += incomplete(at: event.timestamp)
        }
        return result
    }

    func failed(_ receipt: DiagnosticAuditFailureReceipt) -> [MeasurementEvent] {
        guard let capture,
              receipt.emittedAtMonotonicNanos >= capture.startedAt.monotonicNanoseconds,
              let timestamp = try? DiagnosticAuditTimestamp(epochSeconds: receipt.emittedAtEpoch,
                  monotonicNanoseconds: receipt.emittedAtMonotonicNanos) else { return [] }
        return incomplete(at: timestamp)
    }

    func finish() -> [MeasurementEvent] {
        guard let timestamp = try? Self.now() else { discard(); return [] }
        return finish(at: timestamp)
    }

    func finish(at timestamp: DiagnosticAuditTimestamp) -> [MeasurementEvent] {
        guard var active = capture else { return [] }
        defer { discard() }
        var result: [MeasurementEvent] = []
        if delivery?.hasUnresolvedGaps == true || delivery?.hasRejectedEvents == true {
            result += incomplete(at: timestamp)
        }
        delivery?.close()
        do { result += try active.close(at: timestamp).map(MeasurementEvent.diagnosticAudit) }
        catch { result += incomplete(at: timestamp) }
        return result
    }

    func discard() { capture = nil; delivery = nil }

    private func incomplete(at timestamp: DiagnosticAuditTimestamp) -> [MeasurementEvent] {
        guard capture != nil, !recordedIncomplete else { return [] }
        captureIsIncomplete = true
        recordedIncomplete = true
        return [.system(name: "diagnostic_audit_incomplete", timestamp: timestamp.epochSeconds,
                        monotonicNanos: timestamp.monotonicNanoseconds)]
    }

    private static func now() throws -> DiagnosticAuditTimestamp {
        try .init(epochSeconds: Date().timeIntervalSince1970,
                  monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}
