import Foundation

/// Product-facing bridge from the diagnostic scheduler to the store and
/// durable recorder. Raw CAN monitoring uses CANMeasurementPipeline instead;
/// the two pipelines intentionally remain separate.
public actor OBDMeasurementPipeline {
    private let scheduler: OBDQueryScheduler
    private let queries: [OBDQueryDefinition]
    private let store: TelemetryStore
    private let recorder: MeasurementRecorder?
    private var consumer: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?

    public private(set) var lastError: String?

    public init(
        session: OBDQuerySession,
        queries: [OBDQueryDefinition],
        store: TelemetryStore,
        recorder: MeasurementRecorder? = nil
    ) throws {
        guard !queries.isEmpty else { throw OBDQuerySessionError.invalidState }
        self.scheduler = OBDQueryScheduler(session: session)
        self.queries = queries
        self.store = store
        self.recorder = recorder
    }

    public func start() async throws {
        guard consumer == nil else { throw OBDQuerySessionError.invalidState }
        lastError = nil
        let timeouts = queries.reduce(into: [String: Double]()) { result, query in
            for signal in query.signals { result[signal.id] = signal.timeout }
        }
        await store.configureSignalTimeouts(
            timeouts
        )
        let stream = try await scheduler.start(queries: queries)
        consumer = Task { [weak self] in
            for await outcome in stream {
                guard let self else { return }
                await self.consume(outcome)
            }
        }
    }

    public func stop() async {
        if let shutdown { await shutdown.value; return }
        guard let pending = consumer else {
            await scheduler.stop()
            await store.disconnect()
            return
        }
        pending.cancel()
        let drain = Task { [scheduler, store] in
            await scheduler.stop()
            await pending.value
            await store.disconnect()
        }
        shutdown = drain
        await drain.value
        consumer = nil
        shutdown = nil
    }

    private func consume(_ outcome: OBDQueryOutcome) async {
        switch outcome {
        case .success(let result):
            await store.disconnect()
            for signal in result.signals {
                await store.ingest(diagnostic: signal)
            }
            do {
                if let recorder {
                    try await recorder.append(contentsOf: [.diagnosticResponse(result.response)]
                        + result.signals.map { .diagnosticSignal($0) })
                }
            } catch {
                lastError = "diagnostic recorder failure"
            }
        case .failure(let queryID, let error):
            let failure = DiagnosticQueryFailure(queryID: queryID, error: error)
            lastError = "diagnostic query \(queryID) failed: \(failure.errorCode)"
            if let recorder {
                let timestamp = Date().timeIntervalSince1970
                try? await recorder.append(.system(
                    name: failure.recordingName,
                    timestamp: timestamp,
                    monotonicNanos: DispatchTime.now().uptimeNanoseconds
                ))
            }
        }
    }

}
