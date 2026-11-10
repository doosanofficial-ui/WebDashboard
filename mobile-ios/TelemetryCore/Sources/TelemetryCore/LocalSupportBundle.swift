import Foundation
import CryptoKit

public enum LocalSupportBundleError: Error { case entryLimit, archiveLimit, invalidLayout }

/// These are the exact bytes stored in the archive, not a separately regenerated summary.
public struct LocalSupportBundleEntry: Equatable, Sendable {
    public let name: String
    public let content: Data
    public let sha256: String
    public var byteCount: Int { content.count }
    fileprivate init(name: String, content: Data) {
        self.name = name; self.content = content; self.sha256 = supportBundleHash(content)
    }
}

public struct LocalSupportBundle: Equatable, Sendable {
    public let archive: Data
    public let entries: [LocalSupportBundleEntry]
    public let sha256: String
    public var authorizesSharing: Bool { false }
    fileprivate init(archive: Data, entries: [LocalSupportBundleEntry]) {
        self.archive = archive; self.entries = entries; self.sha256 = supportBundleHash(archive)
    }
}

private func supportBundleHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Pure in-memory packaging. Accepts only the immutable allowlisted report type.
/// No arbitrary file names, text, raw archives, disk, network or share-sheet API.
public enum LocalSupportBundleBuilder {
    public static let maximumEntryBytes = 16_384
    public static let maximumArchiveBytes = 40_960
    public static let notice = "Local support snapshot. Contains only typed versions, connection state and optional aggregate counters/latency. No raw logs, VIN, location or device identifiers are included. Numeric aggregates can reveal activity; this is not anonymization. ZIP is not encrypted. Review every entry before any explicit share action. Packaging is not consent to save, send or upload. Remote delivery remains disabled.\n"

    public static func build(report: LocalSupportReport) throws -> LocalSupportBundle {
        let entries = [
            LocalSupportBundleEntry(name: "report.json", content: try report.jsonData()),
            LocalSupportBundleEntry(name: "README.txt", content: Data(notice.utf8))
        ]
        // Count and names are fixed internally. Bounds precede all narrowing conversions.
        guard entries.allSatisfy({ $0.byteCount <= maximumEntryBytes }) else {
            throw LocalSupportBundleError.entryLimit
        }
        let total = 22 + entries.reduce(0) { $0 + 76 + 2 * $1.name.utf8.count + $1.byteCount }
        guard total <= maximumArchiveBytes else { throw LocalSupportBundleError.archiveLimit }
        var local = Data(); var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let size = UInt32(entry.byteCount); let checksum = crc32(entry.content)
            let offset = UInt32(local.count)
            // STORE, UTF-8, fixed DOS timestamp 1980-01-01 00:00:00.
            append32(0x04034b50, to: &local)
            for value in [UInt16(20), 0x0800, 0, 0, 33] { append16(value, to: &local) }
            for value in [checksum, size, size] { append32(value, to: &local) }
            append16(UInt16(name.count), to: &local); append16(0, to: &local)
            local.append(name); local.append(entry.content)

            append32(0x02014b50, to: &central)
            for value in [UInt16(20), 20, 0x0800, 0, 0, 33] { append16(value, to: &central) }
            for value in [checksum, size, size] { append32(value, to: &central) }
            for value in [UInt16(name.count), 0, 0, 0, 0] { append16(value, to: &central) }
            append32(0, to: &central); append32(offset, to: &central); central.append(name)
        }
        let centralOffset = UInt32(local.count); let centralSize = UInt32(central.count)
        local.append(central)
        append32(0x06054b50, to: &local)
        for value in [UInt16(0), 0, 2, 2] { append16(value, to: &local) }
        append32(centralSize, to: &local); append32(centralOffset, to: &local)
        append16(0, to: &local)
        guard local.count == total else { throw LocalSupportBundleError.invalidLayout }
        return LocalSupportBundle(archive: local, entries: entries)
    }

    // Internal for known-vector tests, not an arbitrary archive-building API.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ 0xffffffff
    }
    private static func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    private static func append32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}
