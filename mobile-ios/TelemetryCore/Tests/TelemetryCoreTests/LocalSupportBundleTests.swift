import Foundation
import CryptoKit
import XCTest
@testable import TelemetryCore

final class LocalSupportBundleTests: XCTestCase {
    private func report() throws -> LocalSupportReport {
        try LocalSupportReport(appVersion: [1,2,3], osVersion: [18,0], platform: .iOS,
                               transport: .ble, state: .connected, counters: nil, latency: nil)
    }
    private func u16(_ data: Data, _ i: Int) -> Int { Int(data[i]) | (Int(data[i+1]) << 8) }
    private func u32(_ data: Data, _ i: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[i+$1]) << ($1*8)) }
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func testExactPreviewAndDeterminism() throws {
        let r = try report(); let b = try LocalSupportBundleBuilder.build(report: r)
        XCTAssertEqual(b, try LocalSupportBundleBuilder.build(report: r))
        XCTAssertEqual(b.entries.map(\.name), ["report.json", "README.txt"])
        XCTAssertEqual(b.entries[0].content, try r.jsonData())
        XCTAssertEqual(b.entries[1].content, Data(LocalSupportBundleBuilder.notice.utf8))
        XCTAssertEqual(b.sha256, hash(b.archive)); XCTAssertFalse(b.authorizesSharing)
        XCTAssertLessThanOrEqual(b.archive.count, LocalSupportBundleBuilder.maximumArchiveBytes)
        for e in b.entries { XCTAssertEqual(e.sha256, hash(e.content)) }
    }
    func testLocalAndCentralLayout() throws {
        let b = try LocalSupportBundleBuilder.build(report: report()); let d = b.archive
        var offset = 0; var offsets: [Int] = []
        for e in b.entries {
            offsets.append(offset)
            XCTAssertEqual(u32(d,offset), 0x04034b50)
            XCTAssertEqual(u16(d,offset+4),20); XCTAssertEqual(u16(d,offset+6),0x800)
            XCTAssertEqual(u16(d,offset+8),0); XCTAssertEqual(u16(d,offset+10),0)
            XCTAssertEqual(u16(d,offset+12),33)
            XCTAssertEqual(u32(d,offset+14),LocalSupportBundleBuilder.crc32(e.content))
            XCTAssertEqual(u32(d,offset+18),UInt32(e.byteCount))
            XCTAssertEqual(u32(d,offset+22),UInt32(e.byteCount))
            XCTAssertEqual(u16(d,offset+26),e.name.utf8.count); XCTAssertEqual(u16(d,offset+28),0)
            let start = offset+30+e.name.utf8.count
            XCTAssertEqual(d.subdata(in: (offset+30)..<start),Data(e.name.utf8))
            XCTAssertEqual(d.subdata(in: start..<(start+e.byteCount)),e.content)
            offset = start+e.byteCount
        }
        let centralStart = offset
        for (index,e) in b.entries.enumerated() {
            XCTAssertEqual(u32(d,offset),0x02014b50)
            XCTAssertEqual(u16(d,offset+8),0x800)
            XCTAssertEqual(u32(d,offset+16),LocalSupportBundleBuilder.crc32(e.content))
            XCTAssertEqual(u32(d,offset+42),UInt32(offsets[index]))
            offset += 46+e.name.utf8.count
        }
        XCTAssertEqual(u32(d,offset),0x06054b50)
        XCTAssertEqual(u16(d,offset+8),2); XCTAssertEqual(u16(d,offset+10),2)
        XCTAssertEqual(u32(d,offset+12),UInt32(offset-centralStart))
        XCTAssertEqual(u32(d,offset+16),UInt32(centralStart))
        XCTAssertEqual(u16(d,offset+20),0); XCTAssertEqual(offset+22,d.count)
    }
    func testCRC32KnownVectors() {
        XCTAssertEqual(LocalSupportBundleBuilder.crc32(Data("123456789".utf8)),0xcbf43926)
        XCTAssertEqual(LocalSupportBundleBuilder.crc32(Data()),0)
    }
}
