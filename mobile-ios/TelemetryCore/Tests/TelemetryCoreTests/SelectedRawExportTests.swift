import XCTest
@testable import TelemetryCore

final class SelectedRawExportTests: XCTestCase {
    private func record(_ id: String = "a", _ bytes: Data = Data("GPS,VIN".utf8), revision: String = "r", mode: String = "LIVE", format: SelectedRawFormat = .nativeJSON) -> SelectedRawRecord {
        SelectedRawRecord(id: id, revision: revision, nativeMode: mode, format: format, content: bytes)
    }
    private func snapshot(_ records: [SelectedRawRecord], scope: String = "archive", revision: String = "1") -> SelectedRawSnapshot {
        SelectedRawSnapshot(scope: scope, revision: revision, records: records)
    }
    private func bundle(_ records: [SelectedRawRecord]) throws -> SelectedRawBundle {
        let s = snapshot(records)
        return try XCTUnwrap(SelectedRawExport.build(SelectedRawExport.select(s, ids: records.map(\.id)), current: s))
    }
    func testDefaultEmpty() throws {
        let s = snapshot([record()]); XCTAssertNil(try SelectedRawExport.build(SelectedRawExport.select(s), current: s))
    }
    func testExactPreviewSelection() throws {
        let a = record(); let b = record("b", Data([0,255,1]), mode: "DEMO", format: .nativeCSV)
        let s = snapshot([a,b]); let out = try XCTUnwrap(SelectedRawExport.build(SelectedRawExport.select(s, ids: ["b"]), current: s))
        XCTAssertEqual(out.entries.count,1); XCTAssertEqual(out.entries[0].record,b)
        XCTAssertEqual(out.entries[0].byteCount,3); XCTAssertEqual(out.entries[0].name,"raw-0001.csv")
        XCTAssertEqual(out.scope,"archive"); XCTAssertEqual(out.revision,"1")
    }
    func testDeterministicOrdering() throws {
        XCTAssertEqual(try bundle([record("b"),record("a")]).archive, try bundle([record("a"),record("b")]).archive)
    }
    func testStaleScopeAndRevision() throws {
        let a = record(); let p = try SelectedRawExport.select(snapshot([a]), ids:["a"])
        for s in [snapshot([a],scope:"other"),snapshot([a],revision:"2"),snapshot([])] {
            XCTAssertThrowsError(try SelectedRawExport.build(p,current:s))
        }
    }
    func testStaleBytesAndProvenance() throws {
        let p = try SelectedRawExport.select(snapshot([record()]),ids:["a"])
        for a in [record("a",Data([4])),record(revision:"new"),record(mode:"DEMO"),record(format:.nativeCSV)] {
            XCTAssertThrowsError(try SelectedRawExport.build(p,current:snapshot([a])))
        }
    }
    func testDuplicatesAndMissing() throws {
        let s = snapshot([record()])
        XCTAssertThrowsError(try SelectedRawExport.select(s,ids:["a","a"]))
        XCTAssertThrowsError(try SelectedRawExport.select(s,ids:["missing"]))
        XCTAssertThrowsError(try SelectedRawExport.select(snapshot([record(),record()]),ids:["a"]))
    }
    func testGeneratedNames() throws {
        for id in ["../../secret","https://example.com/a","/tmp/a","a\\b"] {
            XCTAssertEqual(try bundle([record(id)]).entries[0].name,"raw-0001.json")
        }
    }
    func testLimits() throws {
        XCTAssertThrowsError(try bundle((0..<33).map { record(String($0)) }))
        XCTAssertThrowsError(try bundle([record("a",Data(repeating:0,count:1_048_577))]))
        XCTAssertThrowsError(try bundle((0..<9).map { record(String($0),Data(repeating:0,count:1_048_576)) }))
    }
    func testInvalidMetadataAndUnicodeIdentity() throws {
        for a in [record(""),record(revision:""),record(mode:""),record("\0")] {
            XCTAssertThrowsError(try bundle([a]))
        }
        let a = record("é"); let b = record("e\u{301}")
        XCTAssertEqual(try bundle([a,b]).entries.count,2)
    }
    func testWarningAndConsent() throws {
        let out = try bundle([record()]); XCTAssertFalse(out.authorizesSharing)
        for phrase in ["GPS","VIN","not encrypted","not anonymized","separate approval"] { XCTAssertTrue(out.warning.contains(phrase)) }
    }
    func testEmptyBytesAndHashVector() throws {
        let out = try bundle([record("a",Data())])
        XCTAssertEqual(out.entries[0].byteCount,0)
        XCTAssertEqual(out.entries[0].sha256,"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SelectedRawExport.crc32(Data("123456789".utf8)),0xcbf43926)
    }
    func testZIPLayout() throws {
        let out = try bundle([record()]); let bytes = [UInt8](out.archive)
        XCTAssertEqual(Array(bytes[0..<4]),[0x50,0x4b,0x03,0x04])
        XCTAssertEqual(Array(bytes[6..<10]),[0,8,0,0])
        XCTAssertEqual(Array(bytes[12..<14]),[33,0])
        XCTAssertEqual(Array(bytes.suffix(22).prefix(4)),[0x50,0x4b,0x05,0x06])
        let start = 30 + out.entries[0].name.utf8.count
        XCTAssertEqual(Data(bytes[start..<(start+out.entries[0].byteCount)]),out.entries[0].record.content)
    }
}
