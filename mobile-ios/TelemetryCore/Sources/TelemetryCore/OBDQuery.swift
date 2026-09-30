import Foundation

/// Read-only OBD services supported by the diagnostic query layer.
public enum OBDService: String, Codable, Equatable, Sendable {
    case mode01 = "01"
    case service21 = "21"
    case service22 = "22"

    var positiveResponseByte: UInt8 {
        UInt8(rawValue, radix: 16)! + 0x40
    }

    var commandByteCount: Int {
        self == .mode01 ? 1 : 2
    }
}

public enum OBDQueryError: Error, Equatable, Sendable {
    case emptyIdentifier
    case invalidIdentifier
    case invalidCommand
    case invalidCANIdentifier
    case invalidResponseIdentifier
    case invalidTiming
    case emptySignalCatalog
    case duplicateSignalID(String)
    case nonFiniteScaling
    case invalidLimits
    case invalidBitRange
    case invalidTimeout
}

/// A signal inside an OBD response payload. Bit numbering matches the CAN
/// signal convention already used by TelemetryCore.
public struct OBDSignalDefinition: Codable, Equatable, Sendable {
    // Offsets refer to the reassembled diagnostic payload, not one CAN frame.
    // Bound offsets by the 12-bit ISO-TP lengths supported by our parser;
    // each decoded scalar still fits UInt64. This does not add CAN FD support.
    private static let maximumPayloadBits = 4095 * 8

    public let id: String
    public let name: String
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
    public let suggestedMetric: String?
    public let path: String?

    public init(
        id: String,
        name: String,
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
        enumMap: [UInt64: String] = [:],
        suggestedMetric: String? = nil,
        path: String? = nil
    ) throws {
        guard !id.isEmpty, !name.isEmpty else { throw OBDQueryError.emptyIdentifier }
        guard startBit >= 0, startBit < Self.maximumPayloadBits, bitLength >= 1, bitLength <= 64,
              Self.isValidBitRange(startBit: startBit, bitLength: bitLength, byteOrder: byteOrder) else {
            throw OBDQueryError.invalidBitRange
        }
        guard factor.isFinite && offset.isFinite else { throw OBDQueryError.nonFiniteScaling }
        if let minimum, !minimum.isFinite { throw OBDQueryError.invalidLimits }
        if let maximum, !maximum.isFinite { throw OBDQueryError.invalidLimits }
        if let minimum, let maximum, minimum > maximum { throw OBDQueryError.invalidLimits }
        guard timeout.isFinite && timeout > 0 else { throw OBDQueryError.invalidTimeout }
        self.id = id
        self.name = name
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
        self.suggestedMetric = suggestedMetric
        self.path = path
    }

    private static func isValidBitRange(startBit: Int, bitLength: Int, byteOrder: ByteOrder) -> Bool {
        if byteOrder == .intel {
            return bitLength <= maximumPayloadBits - startBit
        }
        var bit = startBit
        for _ in 0..<bitLength {
            guard bit >= 0, bit < maximumPayloadBits else { return false }
            let bitInByte = bit % 8
            bit = bitInByte == 0 ? bit + 15 : bit - 1
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, startBit, bitLength, byteOrder, isSigned, factor, offset
        case minimum, maximum, unit, timeout, enumMap, suggestedMetric, path
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            id: values.decode(String.self, forKey: .id),
            name: values.decode(String.self, forKey: .name),
            startBit: values.decode(Int.self, forKey: .startBit),
            bitLength: values.decode(Int.self, forKey: .bitLength),
            byteOrder: values.decode(ByteOrder.self, forKey: .byteOrder),
            isSigned: values.decode(Bool.self, forKey: .isSigned),
            factor: values.decode(Double.self, forKey: .factor),
            offset: values.decode(Double.self, forKey: .offset),
            minimum: values.decodeIfPresent(Double.self, forKey: .minimum),
            maximum: values.decodeIfPresent(Double.self, forKey: .maximum),
            unit: values.decode(String.self, forKey: .unit),
            timeout: values.decode(Double.self, forKey: .timeout),
            enumMap: values.decodeIfPresent([UInt64: String].self, forKey: .enumMap) ?? [:],
            suggestedMetric: values.decodeIfPresent(String.self, forKey: .suggestedMetric),
            path: values.decodeIfPresent(String.self, forKey: .path)
        )
    }
}

