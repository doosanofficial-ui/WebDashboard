import Foundation
import CryptoKit

public enum ThemeImageImportError: Error, Equatable, Sendable {
    case invalidFormat, exceededLimit, invalidChunk, invalidCRC, invalidDimensions
    case unsupportedEncoding, unapprovedChunk, staleState, digestMismatch, revisionConflict
}

/// Local-only structural evidence. Not a pixel decoder, anonymization claim or persistence format.
public struct ThemeImageManifest: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let byteCount: Int
    public let sha256: String
    public let requiresNativeDecode = true
    fileprivate init(width: Int, height: Int, byteCount: Int, sha256: String) {
        self.width = width; self.height = height; self.byteCount = byteCount; self.sha256 = sha256
    }
}

/// Checks a deliberately narrow PNG chunk allowlist, not arbitrary PNG compatibility.
/// IDAT and visible pixels may contain private data; this is not a sanitization boundary.
/// Native ImageIO must still decode, convert to sRGB, and render these exact bytes before commit.
public enum ThemePNGStructure {
    public static let maximumBytes = 8 * 1024 * 1024
    public static let maximumPixels = 4_194_304
    public static let maximumDimension = 4096
    public static let maximumChunks = 1024

    public static func inspect(_ data: Data) throws -> ThemeImageManifest {
        guard data.count <= maximumBytes else { throw ThemeImageImportError.exceededLimit }
        let bytes = Array(data)
        guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw ThemeImageImportError.invalidFormat
        }
        var offset = 8, chunks = 0, width = 0, height = 0, imageBytes = 0
        var headerSeen = false, ended = false
        while offset < bytes.count {
            chunks += 1
            guard chunks <= maximumChunks, bytes.count - offset >= 12 else {
                throw ThemeImageImportError.exceededLimit
            }
            let length = Int(uint32(bytes, offset))
            guard length <= bytes.count - offset - 12 else { throw ThemeImageImportError.invalidChunk }
            let kind = Array(bytes[(offset + 4)..<(offset + 8)])
            let bodyStart = offset + 8, bodyEnd = bodyStart + length
            guard crc32(bytes[(offset + 4)..<bodyEnd]) == uint32(bytes, bodyEnd) else {
                throw ThemeImageImportError.invalidCRC
            }
            switch kind {
            case [73, 72, 68, 82]: // IHDR
                guard !headerSeen, chunks == 1, length == 13 else { throw ThemeImageImportError.invalidChunk }
                width = Int(uint32(bytes, bodyStart)); height = Int(uint32(bytes, bodyStart + 4))
                guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
                      width <= maximumPixels / height else { throw ThemeImageImportError.invalidDimensions }
                guard bytes[bodyStart + 8] == 8, [2, 6].contains(bytes[bodyStart + 9]),
                      bytes[bodyStart + 10] == 0, bytes[bodyStart + 11] == 0,
                      bytes[bodyStart + 12] == 0 else { throw ThemeImageImportError.unsupportedEncoding }
                headerSeen = true
            case [73, 68, 65, 84]: // IDAT
                guard headerSeen else { throw ThemeImageImportError.invalidChunk }
                imageBytes += length
            case [73, 69, 78, 68]: // IEND
                guard headerSeen, imageBytes > 0, length == 0, offset + 12 == bytes.count else {
                    throw ThemeImageImportError.invalidChunk
                }
                ended = true
            default:
                // Reject EXIF/text/ICC/APNG/private chunks rather than silently retaining them.
                throw ThemeImageImportError.unapprovedChunk
            }
            offset = bodyEnd + 4
        }
        guard ended else { throw ThemeImageImportError.invalidChunk }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(width: width, height: height, byteCount: data.count, sha256: digest)
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
    private static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
        }
        return crc ^ UInt32.max
    }
}

/// Value-state coordinator only. Does not load images, persist files, change themes or delete anything.
public struct ThemeImageImport: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, selecting, awaitingNativePreview, awaitingUserCommit }
    public private(set) var phase: Phase = .idle
    public private(set) var generation: UInt64 = 0
    public private(set) var candidate: ThemeImageManifest?
    private var expectedThemeRevision: UInt64?
    public init() {}

    public mutating func begin(currentThemeRevision: UInt64) throws -> UInt64 {
        guard generation < UInt64.max else { throw ThemeImageImportError.exceededLimit }
        generation += 1; expectedThemeRevision = currentThemeRevision
        candidate = nil; phase = .selecting
        return generation
    }
    public mutating func stage(_ bytes: Data, generation token: UInt64) throws -> ThemeImageManifest {
        try require(token, .selecting)
        let inspected = try ThemePNGStructure.inspect(bytes)
        candidate = inspected; phase = .awaitingNativePreview
        return inspected
    }
    /// Trust boundary: only the verified native decoder/preview adapter may report this event.
    /// This callback cannot itself prove decoding occurred. It binds an actual preview to exact bytes.
    public mutating func nativePreviewRendered(generation token: UInt64, sha256: String) throws {
        try require(token, .awaitingNativePreview)
        guard candidate?.sha256 == sha256 else { throw ThemeImageImportError.digestMismatch }
        phase = .awaitingUserCommit
    }
    /// Call only after explicit user acceptance. Returns a plan, not a storage or theme write.
    public mutating func commit(generation token: UInt64, currentThemeRevision: UInt64) throws -> ThemeImageManifest {
        try require(token, .awaitingUserCommit)
        guard expectedThemeRevision == currentThemeRevision else { throw ThemeImageImportError.revisionConflict }
        guard let result = candidate else { throw ThemeImageImportError.staleState }
        candidate = nil; phase = .idle
        return result
    }
    public mutating func cancel(generation token: UInt64) throws {
        guard token == generation else { throw ThemeImageImportError.staleState }
        candidate = nil; phase = .idle
    }
    private func require(_ token: UInt64, _ expected: Phase) throws {
        guard token == generation, phase == expected else { throw ThemeImageImportError.staleState }
    }
}
