import Foundation
import CryptoKit

public enum SelectedRawExportError: Error { case invalid, stale, limit }
public enum SelectedRawFormat: String, Sendable { case nativeJSON, nativeCSV }
/// Only a trusted native archive adapter may supply these already-authorized snapshot bytes.
/// This value type cannot authenticate origin. It is NOT a file reader or sanitizer.
public struct SelectedRawRecord: Equatable, Sendable {
    public let id: String
    public let revision: String
    public let nativeMode: String
    public let format: SelectedRawFormat
    public let content: Data
    public init(id: String, revision: String, nativeMode: String, format: SelectedRawFormat, content: Data) {
        self.id = id; self.revision = revision; self.nativeMode = nativeMode
        self.format = format; self.content = content
    }
    public static func == (a: Self, b: Self) -> Bool {
        rawIdentity(a.id, b.id) && rawIdentity(a.revision, b.revision) && rawIdentity(a.nativeMode, b.nativeMode) && a.format == b.format && a.content == b.content
    }
}
public struct SelectedRawSnapshot: Sendable {
    public let scope: String
    public let revision: String
    public let records: [SelectedRawRecord]
    public init(scope: String, revision: String, records: [SelectedRawRecord]) {
        self.scope = scope; self.revision = revision; self.records = records
    }
}
public struct SelectedRawSelection: Sendable {
    public let scope: String
    public let revision: String
    public let records: [SelectedRawRecord]
    fileprivate init(_ snapshot: SelectedRawSnapshot, records: [SelectedRawRecord]) {
        scope = snapshot.scope; revision = snapshot.revision; self.records = records
    }
}
public struct SelectedRawPreview: Equatable, Sendable {
    public let name: String
    public let record: SelectedRawRecord
    public var byteCount: Int { record.content.count }
    public var sha256: String { rawHash(record.content) }
}
public struct SelectedRawBundle: Sendable {
    public let scope: String
    public let revision: String
    public let entries: [SelectedRawPreview]
    public let archive: Data
    public var sha256: String { rawHash(archive) }
    public var authorizesSharing: Bool { false }
    public var warning: String { SelectedRawExport.warning }
}
private func rawIdentity(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
private func rawHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public enum SelectedRawExport {
    public static let maximumEntryBytes = 1_048_576
    public static let maximumArchiveBytes = 8_388_608
    public static let maximumCount = 32
    public static let warning = "RAW logs may contain GPS, VIN and other private content. ZIP is not encrypted and not anonymized. Review exact bytes and obtain separate approval for any sharing destination. Packaging grants no save, upload or sharing permission."
    private static func validate(_ snapshot: SelectedRawSnapshot) throws {
        guard snapshot.records.count <= maximumCount else { throw SelectedRawExportError.limit }
        var identities = Set<Data>()
        func valid(_ value: String) -> Bool { !value.isEmpty && value.unicodeScalars.count <= 256 && !value.contains("\0") }
        guard valid(snapshot.scope), valid(snapshot.revision) else { throw SelectedRawExportError.invalid }
        for record in snapshot.records {
            guard valid(record.id), valid(record.revision), valid(record.nativeMode), identities.insert(Data(record.id.utf8)).inserted else { throw SelectedRawExportError.invalid }
            guard record.content.count <= maximumEntryBytes else { throw SelectedRawExportError.limit }
        }
    }
    public static func select(_ snapshot: SelectedRawSnapshot, ids: [String] = []) throws -> SelectedRawSelection {
        try validate(snapshot)
        let keys = ids.map { Data($0.utf8) }
        guard keys.count <= maximumCount, Set(keys).count == keys.count else { throw SelectedRawExportError.invalid }
        let records = snapshot.records.filter { keys.contains(Data($0.id.utf8)) }.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
        guard records.count == ids.count else { throw SelectedRawExportError.invalid }
        return SelectedRawSelection(snapshot, records: records)
    }
    public static func build(_ selection: SelectedRawSelection, current: SelectedRawSnapshot) throws -> SelectedRawBundle? {
        let expected = try select(current, ids: selection.records.map(\.id))
        guard rawIdentity(selection.scope, expected.scope), rawIdentity(selection.revision, expected.revision), selection.records == expected.records else { throw SelectedRawExportError.stale }
        guard !selection.records.isEmpty else { return nil }
        let entries = selection.records.enumerated().map { index, record in
            SelectedRawPreview(name: String(format: "raw-%04d", index + 1) + (record.format == .nativeJSON ? ".json" : ".csv"), record: record)
        }
        let total = 22 + entries.reduce(0) { $0 + 76 + 2 * $1.name.utf8.count + $1.byteCount }
        guard total <= maximumArchiveBytes else { throw SelectedRawExportError.limit }
        var local = Data(); var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8); let size = UInt32(entry.byteCount)
            let crc = crc32(entry.record.content); let offset = UInt32(local.count)
            u32(0x04034b50, &local)
            for v in [UInt16(20), 0x800, 0, 0, 33] { u16(v, &local) }
            for v in [crc, size, size] { u32(v, &local) }
            u16(UInt16(name.count), &local); u16(0, &local); local.append(name); local.append(entry.record.content)
            u32(0x02014b50, &central)
            for v in [UInt16(20), 20, 0x800, 0, 0, 33] { u16(v, &central) }
            for v in [crc, size, size] { u32(v, &central) }
            for v in [UInt16(name.count), 0, 0, 0, 0] { u16(v, &central) }
            u32(0, &central); u32(offset, &central); central.append(name)
        }
        let offset = UInt32(local.count); let size = UInt32(central.count)
        local.append(central); u32(0x06054b50, &local)
        for v in [UInt16(0), 0, UInt16(entries.count), UInt16(entries.count)] { u16(v, &local) }
        u32(size, &local); u32(offset, &local); u16(0, &local)
        guard local.count == total else { throw SelectedRawExportError.invalid }
        return SelectedRawBundle(scope: selection.scope, revision: selection.revision, entries: entries, archive: local)
    }
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ 0xffffffff
    }
    private static func u16(_ n: UInt16, _ data: inout Data) { for s in [0,8] { data.append(UInt8(truncatingIfNeeded: n >> s)) } }
    private static func u32(_ n: UInt32, _ data: inout Data) { for s in [0,8,16,24] { data.append(UInt8(truncatingIfNeeded: n >> s)) } }
}
