import Foundation
import TelemetryCore

/// Ephemeral user assertions only. Intentionally cannot construct calibration evidence.
struct ManualFillUpDraft {
    var vehicle = ""
    var epoch = ""
    var fillDate = Date()
    var dateConfirmed = false
    var odometer = ""
    var volume = ""
    var distanceUnit: LocalFillUpRecord.DistanceUnit = .km
    var volumeUnit: LocalFillUpRecord.VolumeUnit = .liters
    var tank: LocalFillUpRecord.TankState = .unknown
    var completeness: LocalFillUpRecord.Completeness = .uncertain

    /// Decimal point grammar is explicit: no grouping, sign, exponent, NaN or infinity.
    static func decimal(_ text: String) -> Double? {
        guard !text.isEmpty, text.count <= 24,
              text.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let value = Double(text), value.isFinite else { return nil }
        return value
    }

    func reviewRecord(id: String) throws -> LocalFillUpRecord {
        guard dateConfirmed, fillDate.timeIntervalSince1970 >= 0,
              Self.isIdentity(vehicle), Self.isIdentity(epoch),
              let distance = Self.decimal(odometer),
              volume.isEmpty || Self.decimal(volume).map({ $0 > 0 }) == true else {
            throw LocalFillUpRecord.ValidationError.invalidNumber
        }
        return try LocalFillUpRecord(id: id, vehicle: vehicle, epoch: epoch,
            time: fillDate.timeIntervalSince1970, odometer: distance,
            distanceUnit: distanceUnit, volume: volume.isEmpty ? nil : Self.decimal(volume),
            volumeUnit: volumeUnit, tank: tank, completeness: completeness)
    }

    static func isIdentity(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 80 &&
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) &&
            !CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0) }
    }
}

/// Receiving this event authorizes local review only, not saving, exporting or calibration.
enum ManualFillUpReviewEvent {
    case reviewDraft(LocalFillUpRecord)
    case cancelled
}
