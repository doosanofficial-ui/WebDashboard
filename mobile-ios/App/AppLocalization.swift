import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
    case korean = "ko"
    case english = "en"
    var id: String { rawValue }
    var nativeName: String { self == .korean ? "한국어" : "English" }
    static func resolve(saved: String?, preferredLanguages: [String]) -> AppLanguage {
        if let saved, let language = AppLanguage(rawValue: saved) { return language }
        return preferredLanguages.first?.lowercased().split(separator: "-").first == "ko" ? .korean : .english
    }
}

@MainActor @Observable
final class AppLanguageStore {
    static let preferenceKey = "telemetry.appLanguage"
    static let shared: AppLanguageStore = {
        let args = ProcessInfo.processInfo.arguments
        // Explicit Simulator test choice; never changes the system language or original data.
        let index = args.firstIndex(of: "--app-language")
        let override = index.flatMap { $0 + 1 < args.count ? AppLanguage(rawValue: args[$0 + 1]) : nil }
        return AppLanguageStore(initialOverride: override)
    }()
    private(set) var language: AppLanguage
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages,
         initialOverride: AppLanguage? = nil) {
        self.defaults = defaults
        language = initialOverride ?? AppLanguage.resolve(saved: defaults.string(forKey: Self.preferenceKey),
                                                        preferredLanguages: preferredLanguages)
    }
    func select(_ language: AppLanguage) {
        self.language = language
        defaults.set(language.rawValue, forKey: Self.preferenceKey)
    }
}

@MainActor
enum AppLocalization {
    private struct Template: Decodable { let en: String; let ko: String; let localizeSlots: [Int]? }
    private static let templates: [(NSRegularExpression, String, Set<Int>)] = {
        guard let url = Bundle.main.url(forResource: "AppStringTemplates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([Template].self, from: data) else { return [] }
        return values.compactMap { template in
            let chunks = template.en.components(separatedBy: "{value}")
            let pattern = "^" + chunks.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "$"
            return (try? NSRegularExpression(pattern: pattern)).map { ($0, template.ko, Set(template.localizeSlots ?? [])) }
        }
    }()
    private static let koreanBundle: Bundle? = Bundle.main.path(forResource: "ko", ofType: "lproj").flatMap(Bundle.init(path:))
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 256
        return cache
    }()

    /// Translate presentation only. Semantic states, protocol identifiers and stored rows remain original.
    static func text(_ original: String, language: AppLanguage? = nil) -> String {
        guard (language ?? AppLanguageStore.shared.language) == .korean else { return original }
        if let cached = cache.object(forKey: original as NSString) { return cached as String }
        let exact = koreanBundle?.localizedString(forKey: original, value: original, table: "Localizable") ?? original
        if exact != original { cache.setObject(exact as NSString, forKey: original as NSString); return exact }
        let range = NSRange(original.startIndex..., in: original)
        for (pattern, translation, localizeSlots) in templates {
            guard let match = pattern.firstMatch(in: original, range: range) else { continue }
            var values: [String] = []
            for i in 1..<match.numberOfRanges {
                guard let captured = Range(match.range(at: i), in: original) else { values.append(""); continue }
                let value = String(original[captured])
                values.append(localizeSlots.contains(i-1)
                    ? koreanBundle?.localizedString(forKey: value, value: value, table: "Localizable") ?? value
                    : value)
            }
            // Replace only placeholders in the original template, from right to left.
            // Inserted user names such as "{1}" must never be parsed again.
            let rendered = NSMutableString(string: translation)
            let placeholders = try! NSRegularExpression(pattern: "\\{([0-9]+)\\}")
            for slot in placeholders.matches(in: translation, range: NSRange(translation.startIndex..., in: translation)).reversed() {
                guard let digits = Range(slot.range(at: 1), in: translation),
                      let index = Int(translation[digits]), values.indices.contains(index) else { continue }
                rendered.replaceCharacters(in: slot.range, with: values[index])
            }
            let result = rendered as String
            cache.setObject(result as NSString, forKey: original as NSString)
            return result
        }
        cache.setObject(original as NSString, forKey: original as NSString)
        return original // Unknown device/OS diagnostics retain their verbatim evidence.
    }
}
