// Original additive preparation. Swift compilation and XCTest execution deliberately UNRUN.
import Foundation
import CoreFoundation

public enum VehicleDisplayMetadataError: Error, Equatable {
    case invalidChoice, invalidLabel, invalidSchema, invalidRevision, invalidShape, tooLarge, invalidScope, stalePlan
}

/// User descriptions only. No relationship between these fields is inferred.
/// This is NOT VehicleContext, an ECU profile, VIN, support evidence, or query policy.
public struct VehicleDisplayMetadata: Equatable, Sendable {
    public let fuel: String
    public let powertrain: String
    public let gearbox: String
    public let turbo: String
    /// A user-entered display label, never a measured RPM or a safety/control limit.
    /// 1...100000 is a serialization bound, not a validated engine operating range.
    public let redlineLabelRPM: Int?

    public init(fuel: String = "unknown", powertrain: String = "unknown",
                gearbox: String = "unknown", turbo: String = "unknown", redlineLabelRPM: Int? = nil) throws {
        guard ["unknown", "mixed", "gasoline", "diesel", "electric", "hydrogen", "other"].contains(fuel),
              ["unknown", "mixed", "ice", "hev", "phev", "bev", "fuelCell", "other"].contains(powertrain),
              ["unknown", "mixed", "manual", "automatic", "cvt", "ecvt", "dualClutch", "singleSpeed", "other"].contains(gearbox),
              ["unknown", "mixed", "present", "absent", "notApplicable"].contains(turbo) else {
            throw VehicleDisplayMetadataError.invalidChoice
        }
        if let label = redlineLabelRPM, !(1...100000).contains(label) {
            throw VehicleDisplayMetadataError.invalidLabel
        }
        self.fuel = fuel; self.powertrain = powertrain; self.gearbox = gearbox
        self.turbo = turbo; self.redlineLabelRPM = redlineLabelRPM
    }

    fileprivate var object: [String: Any] {
        ["fuel": fuel, "powertrain": powertrain, "gearbox": gearbox, "turbo": turbo,
         "redlineLabelRPM": redlineLabelRPM.map { $0 as Any } ?? NSNull()]
    }
    fileprivate static func decodeObject(_ raw: Any) throws -> Self {
        guard let o = raw as? [String: Any], Set(o.keys) == Set(["fuel", "powertrain", "gearbox", "turbo", "redlineLabelRPM"]),
              let fuel = o["fuel"] as? String, let powertrain = o["powertrain"] as? String,
              let gearbox = o["gearbox"] as? String, let turbo = o["turbo"] as? String else {
            throw VehicleDisplayMetadataError.invalidShape
        }
        let label: Int?
        if o["redlineLabelRPM"] is NSNull { label = nil }
        else { label = try VehicleDisplayMetadataDocument.integer(o["redlineLabelRPM"], range: 1...100000) }
        return try Self(fuel: fuel, powertrain: powertrain, gearbox: gearbox, turbo: turbo, redlineLabelRPM: label)
    }
}

/// A single local display sidecar. Contains no identity, URL, free text, credentials,
/// acquisition settings, diagnostic state, archive data or persistence implementation.
public struct VehicleDisplayMetadataDocument: Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: Int
    public let metadata: VehicleDisplayMetadata
    public static let maximumEncodedBytes = 4096
    public static let maximumRevision = 1000000000

    public init(metadata: VehicleDisplayMetadata, revision: Int = 0, schemaVersion: Int = 1) throws {
        guard schemaVersion == 1 else { throw VehicleDisplayMetadataError.invalidSchema }
        guard (0...Self.maximumRevision).contains(revision) else { throw VehicleDisplayMetadataError.invalidRevision }
        self.metadata = metadata; self.revision = revision; self.schemaVersion = schemaVersion
    }
    public static func empty() throws -> Self { try Self(metadata: VehicleDisplayMetadata()) }
    public func encoded() throws -> Data {
        let data = try JSONSerialization.data(withJSONObject:
            ["schemaVersion": schemaVersion, "revision": revision, "metadata": metadata.object], options: [.sortedKeys])
        guard data.count <= Self.maximumEncodedBytes else { throw VehicleDisplayMetadataError.tooLarge }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw VehicleDisplayMetadataError.tooLarge }
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(o.keys) == Set(["schemaVersion", "revision", "metadata"]), let raw = o["metadata"] else {
            throw VehicleDisplayMetadataError.invalidShape
        }
        return try Self(metadata: VehicleDisplayMetadata.decodeObject(raw),
            revision: integer(o["revision"], range: 0...maximumRevision),
            schemaVersion: integer(o["schemaVersion"], range: 1...1))
    }
    /// JSON whole-valued numbers are accepted; Booleans and fractions are not.
    fileprivate static func integer(_ raw: Any?, range: ClosedRange<Int>) throws -> Int {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            throw VehicleDisplayMetadataError.invalidShape
        }
        let d = n.doubleValue
        guard d.isFinite, d.rounded(.towardZero) == d,
              d >= Double(range.lowerBound), d <= Double(range.upperBound) else {
            throw VehicleDisplayMetadataError.invalidShape
        }
        return Int(d)
    }

    /// scope is the caller's EXISTING local context key, never a new identity.
    /// Caller must check current workspace membership and keep the plan in that owner.
    public func editPlan(scope: String, metadata: VehicleDisplayMetadata) throws -> VehicleDisplayMetadataPlan {
        try Self.validateScope(scope)
        guard revision < Self.maximumRevision else { throw VehicleDisplayMetadataError.invalidRevision }
        return VehicleDisplayMetadataPlan(base: self, scope: scope,
            replacement: try Self(metadata: metadata, revision: revision + 1))
    }
    public func resetPlan(scope: String) throws -> VehicleDisplayMetadataPlan {
        try editPlan(scope: scope, metadata: VehicleDisplayMetadata())
    }
    public func importPlan(scope: String, data: Data) throws -> VehicleDisplayMetadataPlan {
        // Imported revision never overrides the receiving sidecar's revision.
        try editPlan(scope: scope, metadata: Self.decode(data).metadata)
    }
    public func applying(_ plan: VehicleDisplayMetadataPlan, currentScope: String) throws -> Self {
        try Self.validateScope(currentScope)
        guard currentScope == plan.scope, self == plan.base,
              plan.replacement.revision == revision + 1 else { throw VehicleDisplayMetadataError.stalePlan }
        return plan.replacement
    }
    fileprivate static func validateScope(_ scope: String) throws {
        guard (1...128).contains(scope.utf8.count), scope.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw VehicleDisplayMetadataError.invalidScope }
    }
}

/// Immutable proposal only, not a write, reset, import side effect, or permission grant.
public struct VehicleDisplayMetadataPlan: Equatable, Sendable {
    public let base: VehicleDisplayMetadataDocument
    public let scope: String
    public let replacement: VehicleDisplayMetadataDocument
    fileprivate init(base: VehicleDisplayMetadataDocument, scope: String, replacement: VehicleDisplayMetadataDocument) {
        self.base = base; self.scope = scope; self.replacement = replacement
    }
}
