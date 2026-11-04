import Foundation

public enum AppearanceThemeError: Error, Equatable {
    case invalidComponent, invalidSchema, unsupportedVersion, invalidToken, invalidTheme
    case requiresOpaqueColors, insufficientContrast, oversizedData
}

// Deliberately closed schema. No URLs, assets, user labels, telemetry or identifiers.
private struct ThemeJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func requireThemeKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let container = try decoder.container(keyedBy: ThemeJSONKey.self)
    guard Set(container.allKeys.map(\.stringValue)) == expected else {
        throw AppearanceThemeError.invalidSchema
    }
}

/// Normalized sRGB components. Alpha is typed and bounded, but theme tokens must be opaque.
public struct AppearanceColor: Codable, Equatable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) throws {
        guard [r, g, b, a].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw AppearanceThemeError.invalidComponent
        }
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    private enum CodingKeys: String, CodingKey { case r, g, b, a }
    public init(from decoder: Decoder) throws {
        try requireThemeKeys(decoder, ["r", "g", "b", "a"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(r: c.decode(Double.self, forKey: .r),
                      g: c.decode(Double.self, forKey: .g),
                      b: c.decode(Double.self, forKey: .b),
                      a: c.decode(Double.self, forKey: .a))
    }
    public var relativeLuminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
    /// Only opaque pairs are supported. No unknown backdrop compositing assumptions.
    public func contrast(with other: AppearanceColor) throws -> Double {
        guard a == 1, other.a == 1 else { throw AppearanceThemeError.requiresOpaqueColors }
        return (max(relativeLuminance, other.relativeLuminance) + 0.05)
            / (min(relativeLuminance, other.relativeLuminance) + 0.05)
    }
}

public enum AppearanceThemeID: String, Codable, CaseIterable, Sendable {
    case slateDark, amberDark, paperLight, blueLight
    public var isDark: Bool { self == .slateDark || self == .amberDark }
}
public enum AppearanceToken: String, Codable, CaseIterable, Sendable {
    case background, surface, text, secondary, accent, warning, critical
    public static let backgrounds: [Self] = [.background, .surface]
    public static let foregrounds: [Self] = [.text, .secondary, .accent, .warning, .critical]
}

/// Every foreground is qualified for normal text on either opaque background at >= 4.5:1.
/// Does not validate foreground-on-foreground, controls, graphs, font sizes, or driving safety.
public struct AppearancePalette: Equatable, Sendable {
    public let tokens: [AppearanceToken: AppearanceColor]
    public init(tokens: [AppearanceToken: AppearanceColor]) throws {
        guard Set(tokens.keys) == Set(AppearanceToken.allCases) else {
            throw AppearanceThemeError.invalidToken
        }
        guard tokens.values.allSatisfy({ $0.a == 1 }) else {
            throw AppearanceThemeError.requiresOpaqueColors
        }
        for foreground in AppearanceToken.foregrounds {
            for background in AppearanceToken.backgrounds {
                guard let f = tokens[foreground], let b = tokens[background],
                      try f.contrast(with: b) >= 4.5 else {
                    throw AppearanceThemeError.insufficientContrast
                }
            }
        }
        self.tokens = tokens
    }
    public func overriding(_ changes: [String: AppearanceColor]) throws -> Self {
        var merged = tokens
        for (key, value) in changes {
            guard let token = AppearanceToken(rawValue: key) else {
                throw AppearanceThemeError.invalidToken
            }
            merged[token] = value
        }
        return try Self(tokens: merged)
    }
    public static func builtin(_ id: AppearanceThemeID) -> Self {
        // All numeric constants are original; force-try is confined to tested closed fixtures.
        let hex: [UInt32]
        switch id {
        case .slateDark: hex = [0x101820, 0x1C2630, 0xFFFFFF, 0xC1CBD5, 0x85D3FF, 0xFFD17A, 0xFFB6B6]
        case .amberDark: hex = [0x19150F, 0x292116, 0xFFF6E5, 0xDED0B6, 0xFFCC70, 0xFFE3A1, 0xFFC2B6]
        case .paperLight: hex = [0xFFFFFF, 0xF1F3F5, 0x15202B, 0x45515E, 0x075596, 0x754400, 0x9F1635]
        case .blueLight: hex = [0xF7FBFF, 0xE8F1FA, 0x10263D, 0x344E68, 0x004F87, 0x704100, 0x97142B]
        }
        let ordered = AppearanceToken.backgrounds + AppearanceToken.foregrounds
        let pairs = zip(ordered, hex).map { token, value in
            (token, try! AppearanceColor(r: Double((value >> 16) & 255) / 255,
                                        g: Double((value >> 8) & 255) / 255,
                                        b: Double(value & 255) / 255))
        }
        return try! Self(tokens: Dictionary(uniqueKeysWithValues: pairs))
    }
}

/// Pure value model. Does not write UserDefaults, disk, network or remote delivery settings.
public struct AppearanceSettings: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let selected: AppearanceThemeID
    public let overrides: [String: [String: AppearanceColor]]
    public static let maximumEncodedBytes = 16_384
    public init(selected: AppearanceThemeID = .slateDark,
                overrides: [String: [String: AppearanceColor]] = [:]) throws {
        for (key, changes) in overrides {
            guard let id = AppearanceThemeID(rawValue: key) else { throw AppearanceThemeError.invalidTheme }
            _ = try AppearancePalette.builtin(id).overriding(changes)
        }
        self.schemaVersion = 1; self.selected = selected; self.overrides = overrides
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, selected, overrides }
    public init(from decoder: Decoder) throws {
        try requireThemeKeys(decoder, ["schemaVersion", "selected", "overrides"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw AppearanceThemeError.unsupportedVersion
        }
        try self.init(selected: c.decode(AppearanceThemeID.self, forKey: .selected),
                      overrides: c.decode([String: [String: AppearanceColor]].self, forKey: .overrides))
    }
    public func palette(for id: AppearanceThemeID? = nil) throws -> AppearancePalette {
        let key = id ?? selected
        return try AppearancePalette.builtin(key).overriding(overrides[key.rawValue] ?? [:])
    }
    /// Replaces this theme's override set atomically, preserving other themes.
    public func settingOverrides(_ changes: [String: AppearanceColor], for id: AppearanceThemeID) throws -> Self {
        var updated = overrides; updated[id.rawValue] = changes
        return try Self(selected: selected, overrides: updated)
    }
    public func selecting(_ id: AppearanceThemeID) throws -> Self {
        try Self(selected: id, overrides: overrides)
    }
    public func resetting(_ id: AppearanceThemeID) throws -> Self {
        var updated = overrides; updated.removeValue(forKey: id.rawValue)
        return try Self(selected: selected, overrides: updated)
    }
    public static var defaults: Self { try! Self() }
    public func resettingAll() -> Self { Self.defaults }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw AppearanceThemeError.oversizedData }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw AppearanceThemeError.oversizedData }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public enum RestoreStatus: String, Sendable { case loaded, missingData, invalidData }
    /// Invalid/future schemas fall back in memory only; caller must not overwrite original bytes silently.
    public static func restore(_ data: Data?) -> (settings: Self, status: RestoreStatus) {
        guard let data else { return (defaults, .missingData) }
        do { return (try decode(data), .loaded) }
        catch { return (defaults, .invalidData) }
    }
}
