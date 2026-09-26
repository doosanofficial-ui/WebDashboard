import Foundation

public enum ServerCANFrameError: Error, Equatable, Sendable {
    case unsupportedVersion
    case nonFiniteTimestamp
    case invalidSequence
    case invalidDropCount
    case tooManySignals
    case invalidSignalKey
    case nonFiniteSignal
}

/// Validated server-to-iOS CAN snapshot contract.
///
/// Validation happens at the decoding boundary so malformed or hostile server
/// data cannot become a dashboard value or a recorded measurement.
public struct ServerCANFrame: Codable, Equatable, Sendable {
    public struct Status: Codable, Equatable, Sendable {
        public let seq: Int
        public let drop: Int

        public init(sequence: Int, drop: Int) {
            self.seq = sequence
            self.drop = drop
        }
    }

    public let v: Int
    public let t: Double
    public let sig: [String: Double]
    public let status: Status

    public init(
        version: Int,
        serverTimestamp: Double,
        signals: [String: Double],
        status: Status
    ) throws {
        guard version == 1 else { throw ServerCANFrameError.unsupportedVersion }
        guard serverTimestamp.isFinite else { throw ServerCANFrameError.nonFiniteTimestamp }
        guard status.seq >= 0 else { throw ServerCANFrameError.invalidSequence }
        guard status.drop >= 0 else { throw ServerCANFrameError.invalidDropCount }
        guard signals.count <= 256 else { throw ServerCANFrameError.tooManySignals }
        for (key, value) in signals {
            guard !key.isEmpty, key.utf8.count <= 128,
                  !key.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw ServerCANFrameError.invalidSignalKey
            }
            guard value.isFinite else { throw ServerCANFrameError.nonFiniteSignal }
        }
        v = version
        t = serverTimestamp
        sig = signals
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case v, t, sig, status }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .v),
            serverTimestamp: container.decode(Double.self, forKey: .t),
            signals: container.decode([String: Double].self, forKey: .sig),
            status: container.decode(Status.self, forKey: .status)
        )
    }
}