/// A complete read-only query definition with its source provenance.
public struct OBDQueryDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let requestCANID: UInt32
    public let responseCANID: UInt32
    public let isExtended: Bool
    public let service: OBDService
    /// Hex command bytes without the service byte: one byte for Mode 01,
    /// two bytes for services 21/22.
    public let command: String
    public let pollInterval: Double
    public let timeout: Double
    public let flowControl: Bool
    public let sourceRepository: String
    public let sourcePath: String
    public let sourceCommit: String
    public let signals: [OBDSignalDefinition]

    public var requestString: String {
        "\(service.rawValue)\(command)\r"
    }

    public init(
        id: String,
        name: String,
        requestCANID: UInt32,
        responseCANID: UInt32,
        isExtended: Bool,
        service: OBDService,
        command: String,
        pollInterval: Double,
        timeout: Double,
        flowControl: Bool,
        sourceRepository: String,
        sourcePath: String,
        sourceCommit: String,
        signals: [OBDSignalDefinition]
    ) throws {
        guard !id.isEmpty, !name.isEmpty else { throw OBDQueryError.emptyIdentifier }
        let maximumID = isExtended ? UInt32(0x1FFF_FFFF) : UInt32(0x7FF)
        guard requestCANID <= maximumID else { throw OBDQueryError.invalidCANIdentifier }
        guard responseCANID <= maximumID else { throw OBDQueryError.invalidResponseIdentifier }
        guard pollInterval.isFinite, pollInterval > 0,
              timeout.isFinite, timeout > 0,
              timeout >= pollInterval else { throw OBDQueryError.invalidTiming }
        // The scheduler converts seconds to UInt64 nanoseconds. Finiteness in
        // seconds alone does not prevent overflow or a zero-delay truncation.
        guard let pollNanoseconds = UInt64(exactly: (pollInterval * 1_000_000_000).rounded(.towardZero)),
              pollNanoseconds > 0 else { throw OBDQueryError.invalidTiming }
        let normalizedCommand = command.uppercased()
        guard normalizedCommand.count == service.commandByteCount * 2,
              normalizedCommand.unicodeScalars.allSatisfy(Self.isHexScalar) else {
            throw OBDQueryError.invalidCommand
        }
        guard !signals.isEmpty else { throw OBDQueryError.emptySignalCatalog }
        var signalIDs = Set<String>()
        for signal in signals {
            guard signalIDs.insert(signal.id).inserted else {
                throw OBDQueryError.duplicateSignalID(signal.id)
            }
        }
        self.id = id
        self.name = name
        self.requestCANID = requestCANID
        self.responseCANID = responseCANID
        self.isExtended = isExtended
        self.service = service
        self.command = normalizedCommand
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.flowControl = flowControl
        self.sourceRepository = sourceRepository
        self.sourcePath = sourcePath
        self.sourceCommit = sourceCommit
        self.signals = signals
    }

    private static func isHexScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...70, 97...102: return true
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, requestCANID, responseCANID, isExtended, service, command
        case pollInterval, timeout, flowControl, sourceRepository, sourcePath, sourceCommit, signals
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            id: values.decode(String.self, forKey: .id),
            name: values.decode(String.self, forKey: .name),
            requestCANID: values.decode(UInt32.self, forKey: .requestCANID),
            responseCANID: values.decode(UInt32.self, forKey: .responseCANID),
            isExtended: values.decode(Bool.self, forKey: .isExtended),
            service: values.decode(OBDService.self, forKey: .service),
            command: values.decode(String.self, forKey: .command),
            pollInterval: values.decode(Double.self, forKey: .pollInterval),
            timeout: values.decode(Double.self, forKey: .timeout),
            flowControl: values.decode(Bool.self, forKey: .flowControl),
            sourceRepository: values.decode(String.self, forKey: .sourceRepository),
            sourcePath: values.decode(String.self, forKey: .sourcePath),
            sourceCommit: values.decode(String.self, forKey: .sourceCommit),
            signals: values.decode([OBDSignalDefinition].self, forKey: .signals)
        )
    }
}

