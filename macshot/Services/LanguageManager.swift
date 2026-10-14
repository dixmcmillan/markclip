import Foundation

/// Manages the active language for the app.
/// Loads from UserDefaults ("appLanguage"), falls back to system language, then English.
/// Supports runtime switching without app restart by swapping the active bundle.
///
/// A key a translation doesn't have falls back to the English table (then to the
/// key itself), so new strings only need an `en.lproj` entry.
final class LanguageManager {
    static let shared = LanguageManager()

    static let changedNotification = Notification.Name("LanguageManagerDidChange")

    /// Language code -> display name (in that language)
    static let availableLanguages: [(code: String, name: String)] = [
        ("system", "System Default"),
        ("ar", "العربية"),
        ("bg", "Български"),
        ("bn", "বাংলা"),
        ("ca", "Català"),
        ("cs", "Čeština"),
        ("da", "Dansk"),
        ("de", "Deutsch"),
        ("el", "Ελληνικά"),
        ("en", "English"),
        ("es", "Español"),
        ("fa", "فارسی"),
        ("fi", "Suomi"),
        ("fil", "Filipino"),
        ("fr", "Français"),
        ("he", "עברית"),
        ("hi", "हिन्दी"),
        ("hr", "Hrvatski"),
        ("hu", "Magyar"),
        ("id", "Bahasa Indonesia"),
        ("it", "Italiano"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("ms", "Bahasa Melayu"),
        ("nb", "Norsk bokmål"),
        ("nl", "Nederlands"),
        ("pl", "Polski"),
        ("pt", "Português"),
        ("pt-BR", "Português (Brasil)"),
        ("ro", "Română"),
        ("ru", "Русский"),
        ("sk", "Slovenčina"),
        ("sr", "Српски"),
        ("sv", "Svenska"),
        ("ta", "தமிழ்"),
        ("th", "ไทย"),
        ("tr", "Türkçe"),
        ("uk", "Українська"),
        ("vi", "Tiếng Việt"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
    ]

    private var bundle: Bundle = .main
    /// English table used when the active language lacks a key. Nil when the
    /// resources have no `en.lproj`.
    private var fallbackBundle: Bundle?
    private let defaults: UserDefaults
    private let resources: Bundle

    private convenience init() {
        self.init(defaults: .standard, resources: .main)
    }

    /// `resources` holds the `<code>.lproj` folders; tests point it at a temporary folder.
    init(defaults: UserDefaults, resources: Bundle) {
        self.defaults = defaults
        self.resources = resources
        reload()
    }

    /// The active language code. "system" means follow macOS preference.
    var currentLanguage: String {
        get { defaults.string(forKey: "appLanguage") ?? "system" }
        set {
            defaults.set(newValue, forKey: "appLanguage")
            reload()
            NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        }
    }

    /// Resolves the actual language code (never "system").
    var resolvedLanguage: String {
        let lang = currentLanguage
        if lang == "system" {
            // Find first system language we support
            let supported = Self.availableLanguages.map(\.code).filter { $0 != "system" }
            for preferred in Locale.preferredLanguages {
                // Check full code first (e.g. "zh-Hans"), then base language (e.g. "de")
                let normalized = preferred.replacingOccurrences(of: "_", with: "-")
                if supported.contains(normalized) { return normalized }
                // Try with script subtag (zh-Hans-CN -> zh-Hans)
                let parts = normalized.split(separator: "-")
                if parts.count >= 2 {
                    let withScript = "\(parts[0])-\(parts[1])"
                    if supported.contains(withScript) { return withScript }
                }
                let base = String(parts.first ?? "")
                if supported.contains(base) { return base }
            }
            return "en"
        }
        return lang
    }

    func localizedString(_ key: String) -> String {
        Self.applyBrand(Self.lookup(key, in: bundle, fallback: fallbackBundle))
    }

    /// `key` from `bundle`; when that table lacks it, from `fallback` (English);
    /// when neither has it, the key itself (which is the English text for most keys).
    static func lookup(_ key: String, in bundle: Bundle, fallback: Bundle?) -> String {
        // `localizedString(forKey:value:)` returns `value` for a missing key, so
        // a sentinel tells "missing" apart from a legitimately equal string.
        let missing = "\u{1}missing-translation\u{1}"
        let value = bundle.localizedString(forKey: key, value: missing, table: nil)
        guard value == missing else { return value }
        if let fallback {
            let english = fallback.localizedString(forKey: key, value: missing, table: nil)
            if english != missing { return english }
        }
        return key
    }

    /// Every one of the 40 shipped locales still says "macshot" (and a few
    /// "MacShot") in their translated strings — that's the upstream brand
    /// name the translations were written against. Rather than hand-editing
    /// ~35 keys across 40 `.strings` files (and re-doing it every time a
    /// translation is refreshed), the app-facing brand name is substituted
    /// once here, at lookup time, for every locale at once. `.strings` file
    /// *comments* aren't part of what `NSBundle` returns, so this only ever
    /// touches text a user actually sees.
    ///
    /// Order matters: the URL-scheme case ("macshot://") is replaced first so
    /// it becomes the lowercase "markclip://" scheme name rather than picking
    /// up the capitalized brand replacement below.
    static func applyBrand(_ string: String) -> String {
        guard string.contains("macshot") || string.contains("MacShot") else { return string }
        return string
            .replacingOccurrences(of: "macshot://", with: "markclip://")
            .replacingOccurrences(of: "MacShot", with: "Markclip")
            .replacingOccurrences(of: "macshot", with: "Markclip")
    }

    private func reload() {
        let lang = resolvedLanguage
        fallbackBundle = resources.path(forResource: "en", ofType: "lproj").flatMap { Bundle(path: $0) }
        if let path = resources.path(forResource: lang, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            bundle = langBundle
        } else {
            bundle = resources
        }
    }
}

/// Shorthand for localized string lookup.
func L(_ key: String) -> String {
    LanguageManager.shared.localizedString(key)
}
