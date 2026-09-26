import Foundation
import XCTest
@testable import TelemetryCore

final class CarPlayProjectionTests: XCTestCase {
    func testProjectionStateRoundTripsOnlyGlanceableStatus() throws {
        let state = CarPlayProjectionState(
            adapterState: "connected",
            recordingState: "recording",
            profileName: "Santa Fe MX5 HEV",
            elapsedSeconds: 125,
            primaryValues: ["speed": 42.5, "yaw": 1.2]
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CarPlayProjectionState.self, from: data)

        XCTAssertEqual(decoded, state)
        XCTAssertLessThanOrEqual(decoded.primaryValues.count, 4)
        XCTAssertEqual(decoded.elapsedSeconds, 125)
    }

    func testProjectionStateCanRepresentDisconnectedAndIdleSafely() {
        let state = CarPlayProjectionState(
            adapterState: "disconnected",
            recordingState: "idle",
            profileName: "Unselected",
            elapsedSeconds: 0,
            primaryValues: [:]
        )
        XCTAssertEqual(state.adapterState, "disconnected")
        XCTAssertEqual(state.recordingState, "idle")
        XCTAssertTrue(state.primaryValues.isEmpty)
    }
}