public enum OBDResponseError: Error, Equatable, Sendable {
    case malformed
    case noData
    case bufferFull
    case unexpectedResponse
    case negativeResponse(code: UInt8)
    case responseAddressMismatch
    case serviceMismatch
    case commandMismatch
    case incompleteMultiFrame
}

public struct OBDResponse: Codable, Equatable, Sendable {
    public let receivedAtEpoch: Double
    public let receivedAtMonotonicNanos: UInt64
    public let responseCANID: UInt32
    public let isExtended: Bool
    public let service: OBDService
    public let command: String
    public let payload: [UInt8]
    public let sequence: UInt64
    public let sourceAdapter: String
    public let sourceTransport: String

    init(
        receivedAtEpoch: Double,
        receivedAtMonotonicNanos: UInt64,
        responseCANID: UInt32,
        isExtended: Bool,
        service: OBDService,
        command: String,
        payload: [UInt8],
        sequence: UInt64,
        sourceAdapter: String,
        sourceTransport: String
    ) {
        self.receivedAtEpoch = receivedAtEpoch
        self.receivedAtMonotonicNanos = receivedAtMonotonicNanos
        self.responseCANID = responseCANID
        self.isExtended = isExtended
        self.service = service
        self.command = command
        self.payload = payload
        self.sequence = sequence
        self.sourceAdapter = sourceAdapter
        self.sourceTransport = sourceTransport
    }
}

/// Parses ELM327 header-on output after the transport has assembled a prompt
/// terminated response. This parser intentionally accepts only the query's
/// expected ECU/service/command and never treats diagnostic data as passive CAN.
public enum OBDResponseParser {
    public static func parse(
        _ text: String,
        for query: OBDQueryDefinition,
        receivedAtEpoch: Double,
        receivedAtMonotonicNanos: UInt64,
        sequence: UInt64,
        sourceAdapter: String = "elm327",
        sourceTransport: String = "ble"
    ) throws -> OBDResponse {
        guard receivedAtEpoch.isFinite else { throw OBDResponseError.malformed }
        let normalized = text.replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.components(separatedBy: .newlines)
        var frames: [(id: UInt32, isExtended: Bool, bytes: [UInt8])] = []

        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()
            if upper.contains("NO DATA") || upper.contains("NODATA") {
                throw OBDResponseError.noData
            }
            if upper.contains("BUFFER FULL") || upper.contains("BUFFERFULL") {
                throw OBDResponseError.bufferFull
            }
            let parsedLine = try parseLine(line, for: query)
            guard let parsedLine else { continue }
            let (header, isExtended, bytes) = parsedLine
            guard !bytes.isEmpty else { throw OBDResponseError.malformed }
            guard header <= (isExtended ? 0x1FFF_FFFF : 0x7FF) else {
                throw OBDResponseError.malformed
            }
            guard header == query.responseCANID, isExtended == query.isExtended else {
                throw OBDResponseError.unexpectedResponse
            }
            frames.append((header, isExtended, stripOptionalDLC(bytes)))
        }

        guard let first = frames.first else { throw OBDResponseError.malformed }
        guard frames.allSatisfy({ $0.id == first.id && $0.isExtended == first.isExtended }) else {
            throw OBDResponseError.unexpectedResponse
        }

