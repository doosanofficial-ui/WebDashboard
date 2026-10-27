import Foundation
import TelemetryCore

/// Captured before the asynchronous MainActor hop, so an old error cannot be
/// relabeled with the arrival time of a later recording window.
struct DiagnosticAuditFailureReceipt: Sendable {
    let connectionID: UUID
    let error: DiagnosticAuditError
    let emittedAtEpoch: Double
    let emittedAtMonotonicNanos: UInt64
}

@MainActor
final class DiagnosticAdapterController {
    var onState: ((String) -> Void)?
    var onResult: ((OBDQueryResult) -> Void)?
    var onQueryFailure: ((DiagnosticQueryFailure, String) -> Void)?
    var onAcquiringChanged: ((Bool) -> Void)?
    var onConnection: ((UUID, AdapterProfile) -> Void)?
    var onObservation: ((UUID, OBDQueryObservation) -> Void)?
    var onObservationUnavailable: ((UUID) -> Void)?
    var onAudit: ((DiagnosticAuditEvent) -> Void)?
    var onAuditError: ((DiagnosticAuditFailureReceipt) -> Void)?

    private var task: Task<Void, Never>?
    private var scheduler: OBDQueryScheduler?
    private var stopping: Task<Void, Never>?
    private var generation = UUID()

    func start(profile: AdapterProfile, queries selectedQueries: [OBDQueryDefinition]? = nil,
               localContextID: String? = nil) {
        stop()
        let queries = selectedQueries ?? profile.diagnosticQueries
        guard !queries.isEmpty else {
            onState?("No diagnostic queries selected")
            return
        }
        guard Set(queries.map(\.id)).count == queries.count,
              queries.allSatisfy({ profile.diagnosticQueries.contains($0) }) else {
            onState?("Diagnostic query selection needs review")
            return
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        let previousStop = stopping
        onAcquiringChanged?(true)
        onState?("Diagnostic adapter starting")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await previousStop?.value
            guard !Task.isCancelled, self.generation == currentGeneration else { return }
            defer {
                if self.generation == currentGeneration {
                    self.task = nil
                    self.scheduler = nil
                    self.onAcquiringChanged?(false)
                }
            }
            var backoff: UInt64 = 1
            while !Task.isCancelled && self.generation == currentGeneration {
                do {
                    let connectionID = UUID()
                    let auditContext = try DiagnosticAuditContext(vehicleContextID: localContextID,
                        adapterProfileID: profile.id, adapterProfileName: profile.name,
                        transport: profile.transport.rawValue, connectionID: connectionID)
                    let transport = try LiveAdapterController.makeTransport(profile)
                    self.onConnection?(connectionID, profile)
                    let session = OBDQuerySession(
                        transport: transport,
                        sourceAdapter: profile.name,
                        sourceTransport: profile.transport.rawValue,
                        auditContext: auditContext,
                        onAudit: { [weak self] event in await self?.deliverAudit(event) },
                        onAuditError: { [weak self] error in
                            let receipt = DiagnosticAuditFailureReceipt(connectionID: connectionID, error: error,
                                emittedAtEpoch: Date().timeIntervalSince1970,
                                emittedAtMonotonicNanos: DispatchTime.now().uptimeNanoseconds)
                            await self?.deliverAuditError(receipt)
                        }
                    )
                    let observations = OBDQueryObservationBuffer()
                    let scheduler = OBDQueryScheduler(session: session,
                        observedQueries: profile.diagnosticQueries,
                        onObservation: { observations.append($0) })
                    self.scheduler = scheduler
                    let stream = try await scheduler.start(queries: queries)
                    guard !Task.isCancelled, self.generation == currentGeneration else {
                        await scheduler.stop(); return
                    }
                    self.onState?("Diagnostic query monitoring")
                    backoff = 1
                    var observationLossReported = false

                    for await outcome in stream {
                        guard !Task.isCancelled, self.generation == currentGeneration else { break }
                        if let observation = observations.take(for: outcome) {
                            self.onObservation?(connectionID, observation)
                        } else if !observationLossReported {
                            observationLossReported = true
                            self.onObservationUnavailable?(connectionID)
                        }
                        switch outcome {
                        case .success(let result):
                            self.onResult?(result)
                        case .failure(let queryID, let error):
                            let state = "Diagnostic \(queryID): \(Self.errorText(error))"
                            if let onQueryFailure = self.onQueryFailure {
                                onQueryFailure(DiagnosticQueryFailure(queryID: queryID, error: error), state)
                            } else {
                                self.onState?(state)
                            }
                        }
                    }
                    await scheduler.stop()
                    if self.generation == currentGeneration { self.scheduler = nil }
                } catch is CancellationError {
                    return
                } catch {
                    if self.generation == currentGeneration, !Task.isCancelled {
                        self.onState?("Diagnostic adapter reconnecting")
                    }
                }

                guard !Task.isCancelled && self.generation == currentGeneration else { return }
                self.onState?("Diagnostic adapter retrying in \(backoff)s")
                do {
                    try await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                } catch {
                    return
                }
                backoff = min(30, backoff * 2)
            }
        }
    }

    func stop() {
        generation = UUID()
        let pending = task
        pending?.cancel()
        task = nil
        let ownedScheduler = scheduler
        let previousStop = stopping
        scheduler = nil
        stopping = Task {
            await previousStop?.value
            await ownedScheduler?.stop()
            await pending?.value
        }
        onAcquiringChanged?(false)
        onState?("Adapter disconnected")
    }

    // Late completion belongs to its frozen audit scope. The recording-window
    // receiver decides admission; it cannot mutate a new live capability scope.
    private func deliverAudit(_ event: DiagnosticAuditEvent) { onAudit?(event) }
    private func deliverAuditError(_ receipt: DiagnosticAuditFailureReceipt) { onAuditError?(receipt) }

    private static func errorText(_ error: OBDQuerySessionError) -> String {
        switch error {
        case .response(.noData): return "no data"
        case .response(.negativeResponse(let code)): return String(format: "negative response 0x%02X", code)
        case .unsupportedCommand: return "unsupported command"
        case .timeout: return "timeout"
        case .bufferFull: return "buffer full"
        case .transport: return "transport error"
        case .disconnected: return "disconnected"
        case .invalidState: return "invalid state"
        case .response: return "malformed response"
        case .decode: return "decode error"
        }
    }
}
