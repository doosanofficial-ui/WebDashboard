import Foundation

public enum CANSignalPipelineError: Error, Equatable, Sendable {
    case duplicateSignalID(String)
}

public struct DecodedCANSignal: Equatable, Sendable {
    public let definition: SignalDefinition
    public let decoded: DecodedSignal
    public let sample: DecodedSignalSample

    public init(definition: SignalDefinition, frame: CANFrame, decoded: DecodedSignal) {
        self.init(definition: definition, frame: frame, decoded: decoded, recordedQuality: nil)
    }

    init(
        definition: SignalDefinition,
        frame: CANFrame,
        decoded: DecodedSignal,
        recordedQuality: SignalQuality?
    ) {
        self.definition = definition
        self.decoded = decoded
        self.sample = DecodedSignalSample(
            signalID: definition.id,
            value: decoded.value,
            rawValue: decoded.rawValue,
            enumName: decoded.enumName,
            unit: definition.unit,
            frameSequence: frame.sequence,
            receivedAtEpoch: frame.receivedAtEpoch,
            receivedAtMonotonicNanos: frame.receivedAtMonotonicNanos,
            recordedQuality: recordedQuality
        )
    }
}

/// Pure, deterministic signal catalog boundary shared by live and replay paths.
public struct CANSignalPipeline: Sendable {
    private let definitions: [SignalDefinition]

    public init(definitions: [SignalDefinition]) throws {
        var ids = Set<String>()
        for definition in definitions {
            guard ids.insert(definition.id).inserted else {
                throw CANSignalPipelineError.duplicateSignalID(definition.id)
            }
        }
        self.definitions = definitions
    }

    public func decode(_ frame: CANFrame) -> [DecodedCANSignal] {
        definitions.compactMap { definition in
            guard let decoded = try? SignalDecoder.decode(frame, definition: definition) else {
                return nil
            }
            return DecodedCANSignal(
                definition: definition,
                frame: frame,
                decoded: decoded,
                recordedQuality: .valid
            )
        }
    }
}
