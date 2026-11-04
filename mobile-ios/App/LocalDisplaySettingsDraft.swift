import Foundation
import TelemetryCore

/// Presentation input snapshot. The host owns identity, revisions and all eventual writes.
/// Supply a new view identity for a new editing session; never reseed an open draft.
struct LocalDisplaySettingsSeed {
    let scope: String
    let vehicle: VehicleDisplayMetadataDocument
    let units: DUUnitPreferences
    let appearance: AppearanceSettings
    let appearanceMode: AppearanceSchedulePolicy.Mode
}

/// Review output only. This type is not permission to persist or change acquisition.
struct LocalDisplaySettingsReview {
    let base: LocalDisplaySettingsSeed
    let vehiclePlan: VehicleDisplayMetadataPlan
    let units: DUUnitPreferences
    let appearance: AppearanceSettings
    // Schedule/mappings are deliberately not edited by this small component.
    let appearanceMode: AppearanceSchedulePolicy.Mode
}

enum LocalDisplaySettingsDraftError: Error { case invalidRPM }

struct LocalDisplaySettingsDraft {
    let seed: LocalDisplaySettingsSeed
    var fuel: String
    var powertrain: String
    var gearbox: String
    var turbo: String
    var rpmText: String
    // Absence means retain the source unit, including custom units.
    var units: [DUQuantity: DUUnit]
    var appearance: AppearanceSettings

    init(seed: LocalDisplaySettingsSeed) {
        self.seed = seed
        fuel = seed.vehicle.metadata.fuel
        powertrain = seed.vehicle.metadata.powertrain
        gearbox = seed.vehicle.metadata.gearbox
        turbo = seed.vehicle.metadata.turbo
        rpmText = seed.vehicle.metadata.redlineLabelRPM.map { String($0) } ?? ""
        units = Dictionary(uniqueKeysWithValues: seed.units.selections.map { ($0.quantity, $0.unit) })
        appearance = seed.appearance
    }

    subscript(unit quantity: DUQuantity) -> String {
        get { units[quantity]?.rawValue ?? "source" }
        set {
            if newValue == "source" { units.removeValue(forKey: quantity) }
            else if let unit = DUUnit(rawValue: newValue), unit.quantity == quantity {
                units[quantity] = unit
            }
        }
    }

    mutating func resetVehicleDraft() {
        fuel = "unknown"; powertrain = "unknown"; gearbox = "unknown"; turbo = "unknown"
        rpmText = ""
    }

    func review() throws -> LocalDisplaySettingsReview {
        let text = rpmText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rpm: Int?
        if text.isEmpty { rpm = nil }
        else {
            // Deliberately ASCII integer input; reject fractions, signs, exponent and overflow.
            guard text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(text), (1...100000).contains(parsed) else {
                throw LocalDisplaySettingsDraftError.invalidRPM
            }
            rpm = parsed
        }
        let metadata = try VehicleDisplayMetadata(fuel: fuel, powertrain: powertrain,
            gearbox: gearbox, turbo: turbo, redlineLabelRPM: rpm)
        let selections = units.sorted { $0.key.rawValue < $1.key.rawValue }.map {
            DUUnitPreference($0.key, $0.value)
        }
        let preferences = try DUUnitPreferences(selections)
        // Revalidate all retained overrides, not only the selected palette.
        let settings = try AppearanceSettings(selected: appearance.selected, overrides: appearance.overrides)
        return LocalDisplaySettingsReview(base: seed,
            vehiclePlan: try seed.vehicle.editPlan(scope: seed.scope, metadata: metadata),
            units: preferences, appearance: settings, appearanceMode: seed.appearanceMode)
    }
}
