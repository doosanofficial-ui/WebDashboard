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
        guard !profile.signals.isEmpty else {
            onState?("Live adapter profile invalid")
            return
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        onState?("Live adapter starting")
        task = Task { [weak self] in
            guard let self else { return }
            var backoff: UInt64 = 1

            while !Task.isCancelled && self.generation == currentGeneration {
                var reconnectState = "Live adapter reconnecting"
                do {
                    // A transport's stream is terminal after close. Recreate
                    // both transport and session for every recovery attempt.
                    let transport = try Self.makeTransport(profile)
                    let session = ELM327Session(
                        transport: transport,
                        sourceAdapter: profile.name,
                        sourceTransport: profile.transport.rawValue
                    )
                    let stream = await session.frames()
                    let reader = Task { [weak self] in
                        for await frame in stream {
                            guard let self else { return }
                            let decoded = profile.signals.compactMap { definition -> LiveDecodedSignal? in
                                guard let value = try? SignalDecoder.decode(frame, definition: definition) else { return nil }
                                return (definition: definition, decoded: value)
                            }
                            guard self.generation == currentGeneration else { return }
                            // Raw frames are forwarded even when no configured
                            // signal matches; the model owns the logging policy.
                            self.onFrame?(frame, decoded)
                        }
                    }

                    do {
                        try await session.start()
                        guard self.generation == currentGeneration else {
                            reader.cancel()
                            await session.stop()
                            return
                        }
                        self.onState?("Live adapter monitoring")
                        backoff = 1
                        while !Task.isCancelled && self.generation == currentGeneration {
                            try await Task.sleep(nanoseconds: 250_000_000)
                            if await session.state == .recovering {
                                reconnectState = Self.errorState(await session.lastError)
                                break
                            }
                        }
                    } catch is CancellationError {
                        reader.cancel()
                        await reader.value
                        await session.stop()
                        return
                    } catch {
                        reconnectState = "Live adapter error"
                    }
                    reader.cancel()
                    await reader.value
                    await session.stop()
                } catch is CancellationError {
                    return
                } catch {
                    reconnectState = "Live adapter profile or transport error"
                }

                guard !Task.isCancelled && self.generation == currentGeneration else { return }
                self.onState?("\(reconnectState); retrying in \(backoff)s")
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

    private static func makeTransport(_ profile: AdapterProfile) throws -> any CANTransport {
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
