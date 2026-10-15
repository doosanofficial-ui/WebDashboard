import Foundation

// Compile only the proposed Help data declarations, with the real language-store
// prefix and memory-only preferences from offline_language_restoration.swift.
// This checks copy and guide identity, not SwiftUI layout or native execution.
@main struct HelpCopyChecks {
    @MainActor static func main() throws {
        var rows: [[String: Any]] = []
        var errors: [String] = []
        if HelpGuide.all.count != 6 { errors.append("six guides required") }
        for language in AppLanguage.allCases {
            AppLanguageStore.shared.select(language)
            for guide in HelpGuide.all {
                let note = guide.screenshotStateNote
                if (note != nil) != ["live", "setup"].contains(guide.id) {
                    errors.append("unexpected example state note: " + guide.id)
                }
                for (index, step) in guide.steps.enumerated() {
                    if step.number != index + 1 { errors.append("step ordering changed") }
                    if step.action.text.isEmpty || step.result.text.isEmpty || step.recovery.text.isEmpty {
                        errors.append("missing bilingual instruction")
                    }
                    rows.append(["imageName": "Help-" + guide.id + "-" + language.rawValue + "-" + String(step.number),
                                 "targetID": step.id, "note": note?.text ?? ""])
                }
            }
        }
        if rows.count != 28 { errors.append("twenty-eight targets required") }
        if rows.filter({ ($0["note"] as? String)?.isEmpty == false }).count != 10 {
            errors.append("only the setup/live example images receive context")
        }
        let result: [String: Any] = ["scope": "proposed-help-data-only", "targets": rows,
                                    "errors": errors, "productProposalApplied": false,
                                    "nativeUiVerified": false, "actualUserDefaultsUsed": false]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        if !errors.isEmpty { Foundation.exit(1) }
    }
}
