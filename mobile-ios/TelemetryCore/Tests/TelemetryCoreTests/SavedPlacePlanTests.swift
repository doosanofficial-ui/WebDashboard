import XCTest
@testable import TelemetryCore

final class SavedPlacePlanTests: XCTestCase {
    func record(_ id: String = "a", kind: SavedPlace.Kind = .home, label: String = "Synthetic Home", lat: Double = 1, lon: Double = 2) throws -> SavedPlace {
        try SavedPlace(id: id, kind: kind, label: label, latitude: lat, longitude: lon)
    }
    func raw(_ records: [SavedPlace]? = nil, revision: UInt64 = 0) throws -> Data {
        try JSONEncoder().encode(SavedPlaceSnapshot(revision: revision, places: records ?? [record()]))
    }
    func testDecodeExactSource() throws {
        var data = Data("  ".utf8); data.append(try raw())
        let s = try SavedPlaceSnapshot.decodeLocal(data)
        XCTAssertEqual(s.source, data); XCTAssertEqual(s.places.first?.id, "a")
    }
    func testInvalidSchema() {
        for text in ["{}", "{\"version\":2,\"revision\":0,\"places\":[]}",
                     "{\"version\":true,\"revision\":0,\"places\":[]}",
                     "{\"version\":1,\"revision\":0,\"places\":[],\"unknown\":1}",
                     "{\"version\":1,\"revision\":-1,\"places\":[]}",
                     "{\"version\":1,\"revision\":9007199254740992,\"places\":[]}"] {
            XCTAssertThrowsError(try SavedPlaceSnapshot.decodeLocal(Data(text.utf8)))
        }
    }
    func testDuplicateJSONKeys() {
        for text in ["{\"version\":1,\"version\":1,\"revision\":0,\"places\":[]}",
                     "{\"version\":1,\"revision\":0,\"places\":[{\"id\":\"a\",\"id\":\"a\",\"kind\":\"home\",\"label\":\"Synthetic\",\"latitude\":1,\"longitude\":2}]}"] {
            XCTAssertThrowsError(try SavedPlaceSnapshot.decodeLocal(Data(text.utf8)))
        }
    }
    func testBadRecord() throws {
        XCTAssertThrowsError(try record("")); XCTAssertThrowsError(try record(String(repeating: "a", count: 65)))
        XCTAssertThrowsError(try record(label: "https://x")); XCTAssertThrowsError(try record(label: String(repeating: "a", count: 81)))
        XCTAssertThrowsError(try record(lat: 91)); XCTAssertThrowsError(try record(lon: 181)); XCTAssertThrowsError(try record(lat: .nan))
        for fragment in ["\"latitude\":true", "\"kind\":\"office\""] {
            let text = "{\"id\":\"a\",\"kind\":\"home\",\"label\":\"Synthetic\",\"latitude\":1,\"longitude\":2}"
            let modified = fragment.hasPrefix("\"latitude") ? text.replacingOccurrences(of: "\"latitude\":1", with: fragment) : text.replacingOccurrences(of: "\"kind\":\"home\"", with: fragment)
            XCTAssertThrowsError(try JSONDecoder().decode(SavedPlace.self, from: Data(modified.utf8)))
        }
    }
    func testDuplicatesAndLimit() throws {
        XCTAssertThrowsError(try SavedPlaceSnapshot(revision: 0, places: [record(),record()]))
        XCTAssertThrowsError(try SavedPlaceSnapshot(revision: 0, places: [record(),record("b")]))
        XCTAssertThrowsError(try SavedPlaceSnapshot(revision: 0, places: [record(kind: .other),record(kind: .other)]))
        let many = try (0..<129).map { try record(String($0), kind: .other) }
        XCTAssertThrowsError(try SavedPlaceSnapshot(revision: 0, places: many))
    }
    func testAddPreservesSourceAndUnrelated() throws {
        let s = try SavedPlaceSnapshot.decodeLocal(raw())
        let p = try s.plan(expectedRevision: 0, operation: .add(record("b", kind: .work)))
        XCTAssertEqual(s.revision, 0); XCTAssertEqual(s.places.count, 1); XCTAssertEqual(p.revision, 1)
        XCTAssertEqual(p.places.first, s.places.first); XCTAssertNil(p.source)
    }
    func testEditOnlySelected() throws {
        let s = try SavedPlaceSnapshot(revision: 0, places: [record(),record("b",kind: .work)])
        let p = try s.plan(expectedRevision: 0, operation: .edit(record(label: "New Synthetic")))
        XCTAssertEqual(p.places.count, s.places.count); XCTAssertEqual(p.places[0].label, "New Synthetic"); XCTAssertEqual(p.places[1], s.places[1])
    }
    func testRemovePlanOnly() throws {
        let s = try SavedPlaceSnapshot(revision: 0, places: [record(),record("b",kind: .work)])
        let p = try s.plan(expectedRevision: 0, operation: .remove(id: "a"))
        XCTAssertEqual(p.places.map(\.id), ["b"]); XCTAssertEqual(s.places.count, 2)
    }
    func testRevisionOperationConflict() throws {
        let s = try SavedPlaceSnapshot(revision: 0, places: [record()])
        XCTAssertThrowsError(try s.plan(expectedRevision: 1, operation: .remove(id: "a")))
        XCTAssertThrowsError(try s.plan(expectedRevision: 0, operation: .remove(id: "absent")))
        XCTAssertThrowsError(try s.plan(expectedRevision: 0, operation: .edit(record("absent"))))
        XCTAssertThrowsError(try s.plan(expectedRevision: 0, operation: .add(record())))
    }
    func testRevisionExhaustion() throws {
        let s = try SavedPlaceSnapshot(revision: SavedPlaceSnapshot.maximumRevision, places: [record()])
        XCTAssertThrowsError(try s.plan(expectedRevision: s.revision, operation: .remove(id: "a")))
    }