        let assembled = try assembleISO15765(frames.map(\.bytes))
        let expectedService = query.service.positiveResponseByte
        guard assembled.count >= 1 else { throw OBDResponseError.malformed }
        if assembled[0] == 0x7F {
            guard assembled.count >= 3 else { throw OBDResponseError.malformed }
            guard assembled[1] == parseHexByte(query.service.rawValue),
                  commandBytes(query.command).count == 1 || assembled[1] == parseHexByte(query.service.rawValue) else {
                throw OBDResponseError.unexpectedResponse
            }
            throw OBDResponseError.negativeResponse(code: assembled[2])
        }
        guard assembled[0] == expectedService else { throw OBDResponseError.serviceMismatch }
        let commandBytes = commandBytes(query.command)
        guard assembled.count >= 1 + commandBytes.count else { throw OBDResponseError.malformed }
        guard Array(assembled[1..<(1 + commandBytes.count)]) == commandBytes else {
            throw OBDResponseError.commandMismatch
        }
        let payload = Array(assembled.dropFirst(1 + commandBytes.count))
        return OBDResponse(
            receivedAtEpoch: receivedAtEpoch,
            receivedAtMonotonicNanos: receivedAtMonotonicNanos,
            responseCANID: first.id,
            isExtended: first.isExtended,
            service: query.service,
            command: query.command,
            payload: payload,
            sequence: sequence,
            sourceAdapter: sourceAdapter,
            sourceTransport: sourceTransport
        )
    }

    private static func parseHex(_ token: String) -> UInt32? {
        UInt32(token, radix: 16)
    }

    private static func parseLine(
        _ line: String,
        for query: OBDQueryDefinition
    ) throws -> (UInt32, Bool, [UInt8])? {
        let tokens = line.split { $0 == " " || $0 == "\t" || $0 == ">" }
        guard let first = tokens.first else { return nil }
        let firstToken = String(first)
        let expectedHeader = String(format: query.isExtended ? "%08X" : "%03X", query.responseCANID)

        if tokens.count == 1 {
            let compact = firstToken.uppercased()
            guard compact.hasPrefix(expectedHeader) else { return nil }
            let data = String(compact.dropFirst(expectedHeader.count))
            guard !data.isEmpty, data.count.isMultiple(of: 2) else { throw OBDResponseError.malformed }
            return (query.responseCANID, query.isExtended, try parseCompactBytes(data))
        }

        guard let header = parseHex(firstToken),
              firstToken.count == 3 || firstToken.count == 8 else { return nil }
        let isExtended = firstToken.count == 8
        return (header, isExtended, try tokens.dropFirst().flatMap(parseTokenBytes))
    }

    private static func parseHexByte(_ token: String) -> UInt8 {
        UInt8(token, radix: 16)!
    }

    private static func parseByte(_ token: Substring) throws -> UInt8 {
        let string = String(token)
        guard string.count == 2, let byte = UInt8(string, radix: 16) else {
            throw OBDResponseError.malformed
        }
        return byte
    }

    private static func parseTokenBytes(_ token: Substring) throws -> [UInt8] {
        let string = String(token)
        if string.count == 2 { return [try parseByte(token)] }
        return try parseCompactBytes(string)
    }

    private static func parseCompactBytes(_ string: String) throws -> [UInt8] {
        guard string.count.isMultiple(of: 2) else { throw OBDResponseError.malformed }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let end = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<end], radix: 16) else {
                throw OBDResponseError.malformed
            }
            bytes.append(byte)
            index = end
        }
        return bytes
    }

    private static func stripOptionalDLC(_ bytes: [UInt8]) -> [UInt8] {
        guard let first = bytes.first, first <= 8, bytes.count > 1 else { return bytes }
        let remainingCount = bytes.count - 1
        if Int(first) == remainingCount { return Array(bytes.dropFirst()) }
        if Int(first) > remainingCount, let next = bytes.dropFirst().first,
           [0, 1, 2, 3].contains(next >> 4) {
            return Array(bytes.dropFirst())
        }
        return bytes
    }

    private static func assembleISO15765(_ frames: [[UInt8]]) throws -> [UInt8] {
        guard let first = frames.first, !first.isEmpty else { throw OBDResponseError.malformed }
        let pciType = first[0] >> 4
        switch pciType {
        case 0:
            let length = Int(first[0] & 0x0F)
            let data = Array(first.dropFirst())
            guard data.count >= length else { throw OBDResponseError.incompleteMultiFrame }
            return Array(data.prefix(length))
        case 1:
            guard first.count >= 2 else { throw OBDResponseError.malformed }
            let expectedLength = (Int(first[0] & 0x0F) << 8) | Int(first[1])
            var data = Array(first.dropFirst(2))
            var expectedSequence: UInt8 = 1
            for frame in frames.dropFirst() {
                guard !frame.isEmpty, frame[0] >> 4 == 2,
                      (frame[0] & 0x0F) == expectedSequence else {
                    throw OBDResponseError.incompleteMultiFrame
                }
                data.append(contentsOf: frame.dropFirst())
                expectedSequence = (expectedSequence + 1) & 0x0F
            }
            guard data.count >= expectedLength else { throw OBDResponseError.incompleteMultiFrame }
            return Array(data.prefix(expectedLength))
        default:
            return frames.flatMap { $0 }
        }
    }

    private static func commandBytes(_ command: String) -> [UInt8] {
        stride(from: 0, to: command.count, by: 2).compactMap { index in
            let start = command.index(command.startIndex, offsetBy: index)
            let end = command.index(start, offsetBy: 2)
            return UInt8(command[start..<end], radix: 16)
        }
    }
}

