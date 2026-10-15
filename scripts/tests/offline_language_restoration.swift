import Foundation

// Host-only source harness. These module-local names shadow Foundation in the
// compiled product prefix. No suite, persistent domain, CFPreferences, daemon,
// Simulator or real user Locale is opened, even through default arguments.
final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    var values: [String: String]
    var pending: [String: String] = [:]
    var deferWrites = false
    var writes = 0
    var reads = 0
    init(_ values: [String: String] = ["telemetry.appLanguage": "en"]) { self.values = values }
    func string(forKey key: String) -> String? {
        reads += 1
        return pending[key] ?? values[key]
    }
    func set(_ value: Any?, forKey key: String) {
        writes += 1
        if deferWrites { pending[key] = value as? String }
        else { values[key] = value as? String }
    }
    func flushSyntheticQueue() {
        values.merge(pending) { _, queued in queued }
        pending.removeAll()
    }
}
enum Locale { static let preferredLanguages = ["en-US"] }

@main struct LanguageRestorationChecks {
    @MainActor static func main() throws {
        let key = AppLanguageStore.preferenceKey
        var cases: [[String: Any]] = []
        func check(_ name: String, _ condition: Bool) {
            cases.append(["name": name, "passed": condition])
        }
        let normal = UserDefaults()
        let normalStore = AppLanguageStore(defaults: normal, preferredLanguages: ["ko-KR"])
        check("saved language wins over locale without writing", normalStore.language == .english && normal.writes == 0)
        normalStore.select(.korean)
        check("ordinary language selection persists", normalStore.language == .korean && normal.values[key] == "ko" && normal.writes == 1)

        let overridden = UserDefaults()
        let overriddenStore = AppLanguageStore(defaults: overridden, preferredLanguages: ["en-US"], initialOverride: .korean)
        check("argument override initialization is read/write free", overriddenStore.language == .korean && overridden.reads == 0 && overridden.writes == 0 && overridden.values[key] == "en")
        overriddenStore.select(.english)
        overriddenStore.select(.korean)
        check("explicit picker selections still persist under an initial override", overridden.writes == 2 && overridden.values[key] == "ko")

        let cached = UserDefaults()
        let cachedStore = AppLanguageStore(defaults: cached, preferredLanguages: ["en-US"])
        cachedStore.select(.korean)
        cached.values[key] = "en" // Simulated byte restoration, not a preference API.
        check("byte restoration does not refresh a retained AppLanguageStore", cached.values[key] == "en" && cachedStore.language == .korean)
        let recreated = AppLanguageStore(defaults: cached, preferredLanguages: ["en-US"])
        check("a fresh unoverridden store reads restored state after synthetic quiescence", recreated.language == .english)

        let queued = UserDefaults()
        queued.deferWrites = true
        let queuedStore = AppLanguageStore(defaults: queued, preferredLanguages: ["en-US"])
        queuedStore.select(.korean)
        queued.values[key] = "en"
        let matchedBeforeFlush = queued.values[key] == "en"
        queued.flushSyntheticQueue()
        let afterQueuedWrite = AppLanguageStore(defaults: queued, preferredLanguages: ["en-US"])
        check("a queued writer can invalidate a successful byte comparison", matchedBeforeFlush && queued.values[key] == "ko" && afterQueuedWrite.language == .korean)

        let absent = UserDefaults([:])
        let absentStore = AppLanguageStore(defaults: absent, preferredLanguages: ["ko-KR"])
        absentStore.select(.english)
        absent.values.removeAll()
        let absentRecreated = AppLanguageStore(defaults: absent, preferredLanguages: ["ko-KR"])
        check("original absence restores locale fallback only in a fresh store", absentStore.language == .english && absentRecreated.language == .korean && absent.values[key] == nil)

        let wrongPersistent = UserDefaults([key: "ko"])
        let masked = AppLanguageStore(defaults: wrongPersistent, preferredLanguages: ["en-US"], initialOverride: .english)
        let unmasked = AppLanguageStore(defaults: wrongPersistent, preferredLanguages: ["en-US"])
        check("an argument override can mask an incorrectly restored preference", masked.language == .english && unmasked.language == .korean)
        check("invalid saved values fall back without rewriting original data", AppLanguage.resolve(saved: "unsupported", preferredLanguages: ["ko-KR"]) == .korean)

        // Exercise the real shared-store argument parser against local memory.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--app-language"), index + 1 < arguments.count,
           let expected = AppLanguage(rawValue: arguments[index + 1]) {
            check("shared parser uses a process-local test override", AppLanguageStore.shared.language == expected && UserDefaults.standard.writes == 0 && UserDefaults.standard.reads == 0)
        }
        let passed = cases.filter { $0["passed"] as? Bool == true }.count
        let result: [String: Any] = ["scope": "actual-product-store-source-with-memory-preferences",
                                    "cases": cases, "passed": passed, "failed": cases.count - passed,
                                    "actualUserDefaultsUsed": false, "actualLocalePreferencesRead": false,
                                    "realCFPreferencesCacheTested": false, "nativeRestorationCertified": false]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        if passed != cases.count { Foundation.exit(1) }
    }
}
