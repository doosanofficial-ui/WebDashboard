import Foundation

/// The only state the optional CarPlay projection is allowed to expose in the
/// first slice. It deliberately contains no widget layout or raw CAN payload.
public struct CarPlayProjectionState: Codable, Equatable, Sendable {
    public let adapterState: String
    public let recordingState: String
    public let profileName: String
    public let elapsedSeconds: Int
    public let primaryValues: [String: Double]

    public init(
        adapterState: String,
        recordingState: String,
        profileName: String,
        elapsedSeconds: Int,
        primaryValues: [String: Double]
    ) {
        self.adapterState = adapterState
        self.recordingState = recordingState
        self.profileName = profileName
        self.elapsedSeconds = max(0, elapsedSeconds)
        self.primaryValues = Self.limit(primaryValues)
    }

    private static func limit(_ values: [String: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: values
            .filter { $0.value.isFinite }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
            .prefix(4))
    }

    private enum CodingKeys: String, CodingKey {
        case adapterState, recordingState, profileName, elapsedSeconds, primaryValues
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            adapterState: try values.decode(String.self, forKey: .adapterState),
            recordingState: try values.decode(String.self, forKey: .recordingState),
            profileName: try values.decode(String.self, forKey: .profileName),
            elapsedSeconds: try values.decode(Int.self, forKey: .elapsedSeconds),
            primaryValues: try values.decode([String: Double].self, forKey: .primaryValues)
        )
    }
}
