import Foundation

/// The language Poki names known apps in, from its effective UI language: Simplified or Traditional
/// Chinese, or English for any other. Apps' names (`AppIconStore.name`) and the home page's default
/// quick actions (`HomeIdea`) follow it.
enum AppLanguage {
    case english, simplifiedChinese, traditionalChinese

    static var current: AppLanguage {
        let language = AppLocalization.language
        if language.hasPrefix("zh-Hant") || language.hasPrefix("zh-TW") || language.hasPrefix("zh-HK") { return .traditionalChinese }
        return language.hasPrefix("zh") ? .simplifiedChinese : .english
    }
}

/// App identities stay in storage and icon lookups; only these names reach presentation text.
enum AppName {
    static func display(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name.lowercased() != "unknown", !name.hasPrefix("Home screen") else { return nil }
        if let known = KnownApps.find(name) {
            return known.name(in: .current)
        }
        // Unlisted apps can arrive with their on-screen name or their reverse-DNS identifier.
        guard !name.contains(".") || name.contains(where: \.isWhitespace) else { return nil }
        return name
    }
}
