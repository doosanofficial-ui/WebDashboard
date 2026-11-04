import TelemetryCore

/// English presentation keys for the existing AppLocalization.text mechanism.
/// Raw Core identifiers remain untouched in all review values.
enum LocalSettingsLabels {
    static let vehicle: [String: String] = [
        "unknown": "Unknown", "mixed": "Mixed", "gasoline": "Gasoline", "diesel": "Diesel",
        "electric": "Electric", "hydrogen": "Hydrogen", "other": "Other",
        "ice": "Internal combustion", "hev": "Hybrid (HEV)", "phev": "Plug-in hybrid (PHEV)",
        "bev": "Battery electric (BEV)", "fuelCell": "Fuel cell",
        "manual": "Manual", "automatic": "Automatic", "cvt": "CVT", "ecvt": "eCVT",
        "dualClutch": "Dual clutch", "singleSpeed": "Single speed",
        "present": "Present", "absent": "Absent", "notApplicable": "Not applicable"
    ]
    static func quantity(_ value: DUQuantity) -> String {
        switch value {
        case .speed: return "Speed"
        case .distance: return "Distance"
        case .temperature: return "Temperature"
        case .pressure: return "Pressure"
        case .volume: return "Volume"
        case .energy: return "Energy"
        case .percentage: return "Percentage"
        case .economy: return "Fuel economy"
        }
    }
    static func units(_ value: DUQuantity) -> [DUUnit] {
        switch value {
        case .speed: return [.kmh, .mph]
        case .distance: return [.km, .mi]
        case .temperature: return [.c, .f]
        case .pressure: return [.kPa, .bar, .psi]
        case .volume: return [.litre, .usGallon, .imperialGallon]
        case .energy: return [.wh, .kwh]
        case .percentage: return [.percent]
        case .economy: return [.l100, .mpgUS, .mpgImperial]
        }
    }
    static func unit(_ value: DUUnit) -> String {
        switch value {
        case .usGallon: return "US gallons (US gal)"
        case .imperialGallon: return "Imperial gallons (imp gal)"
        case .mpgUS: return "Miles per US gallon (mpg US)"
        case .mpgImperial: return "Miles per imperial gallon (mpg imp)"
        case .c: return "Celsius (°C)"
        case .f: return "Fahrenheit (°F)"
        default: return value.rawValue
        }
    }
    static func theme(_ value: AppearanceThemeID) -> String {
        switch value {
        case .slateDark: return "Slate dark"
        case .amberDark: return "Amber dark"
        case .paperLight: return "Paper light"
        case .blueLight: return "Blue light"
        }
    }
    static func token(_ value: AppearanceToken) -> String {
        switch value {
        case .background: return "Background"
        case .surface: return "Surface"
        case .text: return "Primary text"
        case .secondary: return "Secondary text"
        case .accent: return "Accent"
        case .warning: return "Warning color sample"
        case .critical: return "Critical color sample"
        }
    }
}
