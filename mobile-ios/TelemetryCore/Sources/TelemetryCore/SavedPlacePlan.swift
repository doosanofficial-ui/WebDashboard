import Foundation

public enum SavedPlaceError: Error { case invalidSchema, invalidRecord, conflict }
private struct PlaceKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func exactKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let keys = try decoder.container(keyedBy: PlaceKey.self).allKeys.map(\.stringValue)
    guard Set(keys) == expected else { throw SavedPlaceError.invalidSchema }
}

/// Local data only. Constructing or planning does not save, share or grant permission.
public struct SavedPlace: Codable, Equatable {
    public enum Kind: String, Codable { case home, work, other }
    public let id: String
    public let kind: Kind
    public let label: String
    public let latitude: Double
    public let longitude: Double
    enum CodingKeys: String, CodingKey { case id, kind, label, latitude, longitude }
    public init(id: String, kind: Kind, label: String, latitude: Double, longitude: Double) throws {
        let idSet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-".utf8)
        let scalars = label.unicodeScalars
        let punctuation = Set(" _'().,-".unicodeScalars)
        let validLabelScalars = scalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark,
                 .decimalNumber, .letterNumber, .otherNumber:
                return true
            default: return punctuation.contains(scalar)
            }
        }
        guard (1...64).contains(id.utf8.count), id.utf8.allSatisfy({ idSet.contains($0) }),
              (1...80).contains(scalars.count), label.utf8.count <= 320, validLabelScalars,
              !label.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty,
              latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else {
            throw SavedPlaceError.invalidRecord
        }
        self.id = id; self.kind = kind; self.label = label
        self.latitude = latitude; self.longitude = longitude
    }
    public init(from decoder: Decoder) throws {
        try exactKeys(decoder, ["id", "kind", "label", "latitude", "longitude"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), kind: c.decode(Kind.self, forKey: .kind),
                      label: c.decode(String.self, forKey: .label), latitude: c.decode(Double.self, forKey: .latitude),
                      longitude: c.decode(Double.self, forKey: .longitude))
    }
}

public struct SavedPlaceSnapshot: Codable, Equatable {
    public static let maximumRevision: UInt64 = 9_007_199_254_740_991
    public let version: Int
    public let revision: UInt64
    public let places: [SavedPlace]
    /// Exact imported bytes, local provenance only. Never encoded into the schema.
    public let source: Data?
    enum CodingKeys: String, CodingKey { case version, revision, places }
    public init(revision: UInt64, places: [SavedPlace]) throws {
        try self.init(revision: revision, places: places, source: nil)
    }
    private init(revision: UInt64, places: [SavedPlace], source: Data?) throws {
        guard revision <= Self.maximumRevision, places.count <= 128,
              Set(places.map(\.id)).count == places.count,
              places.filter({ $0.kind == .home }).count <= 1,
              places.filter({ $0.kind == .work }).count <= 1 else { throw SavedPlaceError.invalidSchema }
        self.version = 1; self.revision = revision; self.places = places; self.source = source
    }
    public init(from decoder: Decoder) throws {
        try exactKeys(decoder, ["version", "revision", "places"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw SavedPlaceError.invalidSchema }
        try self.init(revision: c.decode(UInt64.self, forKey: .revision), places: c.decode([SavedPlace].self, forKey: .places))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(revision, forKey: .revision); try c.encode(places, forKey: .places)
    }
    /// Bounded duplicate-key preflight followed by Foundation JSON validation.
    private static func rejectDuplicateKeys(_ data: Data) throws {
        let bytes = Array(data)
        var stack: [Set<String>?] = []
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case 123: stack.append(Set<String>()); i += 1
            case 91: stack.append(nil); i += 1
            case 125, 93:
                guard !stack.isEmpty else { throw SavedPlaceError.invalidSchema }
                stack.removeLast(); i += 1
            case 34:
                let start = i; i += 1
                while i < bytes.count && bytes[i] != 34 {
                    if bytes[i] == 92 { i += 1 }
                    i += 1
                }
                guard i < bytes.count else { throw SavedPlaceError.invalidSchema }
                i += 1
                var next = i
                while next < bytes.count && [UInt8(32), 9, 10, 13].contains(bytes[next]) { next += 1 }
                if next < bytes.count && bytes[next] == 58 {
                    guard let last = stack.indices.last, var keys = stack[last] else { throw SavedPlaceError.invalidSchema }
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<i]))
                    guard keys.insert(key).inserted else { throw SavedPlaceError.invalidSchema }
                    stack[last] = keys
                }
            default: i += 1
            }
        }
    }
    public static func decodeLocal(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw SavedPlaceError.invalidSchema }
        try rejectDuplicateKeys(data)
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        return try Self(revision: decoded.revision, places: decoded.places, source: data)
    }
    public enum Operation { case add(SavedPlace), edit(SavedPlace), remove(id: String) }
    /// Returns a proposed value. Caller must recheck expected revision at any future
    /// authorized atomic commit. This method never persists or deletes anything.
    public func plan(expectedRevision: UInt64, operation: Operation) throws -> Self {
        guard expectedRevision == revision, revision < Self.maximumRevision else { throw SavedPlaceError.conflict }
        var next = places
        switch operation {
        case .add(let place): next.append(place)
        case .edit(let place):
            guard let i = next.firstIndex(where: { $0.id == place.id }) else { throw SavedPlaceError.conflict }
            next[i] = place
        case .remove(let id):
            guard let i = next.firstIndex(where: { $0.id == id }) else { throw SavedPlaceError.conflict }
            next.remove(at: i)
        }
        return try Self(revision: revision + 1, places: next)
    }
}
