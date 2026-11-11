"""Run real editor/model methods and Core profile against a private JSON sink.

The shell omits SwiftUI/platform services. It does not simulate rendering or claim
device persistence; the actual mounted flow is independently tested on Simulator.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


def method(source, name):
    start = source.index('    ' + ('private ' if '    private func ' + name + '(' in source else '') + 'func ' + name + '(')
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end].replace('private func ', 'func ', 1)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Requires installed Mac Swift compiler')
class DashboardNumericDraftTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        view = (root / 'mobile-ios/App/DashboardEditorView.swift').read_text()
        model = (root / 'mobile-ios/App/TelemetryModel.swift').read_text()
        helper = root / 'mobile-ios/App/DashboardNumericDraft.swift'
        error_type = 'DashboardNumericDraft.ValidationError' if helper.exists() else 'String'
        message_method = method(view, 'numericValidationMessage') if helper.exists() else ''
        message_probe = ("AppLocalization.language = \"en\"; let english = h.draftValidationError.map { h.numericValidationMessage($0) } ?? \"\"\n"
                         "AppLocalization.language = \"ko\"; let korean = h.draftValidationError.map { h.numericValidationMessage($0) } ?? \"\"\n") if helper.exists() else 'let english = \"\"; let korean = \"\"\n'
        swift = r'''import Foundation
enum AppLocalization {
    static var language = "en"
    static func text(_ key: String) -> String {
        let bundle = Bundle(path: CommandLine.arguments[2] + "/" + language + ".lproj")!
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
// Real model mutation method below; only platform lifecycle and storage sink differ.
final class RecordingModel {
    var dashboardProfile: DashboardProfile?
    var conditionRuntimes = ["widget": DashboardConditionRuntime()]
    var conditionStates = ["widget": true]
    var dashboardSaveError: String? = "prior disk failure"
    let file: URL
    var persistCalls = 0
    var encodingFailures = 0
    init(_ file: URL) throws {
        self.file = file
        let configuration = DashboardWidgetConfiguration(label: "Stored", unit: "%", decimals: 1,
            minimum: 10, maximum: 90, warningThreshold: 80, criticalThreshold: 85)
        let widget = DashboardWidgetDefinition(id: "widget", type: .numericGauge, signalID: "SOC",
            rect: DashboardRect(x: 0, y: 0, width: 2, height: 2), zIndex: 0, configuration: configuration)
        dashboardProfile = try DashboardProfile(id: "private-fixture", name: "Synthetic",
            pages: [DashboardPage(id: "page", name: "Page", orientation: .portrait, widgets: [widget])])
        try encoded().write(to: file, options: .atomic)
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(dashboardProfile)
    }
    func persistDashboardProfile() {
        persistCalls += 1
        do { try encoded().write(to: file, options: .atomic) }
        catch { encodingFailures += 1 }
    }
''' + method(model, 'updateDashboardWidgetBinding') + r'''
}
final class EditorHarness {
    let model: RecordingModel
    var draftLabel = "Edited"
    var draftUnit = "%"
    var draftDecimals = "1"
    var draftMinimum = "10"
    var draftMaximum = "90"
    var draftWarning = "80"
    var draftCritical = "85"
    var draftSignalID = "SOC"
    var draftConditionEnabled = false
    var draftConditionOperator = DashboardConditionOperator.greaterThan
    var draftConditionThreshold = ""
    var draftConditionUpper = ""
    var draftConditionBit = ""
    var draftConditionHysteresis = "0"
    var draftConditionHold = "0"
    var draftConditionStaleActive = false
    var numericInputFocus: Int? = 1
    var draftValidationError: ''' + error_type + r'''?
    init(_ model: RecordingModel) { self.model = model }
''' + method(view, 'applyDraft') + '\n' + method(view, 'optionalDouble') + '\n' + message_method + r'''
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
func fixture(_ name: String) throws -> EditorHarness {
    EditorHarness(try RecordingModel(directory.appendingPathComponent(name + ".json")))
}
func observe(_ h: EditorHarness, beforeProfile: DashboardProfile?, beforeData: Data) throws -> [String: Any] {
''' + message_probe + r'''    let configuration = h.model.dashboardProfile!.pages[0].widgets[0].configuration
    var minimum: Any = NSNull()
    if let value = configuration.minimum { minimum = value.isFinite ? value as Any : "nonfinite" }
    return ["persistCalls": h.model.persistCalls, "encodingFailures": h.model.encodingFailures,
        "memoryUnchanged": h.model.dashboardProfile == beforeProfile,
        "jsonUnchanged": try Data(contentsOf: h.model.file) == beforeData,
        "runtimeCachePresent": h.model.conditionRuntimes["widget"] != nil,
        "conditionCachePresent": h.model.conditionStates["widget"] != nil,
        "minimum": minimum, "decimals": configuration.decimals,
        "errorMessageEN": english, "errorMessageKO": korean,
        "minLabelKO": AppLocalization.text("Min"),
        "hasError": h.draftValidationError != nil,
        "error": h.draftValidationError.map { String(describing: $0) } ?? "",
        "draftMinimum": h.draftMinimum, "draftDecimals": h.draftDecimals,
        "saveError": h.model.dashboardSaveError ?? ""]
}
var output: [String: Any] = [:]
for field in ["minimum", "maximum", "warning", "critical", "nan", "inf"] {
    let h = try fixture(field)
    switch field {
    case "minimum": h.draftMinimum = "oops"
    case "maximum": h.draftMaximum = "oops"
    case "warning": h.draftWarning = "oops"
    case "critical": h.draftCritical = "oops"
    case "nan": h.draftMinimum = "nan"
    default: h.draftMinimum = "inf"
    }
    let beforeProfile = h.model.dashboardProfile; let beforeData = try Data(contentsOf: h.model.file)
    h.applyDraft(pageID: "page", widgetID: "widget")
    output[field] = try observe(h, beforeProfile: beforeProfile, beforeData: beforeData)
}
for (i, text) in ["oops", "99", "-1", "2.5", ""].enumerated() {
    let h = try fixture("decimals-\(i)"); h.draftDecimals = text
    let beforeProfile = h.model.dashboardProfile; let beforeData = try Data(contentsOf: h.model.file)
    h.applyDraft(pageID: "page", widgetID: "widget")
    output["decimals-\(i)"] = try observe(h, beforeProfile: beforeProfile, beforeData: beforeData)
}
for text in ["0", "6"] {
    let h = try fixture("valid-\(text)"); h.draftDecimals = text; h.draftMinimum = " 12.5 "
    let beforeProfile = h.model.dashboardProfile; let beforeData = try Data(contentsOf: h.model.file)
    h.applyDraft(pageID: "page", widgetID: "widget")
    output["valid-\(text)"] = try observe(h, beforeProfile: beforeProfile, beforeData: beforeData)
}
let blank = try fixture("blank"); blank.draftMinimum = " \n "
let blankBefore = blank.model.dashboardProfile; let blankBytes = try Data(contentsOf: blank.model.file)
blank.applyDraft(pageID: "page", widgetID: "widget")
output["blank"] = try observe(blank, beforeProfile: blankBefore, beforeData: blankBytes)
let correction = try fixture("correction"); correction.draftMinimum = "oops"
correction.applyDraft(pageID: "page", widgetID: "widget")
let errorBeforeCorrection = correction.draftValidationError != nil
correction.draftMinimum = "12.5"
let correctionBefore = correction.model.dashboardProfile; let correctionBytes = try Data(contentsOf: correction.model.file)
correction.applyDraft(pageID: "page", widgetID: "widget")
var corrected = try observe(correction, beforeProfile: correctionBefore, beforeData: correctionBytes)
corrected["hadErrorBeforeCorrection"] = errorBeforeCorrection; output["corrected"] = corrected
print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
'''
        with tempfile.TemporaryDirectory(prefix='dashboard-numeric-draft-') as directory:
            temporary = Path(directory)
            main = temporary / 'main.swift'; main.write_text(swift)
            sources = [root / 'mobile-ios/TelemetryCore/Sources/TelemetryCore/DashboardModel.swift']
            if helper.exists(): sources.append(helper)
            command = ['swiftc', '-swift-version', '5', '-module-cache-path', str(temporary/'cache'),
                       *map(str, sources), str(main), '-o', str(temporary/'check')]
            build = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if build.returncode: raise AssertionError(build.stdout + build.stderr)
            run = subprocess.run([str(temporary/'check'), str(temporary), str(root/'mobile-ios/App/Resources')], capture_output=True, text=True, timeout=10)
            if run.returncode: raise AssertionError(run.stdout + run.stderr)
            cls.result = json.loads(run.stdout)

    def assert_preserved(self, row):
        self.assertEqual(row['persistCalls'], 0, 'Invalid input must not reach the real model mutation/persistence path')
        self.assertTrue(row['memoryUnchanged'])
        self.assertTrue(row['jsonUnchanged'])
        self.assertTrue(row['runtimeCachePresent'])
        self.assertTrue(row['conditionCachePresent'])
        self.assertTrue(row['hasError'], 'The user needs field-specific correction feedback')
        self.assertEqual(row['saveError'], 'prior disk failure', 'Input validation must not dismiss storage failures')

    def test_bad_optional_number_preserves_previous_settings_and_reports_field(self):
        self.assertEqual(self.result['valid-0']['persistCalls'], 1, 'The fixture must reach the real valid write path')
        for field in ['minimum', 'maximum', 'warning', 'critical']:
            with self.subTest(field=field): self.assert_preserved(self.result[field])
        self.assertEqual(self.result['minimum']['draftMinimum'], 'oops', 'Keep the draft available for correction')

    def test_nonfinite_values_cannot_poison_memory_before_json_encoding(self):
        for field in ['nan', 'inf']:
            with self.subTest(field=field): self.assert_preserved(self.result[field])

    def test_decimal_places_require_an_integer_in_the_existing_supported_range(self):
        for i in range(5):
            with self.subTest(case=i): self.assert_preserved(self.result[f'decimals-{i}'])

    def test_valid_boundaries_and_deliberate_blank_clear_keep_existing_semantics(self):
        for value in [0, 6]:
            row = self.result[f'valid-{value}']
            self.assertEqual(row['persistCalls'], 1)
            self.assertEqual(row['minimum'], 12.5)
            self.assertEqual(row['decimals'], value)
            self.assertFalse(row['hasError'])
        self.assertEqual(self.result['blank']['persistCalls'], 1)
        self.assertIsNone(self.result['blank']['minimum'])
        self.assertFalse(self.result['blank']['hasError'])

    def test_field_feedback_uses_the_actual_english_and_korean_string_tables(self):
        row = self.result['minimum']
        self.assertEqual(row['errorMessageEN'], 'Min must be a finite number or empty.')
        self.assertEqual(row['errorMessageKO'], row['minLabelKO'] + '에는 유한한 숫자를 입력하거나 비워 두세요.')
        self.assertEqual(self.result['decimals-0']['errorMessageKO'], '소수 자릿수는 0~6 사이의 정수로 입력하세요.')

    def test_correcting_the_same_draft_applies_once_and_clears_only_input_error(self):
        row = self.result['corrected']
        self.assertTrue(row['hadErrorBeforeCorrection'])
        self.assertEqual(row['persistCalls'], 1)
        self.assertEqual(row['minimum'], 12.5)
        self.assertFalse(row['hasError'])
        self.assertEqual(row['saveError'], 'prior disk failure')


if __name__ == '__main__': unittest.main()
