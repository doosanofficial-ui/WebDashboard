import XCTest
@testable import TelemetryCore

final class TelemetryStoreTests: XCTestCase {
    private func frame() throws -> CANFrame {
        try CANFrame(
            receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 1_000,
            canID: 0x123,
            isExtended: false,
            dlc: 2,
            payload: [0x34, 0x12],
            sourceAdapter: "mock",
            sourceTransport: "test",
            sequence: 7
        )
    }

    private func sample(value: Double = 42, timestamp: Double = 100) -> DecodedSignalSample {
        DecodedSignalSample(
            signalID: "vehicle.speed",
            value: value,
            rawValue: 42,
            enumName: nil,
            unit: "km/h",
            frameSequence: 7,
            receivedAtEpoch: timestamp,
            receivedAtMonotonicNanos: 1_000
        )
    }

    func testLatestSignalAndFrameAreUpdatedWithValidQuality() async throws {
        let store = TelemetryStore(signalTimeouts: ["vehicle.speed": 0.5])
        let can = try frame()
        await store.ingest(frame: can)
        await store.ingest(signal: sample())

        let latest = await store.signalState(for: "vehicle.speed", now: 100.1)
        XCTAssertEqual(latest?.quality, .valid)
        XCTAssertEqual(latest?.value, 42)
        XCTAssertEqual(latest?.frameSequence, 7)
        let latestFrame = await store.latestFrame()
        XCTAssertEqual(latestFrame, can)
    }

    func testSignalBecomesStaleAfterConfiguredTimeout() async {
        let store = TelemetryStore(signalTimeouts: ["vehicle.speed": 0.5])
        await store.ingest(signal: sample())

        let stale = await store.signalState(for: "vehicle.speed", now: 100.6)
        XCTAssertEqual(stale?.quality, .stale)
        XCTAssertEqual(stale?.value, 42)
    }

    func testDisconnectMarksSignalsDisconnectedWithoutInventingAValue() async {
        let store = TelemetryStore(signalTimeouts: ["vehicle.speed": 0.5])
        await store.ingest(signal: sample())
        await store.disconnect()

        let disconnected = await store.signalState(for: "vehicle.speed", now: 100.1)
        XCTAssertEqual(disconnected?.quality, .disconnected)
        XCTAssertEqual(disconnected?.value, 42)
    }

    func testLocationKeepsOriginalAndPhoneReceiveTimesSeparate() async {
        let store = TelemetryStore()
        let location = LocationSample(
            originalTimestamp: 90,
            receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 2_000,
            latitude: 37.5,
            longitude: 127.0,
            altitude: 12,
            speed: 10,
            course: 180,
            horizontalAccuracy: 4,
            verticalAccuracy: 7
        )
        await store.ingest(location: location)

        let latestLocation = await store.latestLocation()
        XCTAssertEqual(latestLocation, location)
    }
}
