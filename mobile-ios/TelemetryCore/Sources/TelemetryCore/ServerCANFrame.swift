import Foundation

public enum ServerCANRawFrameError: Error, Equatable, Sendable {
    case nonFiniteTimestamp
    case invalidIdentifier
    case invalidDLC
    case payloadLengthMismatch
    case dataLengthMismatch
    case invalidSource
    case invalidFlags
}

public struct ServerCANRawFrame: Codable, Equatable, Sendable {
    private static let canFDDataLengths = [0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64]

    public let timestamp: Double
    public let channel: String?
    public let source: String
    public let arbitrationID: UInt32
    public let isExtended: Bool
    public let isFD: Bool
    public let bitrateSwitch: Bool
    public let errorStateIndicator: Bool
    public let dlc: Int
    public let data: [UInt8]

    public var dataLength: Int { data.count }

    public init(
        timestamp: Double,
        channel: String?,
        source: String,
        arbitrationID: UInt32,
        isExtended: Bool,
        isFD: Bool,
        bitrateSwitch: Bool,
        errorStateIndicator: Bool,
        dlc: Int,
        data: [UInt8]
    ) throws {
        guard timestamp.isFinite else { throw ServerCANRawFrameError.nonFiniteTimestamp }
        let maximumID = isExtended ? UInt32(0x1FFF_FFFF) : UInt32(0x7FF)
        guard arbitrationID <= maximumID else { throw ServerCANRawFrameError.invalidIdentifier }
        guard (0...15).contains(dlc) else { throw ServerCANRawFrameError.invalidDLC }
        let expectedLength: Int
        if isFD {
            expectedLength = Self.canFDDataLengths[dlc]
        } else {
            guard dlc <= 8, !bitrateSwitch, !errorStateIndicator else {
                throw ServerCANRawFrameError.invalidFlags
            }
            expectedLength = dlc
        }
        guard data.count == expectedLength else { throw ServerCANRawFrameError.payloadLengthMismatch }
        guard !source.isEmpty, source.utf8.count <= 128 else {
            throw ServerCANRawFrameError.invalidSource
        }
        self.timestamp = timestamp
        self.channel = channel
        self.source = source
        self.arbitrationID = arbitrationID
        self.isExtended = isExtended
        self.isFD = isFD
        self.bitrateSwitch = bitrateSwitch
        self.errorStateIndicator = errorStateIndicator
        self.dlc = dlc
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp = "t"
        case channel
        case source
        case arbitrationID = "arbitration_id"
        case isExtended = "extended"
        case isFD = "fd"
        case bitrateSwitch = "brs"
        case errorStateIndicator = "esi"
        case dlc
        case dataLength = "data_length"
        case data
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let data = try values.decode([UInt8].self, forKey: .data)
        if let declaredLength = try values.decodeIfPresent(Int.self, forKey: .dataLength),
           declaredLength != data.count {
            throw ServerCANRawFrameError.dataLengthMismatch
        }
        try self.init(
            timestamp: values.decode(Double.self, forKey: .timestamp),
            channel: values.decodeIfPresent(String.self, forKey: .channel),
            source: values.decode(String.self, forKey: .source),
            arbitrationID: values.decode(UInt32.self, forKey: .arbitrationID),
            isExtended: values.decode(Bool.self, forKey: .isExtended),
            isFD: values.decode(Bool.self, forKey: .isFD),
            bitrateSwitch: values.decodeIfPresent(Bool.self, forKey: .bitrateSwitch) ?? false,
            errorStateIndicator: values.decodeIfPresent(Bool.self, forKey: .errorStateIndicator) ?? false,
            dlc: values.decode(Int.self, forKey: .dlc),
            data: data
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(timestamp, forKey: .timestamp)
        try values.encodeIfPresent(channel, forKey: .channel)
        try values.encode(source, forKey: .source)
        try values.encode(arbitrationID, forKey: .arbitrationID)
        try values.encode(isExtended, forKey: .isExtended)
        try values.encode(isFD, forKey: .isFD)
        try values.encode(bitrateSwitch, forKey: .bitrateSwitch)
        try values.encode(errorStateIndicator, forKey: .errorStateIndicator)
        try values.encode(dlc, forKey: .dlc)
        try values.encode(dataLength, forKey: .dataLength)
        try values.encode(data, forKey: .data)
    }
}

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
    public let raw: ServerCANRawFrame?
    public let status: Status

    public init(
        version: Int,
        serverTimestamp: Double,
        signals: [String: Double],
        status: Status,
        raw: ServerCANRawFrame? = nil
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
        self.raw = raw
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case v, t, sig, raw, status }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .v),
            serverTimestamp: container.decode(Double.self, forKey: .t),
            signals: container.decode([String: Double].self, forKey: .sig),
            status: container.decode(Status.self, forKey: .status),
            raw: container.decodeIfPresent(ServerCANRawFrame.self, forKey: .raw)
        )
    }
}
