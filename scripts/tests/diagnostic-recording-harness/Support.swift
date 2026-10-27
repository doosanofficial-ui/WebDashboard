import Foundation
import TelemetryCore

enum ProbeError: Error { case missingTransport, deadline }

// Only the physical adapter factory and UI projection are replaced. The full
// App diagnostic controller, callback bodies, recording methods and Core run.
@MainActor enum LiveAdapterController {
    static var transport: (any CANTransport)?
    static func makeTransport(_ profile: AdapterProfile) throws -> any CANTransport {
        guard let transport else { throw ProbeError.missingTransport }
        return transport
    }
}

@MainActor final class RecordingModel {
    let diagnosticAdapter = DiagnosticAdapterController()
    let telemetryStore = TelemetryStore()
    var runMode = TelemetryRunMode.live
    var adapterStatus = "Disconnected"
    var adapterSignalValue: Double?
    var localRecordingEnabled = false
    var localRecordingStatus = "Ready"
    var recordingClosing = false
    var recordingStartedAt: Date?
    var recordingLifecycle = RecordingLifecycle()
    var measurementDBURL: URL?
    var measurementContextGeneration = UUID()
    var selectedSavedSessionID: String?
    var localRecorder: MeasurementRecorder?
    var completedRecorder: MeasurementRecorder?
    var recordingWriteQueue: MeasurementWriteQueue?
    var renderedSignals: [String: Double] = [:]
    var callbackReturned: ((String, String) -> Void)?
    var projectionReturned: (() -> Void)?

    init(path: URL) {
        measurementDBURL = path
        // PRODUCTION_BINDINGS
    }

    func publishCarPlayProjection() { projectionReturned?() }
    func applyLocalDiagnosticSignals(values: [String: Double], rawValues: [String: UInt64],
        source: String, sequence: UInt64, timestamp: Double, responseCANID: UInt32) {
        renderedSignals = values
    }
    // PRODUCTION_METHODS
}

actor DiagnosticTransport: CANTransport {
    private let stream: AsyncThrowingStream<Data, Error>
    private let output: AsyncThrowingStream<Data, Error>.Continuation
    private let closed: AsyncStream<Void>
    private let closedOutput: AsyncStream<Void>.Continuation
    private var connected = false
    private var recorded: [String] = []
    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream; output = pair.continuation
        let stop = AsyncStream<Void>.makeStream()
        closed = stop.stream; closedOutput = stop.continuation
    }
    func incoming() async -> AsyncThrowingStream<Data, Error> { stream }
    func connect() async throws { connected = true }
    func close() async {
        connected = false; output.finish()
        closedOutput.yield(()); closedOutput.finish()
    }
    func write(_ data: Data) async throws {
        guard connected else { throw CANTransportError.notConnected }
        let text = String(decoding: data, as: UTF8.self)
        recorded.append(text)
        let reply: String
        if text.hasPrefix("AT ") { reply = "OK\r>" }
        else if text == "0100\r" { reply = "7E8 06 41 00 B6 3F A8 13\r>" }
        else if text == "220101\r" { reply = "7EC 08 62 01 01 00 00 00 00 64\r>" }
        else { reply = "NO DATA\r>" }
        output.yield(Data(reply.utf8))
    }
    func pushLateReply() { output.yield(Data("NO DATA\r>".utf8)) }
    func writes() -> [String] { recorded }
    func closeEvents() -> AsyncStream<Void> { closed }
}

func waitFor(_ stream: AsyncStream<Void>) async throws {
    try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask { for await _ in stream { return true }; return false }
        group.addTask { try await Task.sleep(nanoseconds: 5_000_000_000); throw ProbeError.deadline }
        defer { group.cancelAll() }
        guard try await group.next() == true else { throw ProbeError.deadline }
    }
}