public enum OBDSignalDecodeError: Error, Equatable, Sendable {
    case payloadTooShort
    case valueOutOfRange
}

public struct DecodedOBDSignal: Codable, Equatable, Sendable {
    public let signalID: String
    public let name: String
    public let rawValue: UInt64
    public let signedRawValue: Int64?
    public let value: Double
    public let enumName: String?
    public let unit: String
    public let suggestedMetric: String?
    public let path: String?
    public let receivedAtEpoch: Double
    public let receivedAtMonotonicNanos: UInt64
    public let sequence: UInt64
    public let sourceAdapter: String
    public let sourceTransport: String

    init(signal: OBDSignalDefinition, rawValue: UInt64, signedRawValue: Int64?, value: Double,
         enumName: String?, response: OBDResponse) {
        self.signalID = signal.id
        self.name = signal.name
        self.rawValue = rawValue
        self.signedRawValue = signedRawValue
        self.value = value
        self.enumName = enumName
        self.unit = signal.unit
        self.suggestedMetric = signal.suggestedMetric
        self.path = signal.path
        self.receivedAtEpoch = response.receivedAtEpoch
        self.receivedAtMonotonicNanos = response.receivedAtMonotonicNanos
        self.sequence = response.sequence
        self.sourceAdapter = response.sourceAdapter
        self.sourceTransport = response.sourceTransport
    }
}

public enum OBDSignalDecoder {
    public static func decode(_ signal: OBDSignalDefinition, response: OBDResponse) throws -> DecodedOBDSignal {
        let positions = bitPositions(startBit: signal.startBit,
                                     bitLength: signal.bitLength,
                                     byteOrder: signal.byteOrder)
        guard positions.allSatisfy({ $0 < response.payload.count * 8 }) else {
            throw OBDSignalDecodeError.payloadTooShort
        }
        var raw: UInt64 = 0
        if signal.byteOrder == .intel {
            for (offset, position) in positions.enumerated() {
                let bit = UInt64((response.payload[position / 8] >> (position % 8)) & 1)
                raw |= bit << UInt64(offset)
            }
        } else {
            for position in positions {
                let bit = UInt64((response.payload[position / 8] >> (position % 8)) & 1)
                raw = (raw << 1) | bit
            }
        }

        let signedRawValue: Int64?
        let numericRaw: Double
        if signal.isSigned {
            let signBit = UInt64(1) << UInt64(signal.bitLength - 1)
            let mask = mask(for: signal.bitLength)
            let signed = (raw & signBit) == 0 ? Int64(raw) : Int64(bitPattern: raw | ~mask)
            signedRawValue = signed
            numericRaw = Double(signed)
        } else {
            signedRawValue = nil
            numericRaw = Double(raw)
        }
        let value = numericRaw * signal.factor + signal.offset
        guard value.isFinite else { throw OBDSignalDecodeError.valueOutOfRange }
        if let minimum = signal.minimum, value < minimum { throw OBDSignalDecodeError.valueOutOfRange }
        if let maximum = signal.maximum, value > maximum { throw OBDSignalDecodeError.valueOutOfRange }
        return DecodedOBDSignal(signal: signal, rawValue: raw, signedRawValue: signedRawValue,
                                value: value, enumName: signal.enumMap[raw], response: response)
    }

    private static func mask(for bitLength: Int) -> UInt64 {
        bitLength == 64 ? UInt64.max : (UInt64(1) << UInt64(bitLength)) - 1
    }

    private static func bitPositions(startBit: Int, bitLength: Int, byteOrder: ByteOrder) -> [Int] {
        if byteOrder == .intel { return Array(startBit..<(startBit + bitLength)) }
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
