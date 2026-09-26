import Foundation

public enum CANFrameError: Error, Equatable, Sendable {
    case nonFiniteTimestamp
    case invalidIdentifier
    case invalidDLC
    case payloadLengthMismatch
}

public struct CANFrame: Codable, Equatable, Sendable {
    public let receivedAtEpoch: Double
    public let receivedAtMonotonicNanos: UInt64
    public let canID: UInt32
    public let isExtended: Bool
    public let dlc: Int
    public let payload: [UInt8]
    public let sourceAdapter: String
    public let sourceTransport: String
    public let sequence: UInt64

    public init(
        receivedAtEpoch: Double,
        receivedAtMonotonicNanos: UInt64,
        canID: UInt32,
        isExtended: Bool,
        dlc: Int,
        payload: [UInt8],
        sourceAdapter: String,
        sourceTransport: String,
        sequence: UInt64
    ) throws {
        guard receivedAtEpoch.isFinite else { throw CANFrameError.nonFiniteTimestamp }
        guard dlc >= 0 && dlc <= 8 else { throw CANFrameError.invalidDLC }
        guard payload.count == dlc else { throw CANFrameError.payloadLengthMismatch }
        let maximumID = isExtended ? UInt32(0x1FFF_FFFF) : UInt32(0x7FF)
        guard canID <= maximumID else { throw CANFrameError.invalidIdentifier }
        self.receivedAtEpoch = receivedAtEpoch
        self.receivedAtMonotonicNanos = receivedAtMonotonicNanos
        self.canID = canID
        self.isExtended = isExtended
        self.dlc = dlc
        self.payload = payload
        self.sourceAdapter = sourceAdapter
        self.sourceTransport = sourceTransport
        self.sequence = sequence
    }
}

public enum ByteOrder: String, Codable, Equatable, Sendable {
    case intel
    case motorola
}

public enum SignalDefinitionError: Error, Equatable, Sendable {
    case emptyIdentifier
    case invalidCANIdentifier
    case invalidBitRange
    case nonFiniteScaling
    case invalidLimits
    case invalidTimeout
}

public struct SignalDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let canID: UInt32
    public let isExtended: Bool
    public let startBit: Int
    public let bitLength: Int
    public let byteOrder: ByteOrder
    public let isSigned: Bool
    public let factor: Double
    public let offset: Double
    public let minimum: Double?
    public let maximum: Double?
    public let unit: String
    public let timeout: Double
    public let enumMap: [UInt64: String]

    public init(
        id: String,
        name: String,
        canID: UInt32,
        isExtended: Bool,
        startBit: Int,
        bitLength: Int,
        byteOrder: ByteOrder,
        isSigned: Bool,
        factor: Double,
        offset: Double,
        minimum: Double?,
        maximum: Double?,
        unit: String,
        timeout: Double,
        enumMap: [UInt64: String] = [:]
    ) throws {
        guard !id.isEmpty, !name.isEmpty else { throw SignalDefinitionError.emptyIdentifier }
        let maximumID = isExtended ? UInt32(0x1FFF_FFFF) : UInt32(0x7FF)
        guard canID <= maximumID else { throw SignalDefinitionError.invalidCANIdentifier }
        guard Self.isValidBitRange(startBit: startBit, bitLength: bitLength, byteOrder: byteOrder) else {
            throw SignalDefinitionError.invalidBitRange
        }
        guard factor.isFinite && offset.isFinite else { throw SignalDefinitionError.nonFiniteScaling }
        if let minimum, !minimum.isFinite { throw SignalDefinitionError.invalidLimits }
        if let maximum, !maximum.isFinite { throw SignalDefinitionError.invalidLimits }
        if let minimum, let maximum, minimum > maximum { throw SignalDefinitionError.invalidLimits }
        guard timeout.isFinite && timeout > 0 else { throw SignalDefinitionError.invalidTimeout }
        self.id = id
        self.name = name
        self.canID = canID
        self.isExtended = isExtended
        self.startBit = startBit
        self.bitLength = bitLength
        self.byteOrder = byteOrder
        self.isSigned = isSigned
        self.factor = factor
        self.offset = offset
        self.minimum = minimum
        self.maximum = maximum
        self.unit = unit
        self.timeout = timeout
        self.enumMap = enumMap
    }

    static func isValidBitRange(startBit: Int, bitLength: Int, byteOrder: ByteOrder) -> Bool {
        guard startBit >= 0, startBit < 64, bitLength >= 1, bitLength <= 64 else { return false }
        if byteOrder == .intel {
            return startBit + bitLength <= 64
        }
        var bit = startBit
        for _ in 0..<bitLength {
            guard bit >= 0, bit < 64 else { return false }
            let bitInByte = bit % 8
            bit = bitInByte == 0 ? bit + 15 : bit - 1
        }
        return true
    }
}

