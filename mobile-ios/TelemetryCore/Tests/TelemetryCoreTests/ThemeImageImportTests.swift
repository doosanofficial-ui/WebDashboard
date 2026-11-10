import Foundation
import XCTest
@testable import TelemetryCore

final class ThemeImageImportTests: XCTestCase {
    private let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private func word(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
    private func chunk(_ kind: String, _ payload: [UInt8] = []) -> [UInt8] {
        let body = Array(kind.utf8) + payload
        var crc = UInt32.max
        for byte in body {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
        }
        return word(UInt32(payload.count)) + body + word(crc ^ UInt32.max)
    }
    private func header(_ width: UInt32 = 2, _ height: UInt32 = 2,
                        color: UInt8 = 6, depth: UInt8 = 8, interlace: UInt8 = 0) -> [UInt8] {
        chunk("IHDR", word(width) + word(height) + [depth, color, 0, 0, interlace])
    }
    private func fixture(_ width: UInt32 = 2, _ height: UInt32 = 2,
                         color: UInt8 = 6, depth: UInt8 = 8, interlace: UInt8 = 0,
                         extra: [UInt8] = [], payload: [UInt8] = [120]) -> Data {
        Data(signature + header(width, height, color: color, depth: depth, interlace: interlace)
             + extra + chunk("IDAT", payload) + chunk("IEND"))
    }
    func testMinimalStructure() throws {
        let bytes = fixture(), manifest = try ThemePNGStructure.inspect(fixture())
        XCTAssertEqual(manifest.width, 2); XCTAssertEqual(manifest.height, 2)
        XCTAssertEqual(manifest.byteCount, bytes.count)
        XCTAssertEqual(manifest.sha256, "0d2fe82de43ecb35c4c05447652a890d0e3c4cf16be472882096d7c9a36d580f")
        XCTAssertTrue(manifest.requiresNativeDecode)
    }
    func testRGB() throws { XCTAssertEqual(try ThemePNGStructure.inspect(fixture(color: 2)).width, 2) }
    func testMetadataRejected() {
        for name in ["eXIf", "tEXt", "iTXt", "zTXt", "iCCP", "acTL", "fcTL", "fdAT", "PLTE"] {
            XCTAssertThrowsError(try ThemePNGStructure.inspect(fixture(extra: chunk(name, [1]))))
        }
    }
    func testBadCRC() {
        var bytes = fixture(); bytes[bytes.count - 1] ^= 1
        XCTAssertThrowsError(try ThemePNGStructure.inspect(bytes))
    }
    func testDimensions() {
        let pairs: [(UInt32, UInt32)] = [(0,1), (1,0), (4097,1), (2049,2048), (.max,1)]
        for (w,h) in pairs { XCTAssertThrowsError(try ThemePNGStructure.inspect(fixture(w,h))) }
    }
    func testModes() {
        for bytes in [fixture(color: 3), fixture(depth: 16), fixture(interlace: 1)] {
            XCTAssertThrowsError(try ThemePNGStructure.inspect(bytes))
        }
    }
    func testTruncatedAndTrailing() {
        let bytes = fixture()
        for value in [Data(), Data(bytes.prefix(7)), Data(bytes.dropLast()), bytes + Data([1]),
                      Data(signature + word(.max) + Array("IDAT".utf8))] {
            XCTAssertThrowsError(try ThemePNGStructure.inspect(value))
        }
    }
    func testOrder() {
        let h = header(1,1), id = chunk("IDAT", [120]), end = chunk("IEND")
        for body in [id+h+end, h+h+id+end, h+end, h+chunk("IDAT")+end, h+id+chunk("IEND", [1])] {
            XCTAssertThrowsError(try ThemePNGStructure.inspect(Data(signature+body)))
        }
    }
    func testBoundedSizeAndChunks() {
        XCTAssertThrowsError(try ThemePNGStructure.inspect(fixture(payload: [UInt8](repeating: 120, count: 8*1024*1024))))
        let many = (0..<1025).flatMap { _ in chunk("IDAT", [120]) }
        XCTAssertThrowsError(try ThemePNGStructure.inspect(fixture(extra: many)))
    }
    func testCorruptCompressedBytesNotClaimedDecoded() throws {
        XCTAssertTrue(try ThemePNGStructure.inspect(fixture(payload: Array("not-zlib".utf8))).requiresNativeDecode)
    }
    func testPreviewCommit() throws {
        var state = ThemeImageImport(); let g = try state.begin(currentThemeRevision: 4)
        let manifest = try state.stage(fixture(), generation: g)
        XCTAssertThrowsError(try state.commit(generation: g, currentThemeRevision: 4))
        try state.nativePreviewRendered(generation: g, sha256: manifest.sha256)
        XCTAssertEqual(try state.commit(generation: g, currentThemeRevision: 4), manifest)
        XCTAssertNil(state.candidate); XCTAssertEqual(state.phase, .idle)
        XCTAssertThrowsError(try state.commit(generation: g, currentThemeRevision: 4))
    }
    func testStaleGeneration() throws {
        var state = ThemeImageImport(); let old = try state.begin(currentThemeRevision: 1)
        let g = try state.begin(currentThemeRevision: 1)
        XCTAssertThrowsError(try state.stage(fixture(), generation: old))
        let m = try state.stage(fixture(), generation: g)
        XCTAssertThrowsError(try state.nativePreviewRendered(generation: old, sha256: m.sha256))
        XCTAssertThrowsError(try state.cancel(generation: old)); XCTAssertEqual(state.phase, .awaitingNativePreview)
    }
    func testDigestBinding() throws {
        var state = ThemeImageImport(); let g = try state.begin(currentThemeRevision: 1)
        _ = try state.stage(fixture(), generation: g)
        XCTAssertThrowsError(try state.nativePreviewRendered(generation: g, sha256: String(repeating: "0", count: 64)))
        XCTAssertEqual(state.phase, .awaitingNativePreview)
    }
    func testRevisionConflict() throws {
        var state = ThemeImageImport(); let g = try state.begin(currentThemeRevision: 1)
        let m = try state.stage(fixture(), generation: g)
        try state.nativePreviewRendered(generation: g, sha256: m.sha256)
        XCTAssertThrowsError(try state.commit(generation: g, currentThemeRevision: 2))
        XCTAssertEqual(state.phase, .awaitingUserCommit)
    }
    func testCancelPreservesNoCommit() throws {
        var state = ThemeImageImport(); let g = try state.begin(currentThemeRevision: 1)
        _ = try state.stage(fixture(), generation: g); try state.cancel(generation: g)
        XCTAssertNil(state.candidate); XCTAssertEqual(state.phase, .idle)
        XCTAssertThrowsError(try state.commit(generation: g, currentThemeRevision: 1))
    }
    func testFailureDoesNotAdvance() throws {
        var state = ThemeImageImport(); let g = try state.begin(currentThemeRevision: 1)
        XCTAssertThrowsError(try state.stage(Data([1]), generation: g))
        XCTAssertEqual(state.phase, .selecting); XCTAssertNil(state.candidate)
    }
    func testManifestAllowlist() throws {
        let m = try ThemePNGStructure.inspect(fixture())
        XCTAssertEqual(Set(Mirror(reflecting: m).children.compactMap(\.label)),
                       Set(["width", "height", "byteCount", "sha256", "requiresNativeDecode"]))
    }
    func testNoRestagingAfterPreview() throws {
        var state = ThemeImageImport(); let g = try state.begin(currentThemeRevision: 0)
        let m = try state.stage(fixture(), generation: g)
        try state.nativePreviewRendered(generation: g, sha256: m.sha256)
        XCTAssertThrowsError(try state.stage(fixture(payload: [1,2]), generation: g))
    }
    func testMultipleIDAT() throws {
        XCTAssertEqual(try ThemePNGStructure.inspect(fixture(extra: chunk("IDAT", [97]), payload: [98])).width, 2)
    }
    func testExactDimensionAndPixelLimits() throws {
        let pairs: [(UInt32, UInt32)] = [(4096,1024), (1024,4096), (2048,2048)]
        for (w,h) in pairs { XCTAssertEqual(try ThemePNGStructure.inspect(fixture(w,h)).width, Int(w)) }
    }
    func testExactByteLimit() throws {
        let bytes = fixture(payload: [UInt8](repeating: 120, count: 8*1024*1024-57))
        XCTAssertEqual(bytes.count, ThemePNGStructure.maximumBytes)
        XCTAssertEqual(try ThemePNGStructure.inspect(bytes).byteCount, bytes.count)
        XCTAssertThrowsError(try ThemePNGStructure.inspect(fixture(payload: [UInt8](repeating: 120, count: 8*1024*1024-56))))
    }
    func testExactChunkLimit() throws {
        let accepted = (0..<1021).flatMap { _ in chunk("IDAT", [120]) }
        XCTAssertEqual(try ThemePNGStructure.inspect(fixture(extra: accepted)).width, 2)
        XCTAssertThrowsError(try ThemePNGStructure.inspect(fixture(extra: accepted + chunk("IDAT", [120]))))
    }
    func testShortIHDR() {
        XCTAssertThrowsError(try ThemePNGStructure.inspect(Data(signature+chunk("IHDR")+chunk("IDAT",[120])+chunk("IEND"))))
    }
    func testUnknownChunkRejected() {
        XCTAssertThrowsError(try ThemePNGStructure.inspect(fixture(extra: chunk("vpAg", [1]))))
    }
    func testMissingEnd() { XCTAssertThrowsError(try ThemePNGStructure.inspect(Data(fixture().dropLast(12)))) }
    func testReplacementClearsCandidate() throws {
        var state = ThemeImageImport(); let old = try state.begin(currentThemeRevision: 0)
        let m = try state.stage(fixture(), generation: old)
        try state.nativePreviewRendered(generation: old, sha256: m.sha256)
        let new = try state.begin(currentThemeRevision: 1)
        XCTAssertEqual(state.phase, .selecting); XCTAssertNil(state.candidate)
        XCTAssertThrowsError(try state.commit(generation: old, currentThemeRevision: 0))
        XCTAssertThrowsError(try state.commit(generation: new, currentThemeRevision: 1))
    }
    func testCancelAfterPreview() throws {
        var state = ThemeImageImport(); let g = try state.begin(currentThemeRevision: 0)
        let m = try state.stage(fixture(), generation: g)
        try state.nativePreviewRendered(generation: g, sha256: m.sha256); try state.cancel(generation: g)
        XCTAssertEqual(state.phase, .idle); XCTAssertNil(state.candidate)
        XCTAssertThrowsError(try state.commit(generation: g, currentThemeRevision: 0))
    }
    func testCallbackIsTrustedNotDecodeProof() throws {
        var state = ThemeImageImport(); let g = try state.begin(currentThemeRevision: 0)
        let m = try state.stage(fixture(payload: Array("private non-zlib bytes".utf8)), generation: g)
        try state.nativePreviewRendered(generation: g, sha256: m.sha256)
        XCTAssertTrue(try state.commit(generation: g, currentThemeRevision: 0).requiresNativeDecode)
    }
}
