// XCTest proposal UNRUN. Add Core/DisplayUnits.swift to a future native test target.
import XCTest
@testable import TelemetryCore

final class DisplayUnitsTests: XCTestCase {
    func source(_ x: Double?, _ q: DUQuantity, _ unit: DUUnit, _ reference: String? = nil) -> DUMeasurement {
        DUMeasurement(x,q,.known(unit),provenance: ["pid:0D","ecu:7E8","capture:local"],pressureReference: reference,label: "Raw PID label")
    }
    func value(_ source: DUMeasurement, _ target: DUUnit, _ expected: Double, file: StaticString = #filePath, line: UInt = #line) {
        let result=DisplayUnits.convert(source,to: target)
        guard case let .available(actual)=result.state else { return XCTFail("Not available: \(result.state)",file:file,line:line) }
        XCTAssertEqual(actual,expected,accuracy:max(1e-13,abs(expected)*2e-14),file:file,line:line)
        XCTAssertEqual(result.originals,[source],file:file,line:line)
        XCTAssertEqual(result.pressureReference,source.pressureReference,file:file,line:line)
        XCTAssertEqual(result.unit,.known(target),file:file,line:line)
    }
    func testOrdinaryConstantsOffsetsSignedValues() {
        let cases: [(Double,DUQuantity,DUUnit,DUUnit,Double)] = [
            (160.9344,.speed,.kmh,.mph,100),(-100,.speed,.mph,.kmh,-160.9344),
            (1,.distance,.mi,.km,1.609344),(1,.volume,.usGallon,.litre,3.785411784),
            (1,.volume,.imperialGallon,.litre,4.54609),(-40,.temperature,.c,.f,-40),
            (212,.temperature,.f,.c,100),(0,.temperature,.c,.f,32),
            (100,.pressure,.kPa,.bar,1),(1,.pressure,.psi,.kPa,6.894757293168361),
            (-100,.pressure,.kPa,.psi,-14.5037737730209),(1000,.energy,.wh,.kwh,1),
            (-1,.energy,.kwh,.wh,-1000),(37.5,.percentage,.percent,.percent,37.5)]
        for (x,q,a,b,w) in cases { value(source(x,q,a),b,w) }
    }
    func testPressureReferenceRetention() {
        let references: [String?] = [nil,"gauge","absolute","differential","unknown-vendor"]
        for ref in references {
            value(source(-10,.pressure,.kPa,ref),.bar,-0.1)
        }
    }
    func testCustomAndMismatchedUnits() {
        let custom=DUMeasurement(100,.speed,.custom("bananas"),label:"km/h")
        XCTAssertEqual(DisplayUnits.convert(custom,to:.mph).state,.unavailable(.unsupportedUnit))
        XCTAssertEqual(DisplayUnits.convert(custom).state,.available(100))
        XCTAssertEqual(DisplayUnits.convert(source(100,.pressure,.kmh),to:.mph).state,.unavailable(.quantityMismatch))
        XCTAssertEqual(DisplayUnits.convert(source(100,.speed,.kmh),to:.litre).state,.unavailable(.quantityMismatch))
    }
    func testMissingNonfiniteRangeAndIdentity() {
        for x in [Double.nan,Double.infinity,-Double.infinity] {
            XCTAssertEqual(DisplayUnits.convert(source(x,.speed,.kmh)).state,.unavailable(.nonfiniteInput))
        }
        XCTAssertEqual(DisplayUnits.convert(source(nil,.speed,.kmh)).state,.unavailable(.missing))
        XCTAssertEqual(DisplayUnits.convert(source(.greatestFiniteMagnitude,.energy,.kwh),to:.wh).state,.unavailable(.overflow))
        XCTAssertEqual(DisplayUnits.convert(source(.leastNonzeroMagnitude,.energy,.wh),to:.kwh).state,.unavailable(.underflow))
        value(source(.greatestFiniteMagnitude,.volume,.imperialGallon),.imperialGallon,.greatestFiniteMagnitude)
        guard case let .available(zero)=DisplayUnits.convert(source(-0.0,.speed,.kmh)).state else { return XCTFail() }
        XCTAssertEqual(zero.sign,.minus)
    }
    func testNegativeZeroSurvivesScaledConversion() {
        for (quantity, from, to) in [(DUQuantity.speed, DUUnit.kmh, DUUnit.mph),
                                     (.pressure, .kPa, .bar), (.energy, .wh, .kwh)] {
            guard case let .available(value) = DisplayUnits.convert(source(-0.0, quantity, from), to: to).state else {
                XCTFail("Negative zero should remain available")
                continue
            }
            XCTAssertEqual(value, 0)
            XCTAssertEqual(value.sign, .minus)
        }
    }
    func testRoundtripBounds() {
        let cases: [(DUQuantity,DUUnit,DUUnit)] = [(.speed,.kmh,.mph),(.distance,.km,.mi),(.pressure,.kPa,.psi),
            (.pressure,.kPa,.bar),(.volume,.litre,.usGallon),(.volume,.litre,.imperialGallon),(.energy,.wh,.kwh),(.temperature,.c,.f)]
        for (q,a,b) in cases {
            for x in [-1e9,-40,-0.125,0,0.125,100,1e9] {
                guard case let .available(y)=DisplayUnits.convert(source(x,q,a),to:b).state,
                      case let .available(z)=DisplayUnits.convert(source(y,q,b),to:a).state else { XCTFail(); continue }
                XCTAssertEqual(z,x,accuracy:max(3e-14,abs(x)*3e-15))
            }
        }
    }
    func testEconomyUnboundedDistinctFromMissing() {
        for target in [DUUnit.mpgUS,DUUnit.mpgImperial] {
            XCTAssertEqual(DisplayUnits.convert(source(0,.economy,.l100),to:target).state,.unbounded)
            XCTAssertEqual(DisplayUnits.convert(source(nil,.economy,.l100),to:target).state,.unavailable(.missing))
            XCTAssertEqual(DisplayUnits.convert(source(0,.economy,target),to:.l100).state,.unbounded)
        }
        value(source(10,.economy,.l100),.mpgUS,23.5214583333333)
        value(source(10,.economy,.l100),.mpgImperial,28.2480936331822)
        value(source(23.5214583333333,.economy,.mpgUS),.l100,10)
        value(source(23.5214583333333,.economy,.mpgUS),.mpgImperial,28.2480936331822)
        for unit in [DUUnit.l100,DUUnit.mpgUS,DUUnit.mpgImperial] {
            XCTAssertEqual(DisplayUnits.convert(source(-1,.economy,unit)).state,.unavailable(.negativeEconomy))
        }
    }
    func testEconomyTotalsValidationAndExtremeRatios() {
        for d in [0.0,-1] {
            XCTAssertEqual(DisplayUnits.economy(fuel:source(2,.volume,.litre),distance:source(d,.distance,.km),to:.mpgUS).state,.unavailable(.nonpositiveDistance))
        }
        XCTAssertEqual(DisplayUnits.economy(fuel:source(0,.volume,.litre),distance:source(100,.distance,.km),to:.mpgUS).state,.unbounded)
        XCTAssertEqual(DisplayUnits.economy(fuel:source(-1,.volume,.litre),distance:source(100,.distance,.km),to:.l100).state,.unavailable(.negativeFuel))
        for x in [Double.greatestFiniteMagnitude,Double.leastNonzeroMagnitude] {
            XCTAssertEqual(DisplayUnits.economy(fuel:source(x,.volume,.litre),distance:source(x,.distance,.km),to:.l100).state,.available(100))
        }
    }
    func testPreferencesPreserveDefaultAndRejectDuplicates() throws {
        let original=source(100,.speed,.kmh)
        let defaults=try DUUnitPreferences()
        XCTAssertEqual(defaults.display(original).state,.available(100))
        let explicit=try DUUnitPreferences([DUUnitPreference(.speed,.mph)])
        guard case let .available(actual)=explicit.display(original).state else { return XCTFail() }
        XCTAssertEqual(actual,62.1371192237334,accuracy:1e-12)
        XCTAssertEqual(defaults.display(original).state,.available(100))
        XCTAssertThrowsError(try DUUnitPreferences([DUUnitPreference(.speed,.litre)]))
        XCTAssertThrowsError(try DUUnitPreferences([DUUnitPreference(.speed,.mph),DUUnitPreference(.speed,.kmh)]))
    }
    func testSourceMetadataValueSemantics() {
        var provenance=["pid:0D"]
        let source=DUMeasurement(100,.speed,.known(.kmh),provenance:provenance)
        provenance.append("rewritten")
        XCTAssertEqual(source.provenance,["pid:0D"])
    }
}
