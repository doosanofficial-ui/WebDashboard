import XCTest
@testable import TelemetryCore

final class CANSignalPipelineTests: XCTestCase {
    private func definition(id: String = "vehicle.speed") throws -> SignalDefinition {
        try SignalDefinition(
            id: id,
            name: "Vehicle speed",
            canID: 0x123,
            isExtended: false,
            startBit: 0,
            bitLength: 8,
            byteOrder: .intel,
            isSigned: false,
            factor: 0.5,
            offset: 0,
            minimum: 0,
            maximum: 127.5,
            unit: "km/h",
            timeout: 0.5
        )
    }

    private func frame(canID: UInt32 = 0x123) throws -> CANFrame {
        try CANFrame(
            receivedAtEpoch: 100,
            receivedAtMonotonicNanos: 2_000,
            canID: canID,
            isExtended: false,
            dlc: 1,
            payload: [80],
            sourceAdapter: "recorded",
            sourceTransport: "mock",
            sequence: 9
        )
    }

    func testRecordedFrameProducesDecodedSampleForStoreAndRecorder() throws {
        let pipeline = try CANSignalPipeline(definitions: [definition()])
        let decoded = pipeline.decode(try frame())

        let item = try XCTUnwrap(decoded.first)
        XCTAssertEqual(item.definition.id, "vehicle.speed")
        XCTAssertEqual(item.decoded.value, 40)
        XCTAssertEqual(item.sample.signalID, "vehicle.speed")
        XCTAssertEqual(item.sample.unit, "km/h")
        XCTAssertEqual(item.sample.frameSequence, 9)
        XCTAssertEqual(item.sample.receivedAtEpoch, 100)
    }

    func testMismatchedFrameIsIgnoredWithoutDroppingPipelineAvailability() throws {
        let pipeline = try CANSignalPipeline(definitions: [definition()])
        XCTAssertTrue(pipeline.decode(try frame(canID: 0x321)).isEmpty)
    }

    func testDuplicateSignalIDsFailBeforeMonitoringStarts() throws {
        XCTAssertThrowsError(try CANSignalPipeline(definitions: [definition(), definition()])) { error in
            XCTAssertEqual(error as? CANSignalPipelineError, .duplicateSignalID("vehicle.speed"))
        }
    }
}
