import Foundation
import TelemetryCore

@MainActor
final class DemoAdapterController {
    var onState: ((String) -> Void)?
    var onFrame: ((CANFrame, DecodedSignal) -> Void)?

    private var transport: MockCANTransport?
    private var session: ELM327Session?
    private var task: Task<Void, Never>?

    func start() {
        stop()
        let transport = MockCANTransport()
        let session = ELM327Session(transport: transport, sourceAdapter: "demo", sourceTransport: "mock")
        self.transport = transport
        self.session = session
        onState?("Demo adapter starting")

        task = Task { [weak self] in
            guard let self else { return }
            let stream = await session.frames()
            let reader = Task { [weak self] in
                for await frame in stream {
                    guard let self,
                          let definition = try? SignalDefinition(
                            id: "demo.signal",
                            name: "Demo Signal",
                            canID: 0x123,
                            isExtended: false,
                            startBit: 0,
                            bitLength: 16,
                            byteOrder: .intel,
                            isSigned: false,
                            factor: 0.1,
                            offset: 0,
                            minimum: 0,
                            maximum: 6553.5,
                            unit: "demo",
                            timeout: 0.5
                          ),
                          let decoded = try? SignalDecoder.decode(frame, definition: definition) else { continue }
                    self.onFrame?(frame, decoded)
                }
            }
            do {
                let start = Task { try await session.start() }
                try await waitForWrites(1, transport: transport)
                await transport.push(Data("OK\r>".utf8))
                try await waitForWrites(2, transport: transport)
                await transport.push(Data("OK\r>".utf8))
                try await waitForWrites(3, transport: transport)
                await transport.push(Data("OK\r>".utf8))
                try await start.value
                onState?("Demo adapter monitoring")

                var tick = 0
                while !Task.isCancelled {
                    let raw = UInt16(1_000 + (tick % 300) * 5)
                    let high = UInt8(raw >> 8)
                    let low = UInt8(raw & 0xFF)
                    await transport.push(Data(String(format: "123 %02X %02X\r", high, low).utf8))
                    tick += 1
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch is CancellationError {
                // Stop is an expected terminal path.
            } catch {
                onState?("Demo adapter error")
            }
            reader.cancel()
            await session.stop()
            onState?("Demo adapter stopped")
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        session = nil
        transport = nil
        onState?("Adapter disconnected")
    }

    private func waitForWrites(_ count: Int, transport: MockCANTransport) async throws {
        for _ in 0..<100 {
            if await transport.writes().count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }
}
