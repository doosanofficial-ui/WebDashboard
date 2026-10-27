import Foundation

public enum VehicleContextError: Error, Equatable, Sendable {
    case emptyIdentifier
}

/// Explicit local scope only. None of these identifiers proves a VIN or ECU identity.
public struct VehicleContext: Codable, Equatable, Sendable {
    public let localContextID: String
    public let profileID: String
    public let profileRevision: String
    public let sessionID: String

    public init(localContextID: String, profileID: String, profileRevision: String, sessionID: String) throws {
        guard [localContextID, profileID, profileRevision, sessionID].allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { throw VehicleContextError.emptyIdentifier }
        self.localContextID = localContextID
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case localContextID, profileID, profileRevision, sessionID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(localContextID: values.decode(String.self, forKey: .localContextID),
            profileID: values.decode(String.self, forKey: .profileID),
            profileRevision: values.decode(String.self, forKey: .profileRevision),
            sessionID: values.decode(String.self, forKey: .sessionID))
    }

    func sharesLocalProfile(with other: Self) -> Bool {
        localContextID == other.localContextID && profileID == other.profileID
            && profileRevision == other.profileRevision
    }
}
