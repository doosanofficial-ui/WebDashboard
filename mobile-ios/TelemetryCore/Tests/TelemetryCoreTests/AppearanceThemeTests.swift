import Foundation
import XCTest
@testable import TelemetryCore

final class AppearanceThemeTests: XCTestCase {
    func testBoundsAndDecodeCannotBypassValidation() throws {
        for value in [-0.1, 1.1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try AppearanceColor(r: value, g: 0, b: 0))
            XCTAssertThrowsError(try AppearanceColor(r: 0, g: 0, b: 0, a: value))
        }
        XCTAssertEqual(try AppearanceColor(r: 0, g: 1, b: 0, a: 0).a, 0)
        XCTAssertThrowsError(try JSONDecoder().decode(AppearanceColor.self,
            from: Data(#"{"r":2,"g":0,"b":0,"a":1}"#.utf8)))
    }
    func testReferenceContrast() throws {
        let black = try AppearanceColor(r: 0, g: 0, b: 0)
        XCTAssertEqual(try black.contrast(with: AppearanceColor(r: 1, g: 1, b: 1)), 21, accuracy: 1e-12)
        let low = try AppearanceColor(r: 0.04045, g: 0, b: 0)
        XCTAssertEqual(try low.contrast(with: black), 1 + 0.2126 * (0.04045 / 12.92) / 0.05, accuracy: 1e-12)
        XCTAssertThrowsError(try black.contrast(with: AppearanceColor(r: 1, g: 1, b: 1, a: 0.5)))
    }
    func testCatalogEveryForegroundOnBothBackgrounds() throws {
        XCTAssertEqual(AppearanceThemeID.allCases.count, 4)
        for id in AppearanceThemeID.allCases {
            let palette = AppearancePalette.builtin(id)
            for f in AppearanceToken.foregrounds {
                for b in AppearanceToken.backgrounds {
                    XCTAssertGreaterThanOrEqual(try XCTUnwrap(palette.tokens[f]).contrast(with: XCTUnwrap(palette.tokens[b])), 4.5)
                }
            }
        }
    }
    func testNoContrastRounding() throws {
        var tokens = AppearancePalette.builtin(.paperLight).tokens
        let white = try AppearanceColor(r: 1, g: 1, b: 1)
        let linear = 1.05 / 4.4999 - 0.05
        let gray = 1.055 * pow(linear, 1 / 2.4) - 0.055
        tokens[.background] = white; tokens[.surface] = white
        tokens[.text] = try AppearanceColor(r: gray, g: gray, b: gray)
        XCTAssertThrowsError(try AppearancePalette(tokens: tokens))
    }
    func testOpaqueCompleteTokensRequired() throws {
        var tokens = AppearancePalette.builtin(.slateDark).tokens
        tokens[.accent] = try AppearanceColor(r: 1, g: 1, b: 1, a: 0.5)
        XCTAssertThrowsError(try AppearancePalette(tokens: tokens))
        tokens = AppearancePalette.builtin(.slateDark).tokens
        tokens.removeValue(forKey: .text)
        XCTAssertThrowsError(try AppearancePalette(tokens: tokens))
    }
    func testOverridesAtomicIsolatedAndResettable() throws {
        let white = try AppearanceColor(r: 1, g: 1, b: 1)
        let original = AppearanceSettings.defaults
        let edited = try original.settingOverrides(["accent": white], for: .slateDark)
        XCTAssertEqual(try edited.palette().tokens[.accent], white)
        XCTAssertEqual(try edited.palette(for: .paperLight), AppearancePalette.builtin(.paperLight))
        XCTAssertThrowsError(try edited.settingOverrides(["text": AppearanceColor(r: 0, g: 0, b: 0)], for: .slateDark))
        XCTAssertEqual(try edited.palette().tokens[.accent], white)
        XCTAssertEqual(try edited.resetting(.slateDark), original)
        XCTAssertEqual(edited.resettingAll(), original)
        XCTAssertEqual(try edited.selecting(.blueLight).selected, .blueLight)
    }
    func testRoundtrip() throws {
        let value = try AppearanceSettings(selected: .blueLight).settingOverrides(
            ["accent": AppearanceColor(r: 1, g: 1, b: 1)], for: .slateDark)
        XCTAssertEqual(try AppearanceSettings.decode(value.encoded()), value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "selected", "overrides"])
    }
    func testStrictSchemaAndPrivacy() throws {
        let invalid = [
            #"{"schemaVersion":2,"selected":"slateDark","overrides":{}}"#,
            #"{"schemaVersion":true,"selected":"slateDark","overrides":{}}"#,
            #"{"schemaVersion":1,"selected":"https://tracker","overrides":{}}"#,
            #"{"schemaVersion":1,"selected":"slateDark","overrides":{},"url":"secret"}"#,
            #"{"schemaVersion":1,"selected":"slateDark","overrides":{"VIN":{}}}"#,
            #"{"schemaVersion":1,"selected":"slateDark","overrides":{"slateDark":{"accent":{"r":1,"g":1,"b":1,"a":1,"url":"secret"}}}}"#,
            #"{"schemaVersion":1,"selected":"slateDark","overrides":{"slateDark":{"text":{"r":0,"g":0,"b":0,"a":1}}}}"#
        ]
        for raw in invalid { XCTAssertThrowsError(try AppearanceSettings.decode(Data(raw.utf8))) }
    }
    func testFallbackAndByteLimit() throws {
        for raw in ["oops", "null", "{}", "[", String(repeating: " ", count: 16_385)] {
            let result = AppearanceSettings.restore(Data(raw.utf8))
            XCTAssertEqual(result.settings, .defaults); XCTAssertEqual(result.status, .invalidData)
        }
        var oversizedValid = try AppearanceSettings.defaults.encoded()
        oversizedValid.append(Data(repeating: 32, count: 16_384))
        XCTAssertThrowsError(try AppearanceSettings.decode(oversizedValid))
        XCTAssertEqual(AppearanceSettings.restore(nil).status, .missingData)
        XCTAssertEqual(AppearanceSettings.restore(try AppearanceSettings.defaults.encoded()).status, .loaded)
    }
    func testUnknownAndTransparentOverridesRejected() throws {
        let white = try AppearanceColor(r: 1, g: 1, b: 1)
        XCTAssertThrowsError(try AppearanceSettings.defaults.settingOverrides(["nope": white], for: .slateDark))
        XCTAssertThrowsError(try AppearanceSettings.defaults.settingOverrides(
            ["accent": AppearanceColor(r: 1, g: 1, b: 1, a: 0.1)], for: .slateDark))
    }
}
