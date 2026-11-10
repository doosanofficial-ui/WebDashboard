import Foundation

public enum StandardMode01CandidateError: Error, Equatable, Sendable {
    case invalidAddress
    case invalidTiming
    case responseIdentityMismatch
    case incorrectPayloadLength
}

/// Explicit caller policy, not a vehicle recommendation or support observation.
/// Construction only validates values; it does not authorize or schedule a query.
public struct StandardMode01CandidateContext: Equatable, Sendable {
    public let requestCANID: UInt32
    public let responseCANID: UInt32
    public let isExtended: Bool
    public let pollInterval: Double
    public let timeout: Double
    public let signalTimeout: Double
    public let minimumPollInterval: Double
    public let maximumTimeout: Double

    public init(requestCANID: UInt32, responseCANID: UInt32, isExtended: Bool,
                pollInterval: Double, timeout: Double, signalTimeout: Double,
                minimumPollInterval: Double, maximumTimeout: Double) throws {
        let maximumID: UInt32 = isExtended ? 0x1FFF_FFFF : 0x7FF
        guard requestCANID <= maximumID, responseCANID <= maximumID else {
            throw StandardMode01CandidateError.invalidAddress
        }
        let values = [pollInterval, timeout, signalTimeout, minimumPollInterval, maximumTimeout]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }),
              minimumPollInterval <= pollInterval, pollInterval <= timeout,
              timeout <= maximumTimeout, signalTimeout >= timeout,
              let nanos = UInt64(exactly: (pollInterval * 1_000_000_000).rounded(.towardZero)),
              nanos > 0 else { throw StandardMode01CandidateError.invalidTiming }
        self.requestCANID = requestCANID
        self.responseCANID = responseCANID
        self.isExtended = isExtended
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.signalTimeout = signalTimeout
        self.minimumPollInterval = minimumPollInterval
        self.maximumTimeout = maximumTimeout
    }
}

/// Independently authored candidates from documented protocol arithmetic.
/// NOT OBDb data, a complete SAE catalog, a profile, or a support cache.
/// No query factory: existing repository-only provenance needs an explicit adapter design.
public enum StandardMode01Candidate: String, CaseIterable, Sendable {
    case load = "04"
    case fuelPressure = "0A"
    case manifoldPressure = "0B"
    case intakeTemperature = "0F"
    case airMassFlow = "10"
    case throttle = "11"
    case engineRuntime = "1F"
    case fuelLevel = "2F"
    case barometricPressure = "33"
    case moduleVoltage = "42"
    case ambientTemperature = "46"
    case oilTemperature = "5C"
    case fuelRate = "5E"
    case railGaugePressure = "23"

    /// Original twelve-candidate reference; use sourceDocumentationURL per candidate.
    public static let documentationURL = "https://docs.emtronaustralia.com.au/displays/functions/obd2/index.html"
    public static let documentationSection = "Standard PIDs / Service 0x01 Common PIDs"
    public static let documentationReviewedOn = "2026-11-04"
    public var sourceDocumentationURL: String {
        switch self {
        case .fuelRate: return "https://www.dashlogic.com/docs/technical/obdii_pids"
        case .railGaugePressure: return "https://f30.bimmerpost.com/forums/attachment.php?attachmentid=1800282&d=1523076762"
        default: return Self.documentationURL
        }
    }
    public var sourceDocumentationSection: String {
        switch self {
        case .fuelRate: return "OBD-II J1979 PID Listing / $5E"
        case .railGaugePressure: return "SAE J1979-DA OCT2011, Table B29, printed page 19; third-party mirror"
        default: return Self.documentationSection
        }
    }
    public var supportGuaranteed: Bool { false }
    public var automaticallySelected: Bool { false }

    public var payloadByteCount: Int {
        switch self {
        case .airMassFlow, .engineRuntime, .moduleVoltage, .fuelRate, .railGaugePressure: return 2
        default: return 1
        }
    }
    private var name: String {
        switch self {
        case .railGaugePressure: return "Fuel rail pressure (atmospheric gauge)"
        case .fuelRate: return "Engine fuel rate"
        case .load: return "Calculated engine load"
        case .fuelPressure: return "Fuel pressure (PID 0A)"
        case .manifoldPressure: return "Intake manifold pressure"
        case .intakeTemperature: return "Intake air temperature"
        case .airMassFlow: return "Mass air flow"
        case .throttle: return "Throttle position"
        case .engineRuntime: return "Engine runtime"
        case .fuelLevel: return "Fuel level"
        case .barometricPressure: return "Barometric pressure"
        case .moduleVoltage: return "Control module voltage"
        case .ambientTemperature: return "Ambient air temperature"
        case .oilTemperature: return "Engine oil temperature"
        }
    }
    private var scaling: (factor: Double, offset: Double, unit: String) {
        switch self {
        case .load, .throttle, .fuelLevel: return (100.0 / 255.0, 0, "percent")
        case .fuelPressure: return (3, 0, "kPa")
        case .manifoldPressure, .barometricPressure: return (1, 0, "kPa")
        case .intakeTemperature, .ambientTemperature, .oilTemperature: return (1, -40, "degC")
        case .airMassFlow: return (0.01, 0, "g/s")
        case .engineRuntime: return (1, 0, "s")
        case .moduleVoltage: return (0.001, 0, "V")
        case .fuelRate: return (0.05, 0, "L/h")
        case .railGaugePressure: return (10, 0, "kPa")
        }
    }
    /// Uses the existing decoder contract, including Motorola start bit 7.
    /// Unit strings are candidate-local; UI/archive unit acceptance is an integration gate.
    public func signalDefinition(context: StandardMode01CandidateContext) throws -> OBDSignalDefinition {
        let scale = scaling
        let rawMaximum = payloadByteCount == 1 ? 255.0 : 65535.0
        return try OBDSignalDefinition(
            id: "STANDARD_MODE01_\(rawValue)", name: name,
            startBit: 7, bitLength: payloadByteCount * 8, byteOrder: .motorola,
            isSigned: false, factor: scale.factor, offset: scale.offset,
            minimum: scale.offset, maximum: rawMaximum * scale.factor + scale.offset,
            unit: scale.unit, timeout: context.signalTimeout,
            suggestedMetric: nil, path: "Standard OBD candidates")
    }
    /// Call before OBDSignalDecoder.decode. Payload excludes service, PID and CAN padding.
    /// This verifies recorded response association, never current vehicle support or sensor validity.
    /// Raw extrema may be ECU defaults/unavailable markers; no universal sentinel inference is safe.
    public func validateResponse(_ response: OBDResponse, context: StandardMode01CandidateContext) throws {
        guard response.service == .mode01, response.command == rawValue,
              response.responseCANID == context.responseCANID,
              response.isExtended == context.isExtended else {
            throw StandardMode01CandidateError.responseIdentityMismatch
        }
        guard response.payload.count == payloadByteCount else {
            throw StandardMode01CandidateError.incorrectPayloadLength
        }
    }
}
