import Foundation
import TelemetryCore

@MainActor
final class DiagnosticAdapterController {
    var onState: ((String) -> Void)?
    var onResult: ((OBDQueryResult) -> Void)?

    private var task: Task<Void, Never>?
    private var scheduler: OBDQueryScheduler?
    private var generation = UUID()

    func start(profile: AdapterProfile) {
        stop()
        guard !profile.diagnosticQueries.isEmpty else {
            onState?("Diagnostic profile has no queries")
            return
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        onState?("Diagnostic adapter starting")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var backoff: UInt64 = 1
            while !Task.isCancelled && self.generation == currentGeneration {
                do {
                    let transport = try LiveAdapterController.makeTransport(profile)
                    let session = OBDQuerySession(
                        transport: transport,
                        sourceAdapter: profile.name,
                        sourceTransport: profile.transport.rawValue
                    )
                    let scheduler = OBDQueryScheduler(session: session)
                    self.scheduler = scheduler
                    let stream = try await scheduler.start(queries: profile.diagnosticQueries)
                    self.onState?("Diagnostic query monitoring")
                    backoff = 1

                    for await outcome in stream {
                        guard !Task.isCancelled, self.generation == currentGeneration else { break }
                        switch outcome {
                        case .success(let result):
                            self.onResult?(result)
                        case .failure(let queryID, let error):
                            self.onState?("Diagnostic \(queryID): \(Self.errorText(error))")
                        }
                    }
                    await scheduler.stop()
                    self.scheduler = nil
                } catch is CancellationError {
                    return
                } catch {
                    self.onState?("Diagnostic adapter reconnecting")
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
        task?.cancel()
        task = nil
        if let scheduler {
            Task { await scheduler.stop() }
        }
        scheduler = nil
        onState?("Adapter disconnected")
    }

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
