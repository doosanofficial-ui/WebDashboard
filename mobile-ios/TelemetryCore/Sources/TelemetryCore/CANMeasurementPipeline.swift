import Foundation

public enum CANMeasurementPipelineError: Error, Equatable, Sendable {
    case alreadyStarted
}

/// End-to-end Core pipeline used by live and recorded/mock CAN sources.
public actor CANMeasurementPipeline {
    private let session: ELM327Session
    private let decoder: CANSignalPipeline
    private let store: TelemetryStore
    private let recorder: MeasurementRecorder?
    private var consumer: Task<Void, Never>?

    public private(set) var lastError: String?

    public init(
        session: ELM327Session,
        definitions: [SignalDefinition],
        store: TelemetryStore,
        recorder: MeasurementRecorder? = nil
    ) throws {
        self.session = session
        decoder = try CANSignalPipeline(definitions: definitions)
        self.store = store
        self.recorder = recorder
    }

    public func start() async throws {
        guard consumer == nil else { throw CANMeasurementPipelineError.alreadyStarted }
        lastError = nil
        let stream = await session.frames()
        consumer = Task { [weak self] in
            for await frame in stream {
                do {
                    _ = try await self?.ingest(frame)
                } catch {
                    await self?.record(error: error)
                }
            }
        }
        do {
            try await session.start()
        } catch {
            consumer?.cancel()
            consumer = nil
            await session.stop()
            throw error
        }
    }

    public func stop() async {
        consumer?.cancel()
        consumer = nil
        await session.stop()
    }

    @discardableResult
    public func ingest(_ frame: CANFrame) async throws -> [DecodedCANSignal] {
        let decoded = decoder.decode(frame)
        await store.ingest(frame: frame)
        for item in decoded {
            await store.ingest(signal: item.sample)
        }
        if let recorder {
            try await recorder.append(.can(frame: frame))
            for item in decoded {
                try await recorder.append(.signal(item.sample))
            }
        }
        return decoded
    }

    private func record(error: Error) {
        lastError = String(describing: error)
    }
}
