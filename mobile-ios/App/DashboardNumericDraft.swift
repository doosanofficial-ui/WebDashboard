import Foundation

/// Basic editor numbers are validated together before replacing saved configuration.
struct DashboardNumericDraft {
    enum Field: String, Hashable {
        case decimals = "Decimals"
        case minimum = "Min"
        case maximum = "Max"
        case warning = "Warn"
        case critical = "Critical"
    }

    enum ValidationError: Error, Equatable {
        case invalidDecimals
        case invalidNumber(Field)
    }

    struct Values {
        let decimals: Int
        let minimum: Double?
        let maximum: Double?
        let warning: Double?
        let critical: Double?
    }

    let decimals: String
    let minimum: String
    let maximum: String
    let warning: String
    let critical: String

    func validated() -> Result<Values, ValidationError> {
        guard let places = Int(decimals.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...6).contains(places) else {
            return .failure(.invalidDecimals)
        }
        let fields: [(Field, String)] = [(.minimum, minimum), (.maximum, maximum),
                                        (.warning, warning), (.critical, critical)]
        var numbers: [Field: Double] = [:]
        for (field, text) in fields {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard let number = Double(value), number.isFinite else {
                return .failure(.invalidNumber(field))
            }
            numbers[field] = number
        }
        return .success(Values(decimals: places, minimum: numbers[.minimum], maximum: numbers[.maximum],
                               warning: numbers[.warning], critical: numbers[.critical]))
    }
}