    func testKoreanLabelsPreserveExactText() throws {
        for label in ["합성 집", "합성 직장 (2)", "  서울-시험 장소  ", "家 １２٣"] {
            XCTAssertEqual(Array(try record(label: label).label.utf8), Array(label.utf8))
        }
    }
    func testDecomposedMarksPreserved() throws {
        for label in ["e\u{0301}", "\u{1100}\u{1161}", "가\u{0301}", "\u{0301}"] {
            XCTAssertEqual(Array(try record(label: label).label.utf8), Array(label.utf8))
        }
    }
    func testUnicodeScalarAndByteBoundaries() throws {
        for label in [String(repeating: "가", count: 80), String(repeating: "\u{10400}", count: 80), String(repeating: "e\u{0301}", count: 40)] {
            XCTAssertEqual(Array(try record(label: label).label.utf8), Array(label.utf8))
        }
        for label in [String(repeating: "가", count: 81), String(repeating: "\u{10400}", count: 81), String(repeating: "e\u{0301}", count: 40) + "e"] {
            XCTAssertThrowsError(try record(label: label))
        }
    }
    func testControlsFormatsAndBidiRejected() {
        for scalar in ["\u{0}", "\n", "\t", "\u{7f}", "\u{85}", "\u{202e}", "\u{202a}", "\u{2066}", "\u{2069}", "\u{200d}", "\u{200b}", "\u{feff}", "\u{ad}"] {
            XCTAssertThrowsError(try record(label: "집" + scalar))
        }
    }
    func testMalformedSurrogatesRejected() throws {
        let original = String(decoding: try raw(), as: UTF8.self)
        for escaped in ["\\ud800", "\\udfff", "집\\ud800"] {
            let bad = original.replacingOccurrences(of: "Synthetic Home", with: escaped)
            XCTAssertThrowsError(try SavedPlaceSnapshot.decodeLocal(Data(bad.utf8)))
        }
    }
    func testURLAndNonDisplaySyntaxRejected() {
        for label in ["https://집", "집/직장", "집\\직장", "집:직장", "집@직장", "%2F", "<집>", "집?", "집#", "집=", "😀", " ", "\u{a0}"] {
            XCTAssertThrowsError(try record(label: label))
        }
    }
    func testJSONImportByteBoundaries() throws {
        var data = try raw([record(label: String(repeating: "가", count: 80))])
        data.append(Data(repeating: 32, count: 65_536 - data.count))
        XCTAssertEqual(try SavedPlaceSnapshot.decodeLocal(data).places.first?.label, String(repeating: "가", count: 80))
        data.append(32)
        XCTAssertThrowsError(try SavedPlaceSnapshot.decodeLocal(data))
    }
    func testUnicodeLabelDoesNotRelaxIDs() {
        for id in ["집", "e\u{301}", "a b", "a/b"] { XCTAssertThrowsError(try record(id)) }
    }
}
