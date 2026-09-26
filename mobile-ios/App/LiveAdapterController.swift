import CoreBluetooth
import Foundation
import TelemetryCore

enum LiveAdapterError: Error {
    case noSignal
    case invalidWiFiProfile
    case invalidBLEProfile
}

typealias LiveDecodedSignal = (definition: SignalDefinition, decoded: DecodedSignal)

@MainActor
final class LiveAdapterController {
    var onState: ((String) -> Void)?
    var onFrame: ((CANFrame, [LiveDecodedSignal]) -> Void)?

    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start(profile: AdapterProfile) {
        stop()
        do {
            guard !profile.signals.isEmpty else { throw LiveAdapterError.noSignal }
            let transport = try makeTransport(profile)
            let session = ELM327Session(
                transport: transport,
                sourceAdapter: profile.name,
                sourceTransport: profile.transport.rawValue
            )
            let currentGeneration = UUID()
            generation = currentGeneration
            onState?("Live adapter starting")
            task = Task { [weak self] in
                guard let self else { return }
                let stream = await session.frames()
                let reader = Task { [weak self] in
                    for await frame in stream {
                        guard let self else { continue }
                        let decoded = profile.signals.compactMap { definition -> LiveDecodedSignal? in
                            guard let value = try? SignalDecoder.decode(frame, definition: definition) else { return nil }
                            return (definition: definition, decoded: value)
                        }
                        guard !decoded.isEmpty else { continue }
                        guard self.generation == currentGeneration else { return }
                        self.onFrame?(frame, decoded)
                    }
                }
                var terminalState: String?
                do {
                    try await session.start()
                    if self.generation == currentGeneration { self.onState?("Live adapter monitoring") }
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 250_000_000)
                        if await session.state == .recovering {
                            terminalState = Self.errorState(await session.lastError)
                            break
                        }
                    }
                } catch is CancellationError {
                    // Stop is an expected terminal path.
                } catch {
                    terminalState = "Live adapter error"
                }
                reader.cancel()
                await reader.value
                await session.stop()
                guard self.generation == currentGeneration else { return }
                if let terminalState { self.onState?(terminalState) }
                else if !Task.isCancelled { self.onState?("Live adapter stopped") }
            }
        } catch {
            onState?("Live adapter profile invalid")
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        onState?("Adapter disconnected")
    }

    private static func errorState(_ error: ELM327SessionError?) -> String {
        switch error {
        case .bufferFull: return "Live adapter recovering: buffer full"
        case .malformedFrame: return "Live adapter recovering: malformed frame"
        case .unsupportedCommand: return "Live adapter recovering: unsupported command"
        case .timeout: return "Live adapter recovering: timeout"
        case .disconnected: return "Live adapter recovering: disconnected"
        case .transport: return "Live adapter recovering: transport error"
        case .invalidState: return "Live adapter recovering: invalid state"
        case nil: return "Live adapter recovering"
        }
    }

    private func makeTransport(_ profile: AdapterProfile) throws -> any CANTransport {
        switch profile.transport {
        case .wifi:
            guard let host = profile.host, let port = profile.port else {
                throw LiveAdapterError.invalidWiFiProfile
            }
            return try WiFiTransport(host: host, port: UInt16(port))
        case .ble:
            guard let peripheralID = profile.peripheralID,
                  let serviceUUID = profile.serviceUUID,
                  let writeUUID = profile.writeCharacteristicUUID,
                  let notifyUUID = profile.notifyCharacteristicUUID,
                  !serviceUUID.isEmpty, !writeUUID.isEmpty, !notifyUUID.isEmpty else {
                throw LiveAdapterError.invalidBLEProfile
            }
            return BLETransport(
                targetPeripheralID: peripheralID,
                serviceUUID: CBUUID(string: serviceUUID),
                writeUUID: CBUUID(string: writeUUID),
                notifyUUID: CBUUID(string: notifyUUID)
            )
        }
    }
}
