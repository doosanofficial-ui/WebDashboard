import XCTest
@testable import TelemetryCore

final class RuntimeEventTests: XCTestCase {
    func testAdapterStatesMapToStableRecordingEvents() {
        XCTAssertEqual(AdapterRuntimeEvent(state: "Live adapter starting"), .starting)
        XCTAssertEqual(AdapterRuntimeEvent(state: "Live adapter monitoring"), .monitoring)
        XCTAssertEqual(AdapterRuntimeEvent(state: "Live adapter recovering: buffer full; retrying in 2s"), .reconnecting)
        XCTAssertEqual(AdapterRuntimeEvent(state: "Adapter disconnected"), .disconnected)
        XCTAssertEqual(AdapterRuntimeEvent(state: "Live adapter profile invalid"), .error)
    }
}
