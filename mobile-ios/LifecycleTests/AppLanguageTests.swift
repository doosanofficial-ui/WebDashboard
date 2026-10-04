import Foundation
import XCTest
@testable import TelemetryLifecycleHost

@MainActor
final class AppLanguageTests: XCTestCase {
    func testSystemDefaultAndUnsupportedLanguageFallback() {
        XCTAssertEqual(AppLanguage.resolve(saved: nil, preferredLanguages: ["ko-KR", "en-US"]), .korean)
        XCTAssertEqual(AppLanguage.resolve(saved: nil, preferredLanguages: ["en-US", "ko-KR"]), .english)
        XCTAssertEqual(AppLanguage.resolve(saved: nil, preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.resolve(saved: "invalid", preferredLanguages: ["ko"]), .korean)
        XCTAssertEqual(AppLanguage.resolve(saved: "en", preferredLanguages: ["ko"]), .english)
    }
    func testSelectionPersistsAcrossNewStoreWithoutChangingModelState() throws {
        let suite = "language-fixture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TelemetryModel.shared
        let original = (model.runMode, model.localRecordingEnabled, model.collecting, model.rawCANText)
        let store = AppLanguageStore(defaults: defaults, preferredLanguages: ["en"])
        store.select(.korean)
        XCTAssertEqual(AppLanguageStore(defaults: defaults, preferredLanguages: ["en"]).language, .korean)
        store.select(.english)
        XCTAssertEqual(AppLanguageStore(defaults: defaults, preferredLanguages: ["ko"]).language, .english)
        XCTAssertEqual(model.runMode, original.0)
        XCTAssertEqual(model.localRecordingEnabled, original.1)
        XCTAssertEqual(model.collecting, original.2)
        XCTAssertEqual(model.rawCANText, original.3)
    }
    func testPresentationTranslatesStatusParametersWithoutChangingOriginal() {
        let original = "Recorded time: 17 original rows; acquisition and recording off"
        XCTAssertEqual(AppLocalization.text(original, language: .english), original)
        XCTAssertEqual(AppLocalization.text(original, language: .korean), "기록 시간: 원본 17행 · 수집 및 기록 꺼짐")
        XCTAssertEqual(AppLocalization.text("VALID RECORDED", language: .korean), "기록 당시 유효")
        XCTAssertEqual(AppLocalization.text("FRESHNESS UNKNOWN", language: .korean), "신선도 미상")
        XCTAssertEqual(original, "Recorded time: 17 original rows; acquisition and recording off")
        XCTAssertEqual(AppLocalization.text("SANTAFEHYB_HVBAT_SOC", language: .korean), "SANTAFEHYB_HVBAT_SOC")
    }
    func testLanguageCannotChangeMissingZeroFreshnessOrDiagnosticSemantics() {
        let cases:[(Double?,Bool,String)] = [(nil,false,"NO SAMPLE"),(0,true,"VALID"),(53,false,"STALE"),(.nan,true,"INVALID")]
        for (value,fresh,expected) in cases {
            let semantic=TelemetryDisplayState.signalLabel(value,liveFresh:fresh)
            XCTAssertEqual(semantic,expected)
            XCTAssertNotEqual(AppLocalization.text(semantic,language:.korean),semantic)
            XCTAssertEqual(TelemetryDisplayState.signalLabel(value,liveFresh:fresh),expected)
        }
        XCTAssertEqual(AppLocalization.text("Diagnostic response; passive CAN bits unavailable",language:.korean),"진단 응답 · 수동 CAN 비트 표시 불가")
        XCTAssertEqual(AppLocalization.text("Diagnostic SOC: unsupported command",language:.korean),"진단 SOC: 지원하지 않는 명령")
        XCTAssertFalse(TelemetryDisplayState.matchesStaleFilter(0,liveFresh:false,isReplay:true,replayFreshness:.unknown))
        XCTAssertTrue(TelemetryDisplayState.matchesStaleFilter(0,liveFresh:true,isReplay:true,replayFreshness:.stale))
    }
    func testTemplatePreservesUserNamesAndInsertedPlaceholders() {
        XCTAssertEqual(AppLocalization.text("Profile loaded: Live", language: .korean), "프로필 불러옴: Live")
        XCTAssertEqual(AppLocalization.text("Profile saved: {1}, 3 signals", language: .korean), "프로필 저장됨: {1}, 신호 3개")
        XCTAssertEqual(AppLocalization.text("Profile loaded: Page 7", language: .korean), "프로필 불러옴: Page 7")
        XCTAssertEqual(AppLocalization.text("LAST 60 SECONDS · Live", language: .korean), "최근 60초 · Live")
    }

}
