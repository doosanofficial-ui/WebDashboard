// PREPARED ONLY: XCTest not compiled or executed.
import XCTest
@testable import TelemetryCore

final class VehicleDisplayMetadataTests: XCTestCase {
    func testUnknownDefaultsAndHEV() throws {
        let m = try VehicleDisplayMetadata()
        XCTAssertEqual([m.fuel, m.powertrain, m.gearbox, m.turbo], Array(repeating: "unknown", count: 4))
        XCTAssertNil(m.redlineLabelRPM)
        let hev = try VehicleDisplayMetadata(fuel: "mixed", powertrain: "hev", gearbox: "ecvt", turbo: "mixed")
        XCTAssertEqual(hev.powertrain, "hev")
        XCTAssertNoThrow(try VehicleDisplayMetadata(powertrain: "phev"))
    }
    func testChoicesAndLabelBounds() throws {
        XCTAssertThrowsError(try VehicleDisplayMetadata(fuel: "https://host"))
        XCTAssertThrowsError(try VehicleDisplayMetadata(powertrain: "diesel-default"))
        XCTAssertThrowsError(try VehicleDisplayMetadata(gearbox: ""))
        XCTAssertThrowsError(try VehicleDisplayMetadata(turbo: "secret"))
        for n in [-1, 0, 100001] { XCTAssertThrowsError(try VehicleDisplayMetadata(redlineLabelRPM: n)) }
        XCTAssertNoThrow(try VehicleDisplayMetadata(redlineLabelRPM: 1))
        XCTAssertNoThrow(try VehicleDisplayMetadata(redlineLabelRPM: 100000))
    }
    func testRoundTripAndBounds() throws {
        let doc = try VehicleDisplayMetadataDocument(metadata: VehicleDisplayMetadata(powertrain: "hev", redlineLabelRPM: 6500), revision: 7)
        XCTAssertEqual(try VehicleDisplayMetadataDocument.decode(doc.encoded()), doc)
        XCTAssertThrowsError(try VehicleDisplayMetadataDocument(metadata: doc.metadata, revision: -1))
        XCTAssertThrowsError(try VehicleDisplayMetadataDocument(metadata: doc.metadata, schemaVersion: 2))
        XCTAssertThrowsError(try VehicleDisplayMetadataDocument.decode(Data(repeating: 32, count: 4097)))
    }
    func testStrictShapeAndBooleanNumericRejection() throws {
        let doc = try VehicleDisplayMetadataDocument.empty()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: doc.encoded()) as? [String: Any])
        let invalidFields: [(String, Any)] = [("VIN", "secret"), ("revision", true), ("schemaVersion", 2), ("metadata", [Any]())]
        for pair in invalidFields {
            var object = original; object[pair.0] = pair.1
            XCTAssertThrowsError(try VehicleDisplayMetadataDocument.decode(JSONSerialization.data(withJSONObject: object)))
        }
        let invalidLabels: [Any] = [true, 1.5, "6500", 0, 100001]
        for value in invalidLabels {
            var object = original
            var metadata = try XCTUnwrap(object["metadata"] as? [String: Any])
            metadata["redlineLabelRPM"] = value; object["metadata"] = metadata
            XCTAssertThrowsError(try VehicleDisplayMetadataDocument.decode(JSONSerialization.data(withJSONObject: object)))
        }
        var object = original
        var metadata = try XCTUnwrap(object["metadata"] as? [String: Any])
        metadata["url"] = "https://host"; object["metadata"] = metadata
        XCTAssertThrowsError(try VehicleDisplayMetadataDocument.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testEditResetImportArePureAndMonotonic() throws {
        let doc = try VehicleDisplayMetadataDocument.empty()
        let m = try VehicleDisplayMetadata(powertrain: "hev")
        let p = try doc.editPlan(scope: "context-a", metadata: m)
        XCTAssertEqual(doc.revision, 0)
        let new = try doc.applying(p, currentScope: "context-a")
        XCTAssertEqual(new.metadata, m); XCTAssertEqual(new.revision, 1)
        let reset = try new.applying(new.resetPlan(scope: "context-a"), currentScope: "context-a")
        XCTAssertEqual(reset.metadata, try VehicleDisplayMetadata()); XCTAssertEqual(reset.revision, 2)
        let incoming = try VehicleDisplayMetadataDocument(metadata: m, revision: 900)
        let imported = try reset.applying(reset.importPlan(scope: "context-a", data: incoming.encoded()), currentScope: "context-a")
        XCTAssertEqual(imported.revision, 3); XCTAssertEqual(imported.metadata, m)
    }
    func testStaleContentRevisionReplayAndScope() throws {
        let doc = try VehicleDisplayMetadataDocument.empty()
        let p = try doc.resetPlan(scope: "a")
        XCTAssertThrowsError(try doc.applying(p, currentScope: "b"))
        let new = try doc.applying(p, currentScope: "a")
        XCTAssertThrowsError(try new.applying(p, currentScope: "a"))
        let changed = try VehicleDisplayMetadataDocument(metadata: VehicleDisplayMetadata(powertrain: "hev"))
        XCTAssertThrowsError(try changed.applying(p, currentScope: "a"))
        for scope in ["", "a/b", "a\n", "https://host", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try doc.resetPlan(scope: scope))
        }
        let full = try VehicleDisplayMetadataDocument(metadata: doc.metadata, revision: 1000000000)
        XCTAssertThrowsError(try full.resetPlan(scope: "a"))
    }
}
