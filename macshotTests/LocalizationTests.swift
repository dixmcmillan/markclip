import Cocoa
import XCTest

/// macshot ships 40 translations. Nothing in the build checks them, so a new
/// `L("…")` key or an edited translation can silently leave users with an
/// English string — or, for a format string, crash `String(format:)`.
///
/// These read the repository sources directly (via `#filePath`) rather than the
/// test bundle, because the keys live in Swift code, not in resources.
final class LocalizationTests: XCTestCase {

    // MARK: - Repository layout

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // macshotTests
        .deletingLastPathComponent()  // repo root

    private static let sourceRoot = repoRoot.appendingPathComponent("macshot")

    private static let baseLocale = "en"

    /// Locale code -> parsed strings table.
    private static let tables: [String: [String: String]] = {
        var tables: [String: [String: String]] = [:]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: sourceRoot, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension == "lproj" {
            let strings = url.appendingPathComponent("Localizable.strings")
            guard FileManager.default.fileExists(atPath: strings.path),
                  let dict = NSDictionary(contentsOf: strings) as? [String: String] else { continue }
            tables[url.deletingPathExtension().lastPathComponent] = dict
        }
        return tables
    }()

    /// Every `L("literal")` key used in the app sources.
    private static let keysUsedInCode: Set<String> = {
        var keys = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)"\)"#)
        let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(unescape(String(source[keyRange])))
            }
        }
        return keys
    }()

    /// Swift source escapes (`\n`, `\"`) as the .strings file stores them.
    private static func unescape(_ literal: String) -> String {
        literal
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// printf-style placeholders, in the order they appear.
    private static let formatSpecifier = try! NSRegularExpression(
        pattern: #"%(?:\d+\$)?[-+ #0]*[\d.*]*(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaAF%]"#)

    private static func specifiers(in value: String) -> [String] {
        let range = NSRange(value.startIndex..., in: value)
        return formatSpecifier.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }.sorted()
    }

    // MARK: - Sanity of the fixture itself

    func testTheTestCanSeeTheTranslations() throws {
        XCTAssertGreaterThan(Self.tables.count, 30, "expected the shipped locales at \(Self.sourceRoot.path)")
        XCTAssertNotNil(Self.tables[Self.baseLocale], "the English base table is missing")
        XCTAssertGreaterThan(Self.keysUsedInCode.count, 100, "the L(\"…\") scan found almost nothing — check the regex")
    }

    // MARK: - Coverage

    func testEveryKeyUsedInCodeExistsInEnglish() {
        let base = try? XCTUnwrap(Self.tables[Self.baseLocale])
        let missing = Self.keysUsedInCode.filter { base?[$0] == nil }.sorted()
        XCTAssertTrue(missing.isEmpty, """
            \(missing.count) key(s) used in code are missing from en.lproj/Localizable.strings, \
            so they'd show as raw keys: \(missing.prefix(10).joined(separator: " | "))
            """)
    }

    func testEveryLocaleTranslatesEveryEnglishKey() throws {
        let base = try XCTUnwrap(Self.tables[Self.baseLocale])
        var report: [String] = []
        for (locale, table) in Self.tables.sorted(by: { $0.key < $1.key }) where locale != Self.baseLocale {
            let missing = base.keys.filter { table[$0] == nil }.sorted()
            if !missing.isEmpty {
                report.append("\(locale): \(missing.count) missing (\(missing.prefix(3).joined(separator: ", ")))")
            }
        }
        XCTAssertTrue(report.isEmpty, "untranslated keys — these fall back to the raw key:\n" + report.joined(separator: "\n"))
    }

    func testNoTranslationIsEmpty() {
        var empty: [String] = []
        for (locale, table) in Self.tables {
            for (key, value) in table where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                empty.append("\(locale): \"\(key)\"")
            }
        }
        XCTAssertTrue(empty.isEmpty, "an empty translation shows as a blank label:\n" + empty.prefix(10).joined(separator: "\n"))
    }

    // MARK: - Format strings

    func testTranslationsKeepTheSameFormatPlaceholders() throws {
        // A translation that drops %d (or adds one) makes String(format:) read
        // an argument that isn't there.
        let base = try XCTUnwrap(Self.tables[Self.baseLocale])
        var problems: [String] = []
        for (locale, table) in Self.tables.sorted(by: { $0.key < $1.key }) where locale != Self.baseLocale {
            for (key, englishValue) in base {
                guard let translated = table[key] else { continue }
                let expected = Self.specifiers(in: englishValue)
                let actual = Self.specifiers(in: translated)
                if expected != actual {
                    problems.append("\(locale) \"\(key)\": en has \(expected), translation has \(actual)")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, "format placeholder mismatch — these can crash on formatting:\n"
                      + problems.prefix(10).joined(separator: "\n"))
    }

    func testFormatKeysUsedInCodeAreConsistentEverywhere() throws {
        // Narrower but sharper: only the keys the app actually formats.
        let base = try XCTUnwrap(Self.tables[Self.baseLocale])
        let formatKeys = Self.keysUsedInCode.filter { !Self.specifiers(in: base[$0] ?? "").isEmpty }
        for key in formatKeys {
            let expected = Self.specifiers(in: base[key] ?? "")
            for (locale, table) in Self.tables where locale != Self.baseLocale {
                guard let translated = table[key] else { continue }
                XCTAssertEqual(Self.specifiers(in: translated), expected,
                               "\(locale) changed the placeholders of \"\(key)\"")
            }
        }
    }

    // MARK: - File hygiene

    func testEveryLocaleFileParses() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.sourceRoot, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension == "lproj" {
            let strings = url.appendingPathComponent("Localizable.strings")
            guard FileManager.default.fileExists(atPath: strings.path) else { continue }
            let locale = url.deletingPathExtension().lastPathComponent
            XCTAssertNotNil(NSDictionary(contentsOf: strings) as? [String: String],
                            "\(locale)/Localizable.strings is malformed — the whole locale would fall back to English")
        }
    }

    func testNoLocaleFileDeclaresTheSameKeyTwice() throws {
        // NSDictionary silently keeps the last value, so duplicates hide edits.
        let keyPattern = try NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*="#, options: [.anchorsMatchLines])
        for (locale, _) in Self.tables {
            let url = Self.sourceRoot.appendingPathComponent("\(locale).lproj/Localizable.strings")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var seen = Set<String>()
            var duplicates: [String] = []
            let range = NSRange(text.startIndex..., in: text)
            for match in keyPattern.matches(in: text, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: text) else { continue }
                let key = String(text[keyRange])
                if !seen.insert(key).inserted { duplicates.append(key) }
            }
            XCTAssertTrue(duplicates.isEmpty, "\(locale) declares \(duplicates.prefix(5)) more than once")
        }
    }

    // MARK: - Language list

    func testEveryOfferedLanguageHasATranslationFile() {
        for (code, name) in LanguageManager.availableLanguages {
            XCTAssertFalse(name.isEmpty, "language \(code) has no display name")
            guard code != "system" else { continue }
            XCTAssertNotNil(Self.tables[code], "the settings list offers \(code), but there is no \(code).lproj")
        }
    }

    func testEveryTranslationFileIsOfferedInSettings() {
        let offered = Set(LanguageManager.availableLanguages.map(\.0))
        for locale in Self.tables.keys {
            XCTAssertTrue(offered.contains(locale), "\(locale).lproj ships but users can't select it")
        }
    }

    func testResolvedLanguageNeverReportsSystem() {
        XCTAssertNotEqual(LanguageManager.shared.resolvedLanguage, "system",
                          "resolvedLanguage has to name a real bundle")
        XCTAssertNotNil(Self.tables[LanguageManager.shared.resolvedLanguage],
                        "resolved to a locale that isn't shipped")
    }

    // MARK: - Diacritic damage

    /// A word written without diacritics where the same word appears accented
    /// elsewhere in the file is usually damage: an old script stripped
    /// diacritics from roughly 1,300 translated values, leaving misspelled UI
    /// text in ten languages.
    ///
    /// Some are legitimate, though — a word can collapse onto another once
    /// diacritics are removed (Vietnamese "trong", Czech case endings,
    /// Romanian's definite-article forms), so this is a ceiling rather than a
    /// ban. A locale that climbs above its budget has almost certainly been
    /// re-damaged; the fix is to repair the strings, not to raise the number.
    private static let diacriticSuspectBudget: [String: Int] = [
        // cs: +2 (Czech case endings — "souboru"/"poskytovatele" are plain
        // declined forms of words that appear accented in other cases
        // elsewhere; see the comment on `diacriticSuspects`).
        // hr: +1 ("brzi", the definite adjective form of "fast/quick", vs.
        // unrelated comparative "brži").
        // ro: +1 ("combina", infinitive "to combine", vs. imperative
        // "Combină!" — one of Romanian's verb-form collisions, same family
        // as the definite-article forms already noted below).
        // vi: +7 for the export UI ("thanh" x3 in "âm thanh" (audio), and
        // "ngày" (day) in "%d ngày trước" lighting up the four existing plain
        // "ngay" (immediately) — both ordinary words, not stripped diacritics).
        // Phase 7 (removed upload strings): ca 2->1, fr 6->5, ro 46->44, sk 3->1, vi 41->39.
        // vi: +8 (ordinary, very common words — "cung" in "cung cấp"
        // (provide/supply), "thanh" in "âm thanh" (audio) and "thanh menu"
        // (menu bar) — colliding with unrelated accented homographs, the
        // same tonal-collision pattern the existing budget already covers).
        "ca": 1, "cs": 19, "es": 0, "fr": 5, "hr": 2, "pl": 1,
        "pt": 1, "pt-BR": 1, "ro": 44, "sk": 1, "sv": 1, "tr": 6, "vi": 46,
    ]

    private static func deaccented(_ word: String) -> String {
        String(word.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !(0x0300...0x036F).contains($0.value)
        })
    }

    /// Counts words in `table` that are ASCII while the same word appears
    /// accented in another value of the same table.
    private static func diacriticSuspects(in table: [String: String], locale: String) -> [String: Int] {
        var accented = Set<String>()
        var plain: [String: Int] = [:]
        for value in table.values {
            for word in value.split(whereSeparator: { !$0.isLetter }).map(String.init) {
                guard word.count > 3 else { continue }
                if word.unicodeScalars.contains(where: { !$0.isASCII }) {
                    accented.insert(deaccented(word).lowercased())
                } else {
                    plain[word.lowercased(), default: 0] += 1
                }
            }
        }
        // Vietnamese "trong" (in/inside) and "trống" (empty) are both valid
        // words. The presence of one does not make the other damaged text.
        // Exclude this known homograph instead of rewriting correct UI copy
        // or increasing the damage budget whenever another "in" is added.
        // Spanish video/vídeo are both valid regional spellings (FundéuRAE:
        // https://www.fundeu.es/recomendacion/video-video/).
        let validPlainWords: Set<String>
        switch locale {
        // "trong" (in/inside) vs "trống" (empty); "thay" (replace/instead) vs "thấy" (see/find).
        case "vi": validPlainWords = ["trong", "thay"]
        // "esta" (this) and "está" (is) are different words.
        case "es": validPlainWords = ["video", "esta"]
        // "audio" here is always the literal, untranslated `/audio/transcriptions`
        // API path (the transcription provider's endpoint) embedded in a
        // translated sentence, not damaged text — the real word is "áudio".
        case "pt", "pt-BR": validPlainWords = ["esta", "audio"]
        // "copia" (copy, verb) vs "còpia" (a copy). "audio": same
        // `/audio/transcriptions` API path as above ("àudio" is the real word).
        case "ca": validPlainWords = ["copia", "audio"]
        // "enregistre" (records) vs "enregistré" (recorded).
        case "fr": validPlainWords = ["enregistre"]
        // "andra" (other) vs "ändra" (change); "fast" (fixed) vs "fäst" (attach).
        case "sv": validPlainWords = ["andra", "fast"]
        // "imleci" (the pointer, accusative) vs "imleç" (pointer).
        case "tr": validPlainWords = ["imleci"]
        default: validPlainWords = []
        }
        return plain.filter { accented.contains($0.key) && !validPlainWords.contains($0.key) }
    }

    func testNoLocaleHasMoreDiacriticDamageThanItsBudget() {
        var report: [String] = []
        for (locale, table) in Self.tables.sorted(by: { $0.key < $1.key }) where locale != Self.baseLocale {
            let suspects = Self.diacriticSuspects(in: table, locale: locale)
            let count = suspects.values.reduce(0, +)
            let budget = Self.diacriticSuspectBudget[locale] ?? 0
            if count > budget {
                let worst = suspects.sorted { $0.value > $1.value }.prefix(4)
                    .map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
                report.append("\(locale): \(count) suspect words (budget \(budget)) — \(worst)")
            }
        }
        XCTAssertTrue(report.isEmpty, """
            Translations look like their diacritics were stripped:
            \(report.joined(separator: "\n"))
            """)
    }

    func testTheDiacriticBudgetHasNoStaleSlack() {
        // The companion to the test above: that one fails when a locale gets
        // worse, this one when it gets better, so a repaired locale can't leave
        // room for future damage to hide in.
        for (locale, budget) in Self.diacriticSuspectBudget {
            guard let table = Self.tables[locale] else {
                return XCTFail("budget lists `\(locale)`, which isn't a shipped locale")
            }
            let count = Self.diacriticSuspects(in: table, locale: locale).values.reduce(0, +)
            XCTAssertGreaterThanOrEqual(count, budget, """
                `\(locale)` is down to \(count) suspect words but the budget still says \(budget) — \
                lower it to \(count) so the slack can't hide new damage.
                """)
        }
    }

    func testVietnameseInAndEmptyDoNotImplyDiacriticDamage() {
        let table = ["in": "trong", "empty": "trống", "correct": "bình thường", "damaged": "binh thuong"]
        let suspects = Self.diacriticSuspects(in: table, locale: "vi")
        XCTAssertNil(suspects["trong"])
        XCTAssertEqual(suspects["binh"], 1)
        XCTAssertEqual(suspects["thuong"], 1)
    }

    func testSpanishVideoSpellingsAreValidWithoutMaskingOtherDamage() {
        let suspects = Self.diacriticSuspects(in: ["a": "video vídeo", "b": "cámara camara"], locale: "es")
        XCTAssertNil(suspects["video"])
        XCTAssertEqual(suspects["camara"], 1)
    }

    // MARK: - Runtime brand substitution (Markclip)

    /// The shipped translations still say "macshot" — that's the upstream
    /// brand the fork's ~35 English keys (and their 40 translations) were
    /// written against. `LanguageManager.applyBrand` substitutes it at
    /// lookup time instead of hand-editing every locale file. These tests
    /// exercise that substitution directly against the real `.strings`
    /// tables, so a future edit that reintroduces "macshot"/"MacShot" text
    /// a user can see would either get rebranded correctly or get caught here.

    func testApplyBrandRewritesTheCommonCases() {
        XCTAssertEqual(LanguageManager.applyBrand("Quit macshot"), "Quit Markclip")
        XCTAssertEqual(LanguageManager.applyBrand("macshot Preferences"), "Markclip Preferences")
        XCTAssertEqual(LanguageManager.applyBrand("Enable macshot:// URL scheme"),
                       "Enable markclip:// URL scheme")
        XCTAssertEqual(LanguageManager.applyBrand("Trigger macshot from Raycast"),
                       "Trigger Markclip from Raycast")
        XCTAssertEqual(LanguageManager.applyBrand("MacShot's update server"), "Markclip's update server")
        XCTAssertEqual(LanguageManager.applyBrand("No brand here"), "No brand here")
    }

    func testApplyBrandNeverLeavesTheUpstreamNameBehind() throws {
        var leaks: [String] = []
        for (locale, table) in Self.tables {
            for (key, value) in table {
                let rebranded = LanguageManager.applyBrand(value)
                if rebranded.localizedCaseInsensitiveContains("macshot") {
                    leaks.append("\(locale) \"\(key)\": \"\(rebranded)\"")
                }
            }
        }
        XCTAssertTrue(leaks.isEmpty, "runtime brand substitution left the upstream name visible:\n"
                      + leaks.prefix(10).joined(separator: "\n"))
    }

    func testApplyBrandPreservesFormatPlaceholders() throws {
        // Substitution must not disturb printf-style placeholders — the
        // format-consistency tests above assume the pre-substitution text.
        let base = try XCTUnwrap(Self.tables[Self.baseLocale])
        for (key, value) in base where !Self.specifiers(in: value).isEmpty {
            XCTAssertEqual(Self.specifiers(in: LanguageManager.applyBrand(value)), Self.specifiers(in: value),
                           "brand substitution changed the placeholders of \"\(key)\"")
        }
    }

    func testLDoesTheSubstitutionEndToEnd() {
        // `L(_:)` is the shorthand every call site uses; confirm the
        // substitution is actually wired into it, not just into the helper.
        // Don't assume the resolved runtime language is English — just that
        // whichever translation comes back has already been rebranded.
        XCTAssertFalse(L("Quit macshot").localizedCaseInsensitiveContains("macshot"),
                       "L(\"Quit macshot\") should return a rebranded string, got: \(L("Quit macshot"))")
    }
}
