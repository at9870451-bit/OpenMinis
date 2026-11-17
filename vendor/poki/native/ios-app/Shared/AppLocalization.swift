import Foundation
import Observation

/// One language for Poki-owned UI. System UI keeps iOS's per-app language, and stored conversation
/// content stays as written. Resources still live in the existing String Catalogs.
@Observable final class AppLocalization {
    static let shared = AppLocalization()
    static let key = "uiLanguage"
    static let system = "system"

    var preference: String {
        didSet {
            UserDefaults.standard.set(preference, forKey: Self.key)
            Self.publish()
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? Self.system
        preference = Self.languages.contains(saved) ? saved : Self.system
    }

    /// Adding a bundled localization makes it available here without another language-specific case.
    static let languages: [String] = {
        // Bundle can return the same identifier from CFBundleLocalizations and its .lproj folders.
        Set(Bundle.main.localizations).subtracting(["Base"]).sorted()
    }()

    static func resolve(_ preference: String, supported: [String], preferred: [String]) -> String {
        if supported.contains(preference) { return preference }
        return Bundle.preferredLocalizations(from: supported, forPreferences: preferred).first ?? "en"
    }

    private static let cache = LocalizationCache(supported: languages)

    private static var resolved: LocalizationCache.Value {
        #if POKI_APP
        let preference = shared.preference // Keep SwiftUI's Observation dependency.
        #else
        // Re-read this cheap key: defaults notifications do not reliably cross process boundaries.
        let preference = SharedContainer.defaults.string(forKey: "effectiveUILanguage") ?? system
        #endif
        return cache.value(for: preference)
    }

    static var language: String { resolved.language }
    static var locale: Locale { resolved.locale }

    /// String(localized:locale:) only changes interpolation formatting. A resource's locale also
    /// chooses its translation. Keeping the resource at the call site preserves catalog extraction.
    static func text(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    /// Existing runtime status keys, never arbitrary user/model content.
    static var bundle: Bundle { resolved.bundle }

    static func publish() {
        SharedContainer.defaults.set(language, forKey: "effectiveUILanguage")
    }
}

/// A single resolved snapshot per preference. Locale changes invalidate even an explicit language:
/// its date/number formatting must continue to follow the current system region.
final class LocalizationCache {
    struct Value {
        let language: String
        let locale: Locale
        let bundle: Bundle
    }

    private let lock = NSLock()
    private let supported: [String]
    private let preferred: () -> [String]
    private let currentLocale: () -> Locale
    private let notifications: NotificationCenter
    private var observer: NSObjectProtocol?
    private var cached: (preference: String, value: Value)?

    init(supported: [String], notifications: NotificationCenter = .default,
         preferred: @escaping () -> [String] = { Bundle.main.preferredLocalizations },
         currentLocale: @escaping () -> Locale = { Locale.current }) {
        self.supported = supported
        self.preferred = preferred
        self.currentLocale = currentLocale
        self.notifications = notifications
        observer = notifications.addObserver(forName: NSLocale.currentLocaleDidChangeNotification,
                                              object: nil, queue: nil) { [weak self] _ in
            self?.invalidate()
        }
    }

    deinit {
        if let observer { notifications.removeObserver(observer) }
    }

    private func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    func value(for preference: String) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.preference == preference { return cached.value }
        let language = AppLocalization.resolve(preference, supported: supported, preferred: preferred())
        let systemLocale = currentLocale()
        var components = Locale.Components(identifier: systemLocale.identifier)
        components.languageComponents = Locale.Components(identifier: language).languageComponents
        components.languageComponents.region = systemLocale.region
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        let value = Value(language: language, locale: Locale(components: components), bundle: bundle)
        cached = (preference, value)
        return value
    }
}