public enum SignalDecodeError: Error, Equatable, Sendable {
    case frameIdentifierMismatch
    case payloadTooShort
    case valueOutOfRange
}

public struct DecodedSignal: Equatable, Sendable {
    public let rawValue: UInt64
    public let signedRawValue: Int64?
    public let value: Double
    public let enumName: String?

    public init(rawValue: UInt64, signedRawValue: Int64?, value: Double, enumName: String?) {
        self.rawValue = rawValue
        self.signedRawValue = signedRawValue
        self.value = value
        self.enumName = enumName
    }
}

public enum SignalDecoder {
    public static func decode(_ frame: CANFrame, definition: SignalDefinition) throws -> DecodedSignal {
        guard frame.canID == definition.canID, frame.isExtended == definition.isExtended else {
            throw SignalDecodeError.frameIdentifierMismatch
        }
        let positions = bitPositions(startBit: definition.startBit,
                                     bitLength: definition.bitLength,
                                     byteOrder: definition.byteOrder)
        guard positions.allSatisfy({ $0 < frame.dlc * 8 }) else {
            throw SignalDecodeError.payloadTooShort
        }

        var raw: UInt64 = 0
        if definition.byteOrder == .intel {
            for (offset, position) in positions.enumerated() {
                let bit = UInt64((frame.payload[position / 8] >> (position % 8)) & 1)
                raw |= bit << UInt64(offset)
            }
        } else {
            for position in positions {
                let bit = UInt64((frame.payload[position / 8] >> (position % 8)) & 1)
                raw = (raw << 1) | bit
            }
        }

        let signedRaw: Int64?
        let numericRaw: Double
        if definition.isSigned {
            let signBit = UInt64(1) << UInt64(definition.bitLength - 1)
            let mask = mask(for: definition.bitLength)
            let signed = (raw & signBit) == 0
                ? Int64(raw)
                : Int64(bitPattern: raw | ~mask)
            signedRaw = signed
            numericRaw = Double(signed)
        } else {
            signedRaw = nil
            numericRaw = Double(raw)
        }

        let value = numericRaw * definition.factor + definition.offset
        if let minimum = definition.minimum, value < minimum {
            throw SignalDecodeError.valueOutOfRange
        }
        if let maximum = definition.maximum, value > maximum {
            throw SignalDecodeError.valueOutOfRange
        }
        return DecodedSignal(rawValue: raw,
                             signedRawValue: signedRaw,
                             value: value,
                             enumName: definition.enumMap[raw])
    }

    private static func mask(for bitLength: Int) -> UInt64 {
        bitLength == 64 ? UInt64.max : (UInt64(1) << UInt64(bitLength)) - 1
    }

    private static func bitPositions(startBit: Int, bitLength: Int, byteOrder: ByteOrder) -> [Int] {
        if byteOrder == .intel {
            return Array(startBit..<(startBit + bitLength))
        }
        var bit = startBit
        var positions: [Int] = []
        positions.reserveCapacity(bitLength)
        for _ in 0..<bitLength {
            positions.append(bit)
            let bitInByte = bit % 8
            bit = bitInByte == 0 ? bit + 15 : bit - 1
        }
        return positions
    }
}
