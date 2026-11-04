import Foundation
import XCTest
@testable import TelemetryCore

final class LocalFillUpHistoryTests: XCTestCase {
    private func r(_ i: Int, id: String? = nil, vehicle: String = "v", epoch: String = "e",
                   time: Double? = nil, odometer: Double? = nil,
                   distance: LocalFillUpRecord.DistanceUnit = .km, volume: Double? = 10,
                   unit: LocalFillUpRecord.VolumeUnit = .liters,
                   tank: LocalFillUpRecord.TankState = .full,
                   completeness: LocalFillUpRecord.Completeness = .complete) throws -> LocalFillUpRecord {
        try LocalFillUpRecord(id: id ?? String(i), vehicle: vehicle, epoch: epoch, time: time ?? Double(i),
                             odometer: odometer ?? Double(i) * 100, distanceUnit: distance, volume: volume,
                             volumeUnit: unit, tank: tank, completeness: completeness)
    }
    private func excluded(_ rows: [LocalFillUpRecord], _ reason: LocalFillUpHistory.Exclusion,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        let i = try XCTUnwrap(LocalFillUpHistory.summarize(rows).intervals.first, file: file, line: line)
        XCTAssertTrue(i.exclusions.contains(reason), file: file, line: line)
        XCTAssertNil(i.kilometers, file: file, line: line)
        XCTAssertNil(i.liters, file: file, line: line)
        XCTAssertNil(i.litersPer100Kilometers, file: file, line: line)
    }
    func testEmpty() throws {
        let x = try LocalFillUpHistory.summarize([])
        XCTAssertTrue(x.intervals.isEmpty); XCTAssertTrue(x.unanchoredRecordIDs.isEmpty)
    }
    func testFullPairExcludesStartingVolume() throws {
        let s = try LocalFillUpHistory.summarize([r(1, volume: nil), r(2)])
        let x = try XCTUnwrap(s.intervals.first)
        XCTAssertEqual(x.startID, "1"); XCTAssertEqual(x.endID, "2")
        XCTAssertEqual(x.includedVolumeRecordIDs, ["2"]); XCTAssertEqual(x.exclusions, [])
        XCTAssertEqual(x.kilometers, 100); XCTAssertEqual(x.liters, 10)
        XCTAssertEqual(x.litersPer100Kilometers, 10); XCTAssertTrue(s.unanchoredRecordIDs.isEmpty)
        XCTAssertFalse(x.uncertainty.isEmpty)
    }
    func testPartialsIncluded() throws {
        let x = try XCTUnwrap(LocalFillUpHistory.summarize([r(1, volume: 99), r(2, volume: 4, tank: .partial), r(3, volume: 16)]).intervals.first)
        XCTAssertEqual(x.kilometers, 200); XCTAssertEqual(x.liters, 20); XCTAssertEqual(x.litersPer100Kilometers, 10)
        XCTAssertEqual(x.includedVolumeRecordIDs, ["2", "3"])
    }
    func testUnanchored() throws {
        let x = try LocalFillUpHistory.summarize([r(1, tank: .partial), r(2), r(3, tank: .partial)])
        XCTAssertTrue(x.intervals.isEmpty); XCTAssertEqual(x.unanchoredRecordIDs, ["1", "2", "3"])
    }
    func testTwoIntervals() throws {
        let x = try LocalFillUpHistory.summarize([r(1), r(2), r(3)])
        XCTAssertEqual(x.intervals.map(\.includedVolumeRecordIDs), [["2"], ["3"]])
    }
    func testExactUnits() throws {
        let x = try XCTUnwrap(LocalFillUpHistory.summarize([r(1, odometer: 0, distance: .miles), r(2, odometer: 100, distance: .miles, volume: 1, unit: .usGallons)]).intervals.first)
        XCTAssertEqual(try XCTUnwrap(x.kilometers), 160.9344, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(x.liters), 3.785411784, accuracy: 1e-10)
        let y = try XCTUnwrap(LocalFillUpHistory.summarize([r(1), r(2, volume: 1, unit: .imperialGallons)]).intervals.first)
        XCTAssertEqual(try XCTUnwrap(y.liters), 4.54609, accuracy: 1e-10)
    }
    func testMixedTypedUnits() throws {
        let x = try XCTUnwrap(LocalFillUpHistory.summarize([r(1, odometer: 1, distance: .miles), r(2, odometer: 101.609344)]).intervals.first)
        XCTAssertEqual(try XCTUnwrap(x.kilometers), 100, accuracy: 1e-10)
    }
    func testMissingHistory() throws { try excluded([r(1), r(2, completeness: .missing)], .incompleteHistory) }
    func testUncertainHistory() throws { try excluded([r(1), r(2, completeness: .uncertain)], .incompleteHistory) }
    func testUnknownTank() throws { try excluded([r(1), r(2, tank: .unknown), r(3)], .unknownTankState) }
    func testMissingVolume() throws { try excluded([r(1), r(2, volume: nil)], .missingVolume) }
    func testReset() throws { try excluded([r(1), r(2, odometer: 1)], .odometerDiscontinuity) }
    func testEpochChange() throws { try excluded([r(1), r(2, epoch: "other")], .odometerDiscontinuity) }
    func testIntermediateReset() throws { try excluded([r(1), r(2, odometer: 10, tank: .partial), r(3)], .odometerDiscontinuity) }
    func testZeroDistance() throws { try excluded([r(1), r(2, odometer: 100)], .nonPositiveDistance) }
    func testRecoversAfterBadInterval() throws {
        let x = try LocalFillUpHistory.summarize([r(1), r(2, completeness: .missing), r(3)])
        XCTAssertNil(x.intervals[0].litersPer100Kilometers); XCTAssertEqual(x.intervals[1].litersPer100Kilometers, 10)
    }
    func testDuplicateID() throws { XCTAssertThrowsError(try LocalFillUpHistory.summarize([r(1), r(2, id: "1")])) }
    func testDuplicateEventTime() throws { XCTAssertThrowsError(try LocalFillUpHistory.summarize([r(1), r(2, time: 1)])) }
    func testChronologyNotSortedSilently() throws { XCTAssertThrowsError(try LocalFillUpHistory.summarize([r(2), r(1)])) }
    func testMixedVehicle() throws { XCTAssertThrowsError(try LocalFillUpHistory.summarize([r(1), r(2, vehicle: "other")])) }
    func testInvalidNumbers() throws {
        for v in [0.0, -1, Double.nan, .infinity] { XCTAssertThrowsError(try r(1, volume: v)) }
        for v in [-1.0, Double.nan, .infinity] { XCTAssertThrowsError(try r(1, odometer: v)) }
        XCTAssertThrowsError(try r(1, time: .infinity))
    }
    func testInvalidIdentities() throws {
        XCTAssertThrowsError(try r(1, id: "")); XCTAssertThrowsError(try r(1, vehicle: " "))
        XCTAssertThrowsError(try r(1, epoch: ""))
    }
    func testOverflow() throws { try excluded([r(1, odometer: 0), r(2, odometer: 1, volume: 1e308, unit: .imperialGallons)], .numericRange) }
    func testEconomyUnderflow() throws { try excluded([r(1, odometer: 0), r(2, odometer: 1e308, volume: 1e-300)], .numericRange) }
    func testCalibrationIsGated() {
        XCTAssertFalse(LocalFillUpCalibrationGate.proposalAvailable)
        XCTAssertEqual(LocalFillUpCalibrationGate.requiredAdapterProof.count, 5)
        XCTAssertTrue(LocalFillUpCalibrationGate.requiredAdapterProof.contains(.completeAdmittedMeasuredFuelCoverageBetweenAnchors))
    }
    func testNoMutation() throws {
        let rows = try [r(1), r(2)]; let before = rows
        _ = try LocalFillUpHistory.summarize(rows); XCTAssertEqual(rows, before)
    }
    func testCodableValidationAndExplicitNull() throws {
        let row = try r(1, volume: nil)
        let data = try JSONEncoder().encode(row)
        XCTAssertEqual(try JSONDecoder().decode(LocalFillUpRecord.self, from: data), row)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(raw["volume"] is NSNull)
        for (key, value) in [("volumeUnit", "gallons"), ("tank", "assumed"), ("completeness", "yes"), ("distanceUnit", "meters"), ("id", "")] {
            var invalid = raw; invalid[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(LocalFillUpRecord.self, from: JSONSerialization.data(withJSONObject: invalid)))
        }
        var missing = raw; missing.removeValue(forKey: "volume")
        XCTAssertThrowsError(try JSONDecoder().decode(LocalFillUpRecord.self, from: JSONSerialization.data(withJSONObject: missing)))
        var negative = raw; negative["odometer"] = -1
        XCTAssertThrowsError(try JSONDecoder().decode(LocalFillUpRecord.self, from: JSONSerialization.data(withJSONObject: negative)))
    }
}
