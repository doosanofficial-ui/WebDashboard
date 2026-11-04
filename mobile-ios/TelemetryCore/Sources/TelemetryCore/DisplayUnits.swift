// Independent additive proposal. NOT compiled or executed; no persistence/UI coupling.
import Foundation

public enum DUQuantity: String { case speed, distance, temperature, pressure, volume, energy, percentage, economy }
public enum DUUnit: String {
    case kmh = "km/h", mph, km, mi, c = "degC", f = "degF", kPa, bar, psi
    case litre = "L", usGallon = "US gal", imperialGallon = "imp gal", wh = "Wh", kwh = "kWh"
    case percent = "%", l100 = "L/100km", mpgUS = "mpg US", mpgImperial = "mpg imp"
    public var quantity: DUQuantity {
        switch self {
        case .kmh, .mph: return .speed
        case .km, .mi: return .distance
        case .c, .f: return .temperature
        case .kPa, .bar, .psi: return .pressure
        case .litre, .usGallon, .imperialGallon: return .volume
        case .wh, .kwh: return .energy
        case .percent: return .percentage
        case .l100, .mpgUS, .mpgImperial: return .economy
        }
    }
    fileprivate var factor: Double {
        switch self {
        case .mph, .mi: return 1.609344
        case .bar: return 100
        case .psi: return 0.45359237 * 9.80665 / (0.0254 * 0.0254) / 1000
        case .usGallon: return 3.785411784
        case .imperialGallon: return 4.54609
        case .kwh: return 1000
        default: return 1
        }
    }
    fileprivate var economyConstant: Double {
        self == .mpgUS ? 235.21458333333333 : 282.48093633182216
    }
}
public enum DUUnitIdentity: Equatable { case known(DUUnit), custom(String) }
public struct DUMeasurement: Equatable {
    public let value: Double?
    public let quantity: DUQuantity
    public let unit: DUUnitIdentity
    public let provenance: [String]
    public let pressureReference: String?
    public let label: String
    public init(_ value: Double?, _ quantity: DUQuantity, _ unit: DUUnitIdentity,
                provenance: [String] = [], pressureReference: String? = nil, label: String = "") {
        self.value=value; self.quantity=quantity; self.unit=unit; self.provenance=provenance
        self.pressureReference=pressureReference; self.label=label
    }
}
public enum DUUnavailable: String { case missing, nonfiniteInput, unsupportedUnit, quantityMismatch, overflow, underflow, negativeEconomy, nonpositiveDistance, negativeFuel }
public enum DUDisplayState: Equatable { case available(Double), unavailable(DUUnavailable), unbounded }
public struct DUDisplayResult: Equatable {
    public let originals: [DUMeasurement]
    public let unit: DUUnitIdentity
    public let pressureReference: String?
    public let state: DUDisplayState
}
public enum DisplayUnits {
    // Binary exponent decomposition avoids common-base intermediate over/underflow.
    // Final binary64 rounding remains subject to native parity tests before integration.
    private static func ratio(_ numerator: [Double], _ denominator: [Double]) -> Double {
        // Swift's significand is a magnitude; carry operand signs separately.
        var sign: FloatingPointSign = .plus
        for value in numerator + denominator where value.sign == .minus {
            sign = sign == .plus ? .minus : .plus
        }
        if numerator.contains(0) { return Double(sign: sign, exponent: 0, significand: 0) }
        var mantissa=1.0
        var exponent=0
        for value in numerator { mantissa *= value.significand; exponent += value.exponent }
        for value in denominator { mantissa /= value.significand; exponent -= value.exponent }
        return Double(sign: sign, exponent: exponent, significand: mantissa)
    }
    private static func checked(_ value: Double, expectedNonzero: Bool) -> DUDisplayState {
        guard value.isFinite else { return .unavailable(.overflow) }
        if value == 0 && expectedNonzero { return .unavailable(.underflow) }
        return .available(value)
    }
    public static func convert(_ source: DUMeasurement, to target: DUUnit? = nil) -> DUDisplayResult {
        let selected=target.map(DUUnitIdentity.known) ?? source.unit
        func result(_ state: DUDisplayState) -> DUDisplayResult {
            DUDisplayResult(originals: [source], unit: selected, pressureReference: source.pressureReference, state: state)
        }
        guard let x=source.value else { return result(.unavailable(.missing)) }
        guard x.isFinite else { return result(.unavailable(.nonfiniteInput)) }
        if source.quantity == .economy && x < 0 { return result(.unavailable(.negativeEconomy)) }
        guard case let .known(unit)=source.unit else {
            return result(target == nil ? .available(x) : .unavailable(.unsupportedUnit))
        }
        guard unit.quantity == source.quantity, target == nil || target?.quantity == source.quantity else {
            return result(.unavailable(.quantityMismatch))
        }
        guard let target=target, target != unit else { return result(.available(x)) }
        if source.quantity == .temperature {
            let value=unit == .c ? x * 1.8 + 32 : (x - 32) / 1.8
            return result(checked(value, expectedNonzero: unit == .c ? x != (-160.0/9.0) : x != 32))
        }
        if source.quantity == .economy {
            if unit == .l100 || target == .l100 {
                if x == 0 { return result(.unbounded) }
                let constant=unit == .l100 ? target.economyConstant : unit.economyConstant
                return result(checked(ratio([constant], [x]), expectedNonzero: true))
            }
            return result(checked(ratio([x,target.economyConstant], [unit.economyConstant]), expectedNonzero: x != 0))
        }
        return result(checked(ratio([x,unit.factor], [target.factor]), expectedNonzero: x != 0))
    }
    public static func economy(fuel: DUMeasurement, distance: DUMeasurement, to target: DUUnit) -> DUDisplayResult {
        func result(_ state: DUDisplayState) -> DUDisplayResult {
            DUDisplayResult(originals: [fuel,distance], unit: .known(target), pressureReference: nil, state: state)
        }
        guard let f=fuel.value, let d=distance.value else { return result(.unavailable(.missing)) }
        guard f.isFinite && d.isFinite else { return result(.unavailable(.nonfiniteInput)) }
        guard fuel.quantity == .volume, distance.quantity == .distance,
              case let .known(fu)=fuel.unit, fu.quantity == .volume,
              case let .known(du)=distance.unit, du.quantity == .distance, target.quantity == .economy else {
            return result(.unavailable(.quantityMismatch))
        }
        guard d > 0 else { return result(.unavailable(.nonpositiveDistance)) }
        guard f >= 0 else { return result(.unavailable(.negativeFuel)) }
        if target == .l100 { return result(checked(ratio([100,f,fu.factor], [d,du.factor]), expectedNonzero: f != 0)) }
        if f == 0 { return result(.unbounded) }
        return result(checked(ratio([target.economyConstant,d,du.factor], [100,f,fu.factor]), expectedNonzero: true))
    }
}
public struct DUUnitPreference {
    public let quantity: DUQuantity
    public let unit: DUUnit
    public init(_ quantity: DUQuantity, _ unit: DUUnit) { self.quantity=quantity; self.unit=unit }
}
public enum DUPreferenceError: Error { case invalidOrDuplicate }
public struct DUUnitPreferences {
    public let selections: [DUUnitPreference]
    public init(_ selections: [DUUnitPreference] = []) throws {
        var seen=Set<DUQuantity>()
        for selection in selections {
            guard selection.quantity == selection.unit.quantity, seen.insert(selection.quantity).inserted else {
                throw DUPreferenceError.invalidOrDuplicate
            }
        }
        self.selections=selections
    }
    public func display(_ source: DUMeasurement) -> DUDisplayResult {
        DisplayUnits.convert(source, to: selections.first { $0.quantity == source.quantity }?.unit)
    }
}
