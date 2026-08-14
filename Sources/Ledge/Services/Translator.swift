import AppKit
import Translation

/// Apple's on-device translator, driven from the panel.
///
/// The session is not ours to create: `translationTask` hands one over and owns
/// its lifetime, so everything here is about deciding *what* to translate and
/// holding the result. `TranslatePane` supplies the session.
@MainActor
final class Translator: ObservableObject {
    static let russian = Locale.Language(identifier: "ru")
    static let english = Locale.Language(identifier: "en")

    /// Both ends are always named. Leaving the source to the framework looks
    /// tempting, but its identifier is a separate asset that is not installed
    /// either — auto-detection fails with `unableToIdentifyLanguage`, and the
    /// translation that follows hangs instead of returning an error.
    struct Route: Equatable {
        /// Which column a language was picked in. Not which end of the pair it
        /// is: the direction flips with the script of the text, so the left
        /// column is sometimes `first` and sometimes `second`.
        enum Side { case source, target }

        var source: Locale.Language
        var target: Locale.Language
    }

    /// Keyed by the pane's debounced task. The counter is what makes a retry of
    /// unchanged text a new request rather than a no-op.
    struct Request: Equatable {
        var text: String
        var attempt: Int
    }

    @Published var input = ""
    @Published private(set) var output = ""
    @Published private(set) var failure: String?
    /// The failure is a missing language pack, which is a thing the user can
    /// go and fix — so the pane offers the button that takes them there.
    @Published private(set) var needsDownload = false

    private var attempt = 0

    init() {
        let defaults = UserDefaults.standard
        first = defaults.string(forKey: Self.firstKey).map(Locale.Language.init(identifier:)) ?? Self.english
        second = defaults.string(forKey: Self.secondKey).map(Locale.Language.init(identifier:)) ?? Self.russian
    }

    var request: Request { Request(text: input, attempt: attempt) }
    var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    var route: Route { routing(for: trimmed) }

    /// The chosen pair, and the direction is worked out from the text.
    ///
    /// Direction is decided by script rather than by language detection: a
    /// single word is far too short to identify reliably, and "привет" comes
    /// back as Bulgarian often enough to matter. Whichever side's script the
    /// text is written in becomes the source.
    ///
    /// When both sides share a script — German and English, say — there is
    /// nothing to tell them apart, so the pair keeps its stated direction and
    /// the swap button becomes the only way round. That is the honest failure:
    /// guessing between two Latin languages from a word and a half is how a
    /// translator starts answering confidently in the wrong direction.
    func routing(for text: String) -> Route {
        let forward = Route(source: first, target: second)
        guard let script = Self.script(of: text) else { return forward }
        if script == second.script?.identifier, script != first.script?.identifier {
            return Route(source: second, target: first)
        }
        return forward
    }

    /// Enough of a script to tell one side of the pair from the other.
    ///
    /// Only the blocks that separate the installed languages are looked at, and
    /// the first hit wins — mixed text is normally one language with a borrowed
    /// word in it, and the borrowed word is not what is being translated.
    private static func script(of text: String) -> String? {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF: return "Cyrl"
            case 0x0600...0x06FF, 0x0750...0x077F: return "Arab"
            case 0x3040...0x30FF: return "Jpan"
            case 0x4E00...0x9FFF: return "Hani"
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: return "Latn"
            default: continue
            }
        }
        return nil
    }

    // MARK: - The pair

    private static let firstKey = "translate.first"
    private static let secondKey = "translate.second"

    /// The two languages on screen. `first` is the left column's default side.
    ///
    /// Stored as identifiers rather than as the plain codes the panel used to
    /// hardcode: every pack is regional, so a language without a region names a
    /// variant that may not be the installed one.
    @Published var first: Locale.Language {
        didSet { UserDefaults.standard.set(first.maximalIdentifier, forKey: Self.firstKey) }
    }
    @Published var second: Locale.Language {
        didSet { UserDefaults.standard.set(second.maximalIdentifier, forKey: Self.secondKey) }
    }

    /// Everything this Mac can actually translate to or from `second`.
    ///
    /// Only installed pairs are offered. Listing all twenty-one supported
    /// languages would put eight dead ends in the menu, each of which answers
    /// with the same "download a pack" wall the panel cannot open.
    @Published private(set) var available: [Locale.Language] = []

    /// Sets whichever end of the pair that column is currently showing.
    ///
    /// Resolving the column to an end through the live route rather than
    /// assuming left is `first`: with Cyrillic in the field the columns are
    /// already the other way round, and picking German on the left would
    /// otherwise replace the language on the right.
    func choose(_ language: Locale.Language, for side: Route.Side) {
        let forward = route.source == first
        if (side == .source) == forward {
            first = language
        } else {
            second = language
        }
        clear()
        attempt += 1
        Task { await loadAvailable() }
    }

    func swap() {
        let held = first
        first = second
        second = held
        clear()
        attempt += 1
    }

    /// Fills the menu. Cheap enough to repeat, so it runs whenever the tab is
    /// opened — packs get downloaded while the app is running, and a menu that
    /// only listed what existed at launch would be wrong by the afternoon.
    func loadAvailable() async {
        let availability = LanguageAvailability()
        var found: [Locale.Language] = []
        for language in await availability.supportedLanguages {
            guard language.languageCode?.identifier != second.languageCode?.identifier else { continue }
            let out = await availability.status(from: language, to: second) == .installed
            let back = await availability.status(from: second, to: language) == .installed
            if out || back { found.append(language) }
        }
        available = found.sorted { Self.name($0).localizedCompare(Self.name($1)) == .orderedAscending }
    }

    /// The same route, said in the regional variant this machine actually has.
    ///
    /// `Locale.Language("en")` maximises to `en-Latn-US`, so a Mac whose English
    /// pack is the British one answers "not installed" for a pair it translates
    /// perfectly well — and the panel then sent its owner off to download
    /// something they already had. There is no such thing as a region-free pack:
    /// every one of them is regional, so naming a language without a region is
    /// naming a variant, and it may not be the downloaded one.
    ///
    /// The plain pair is tried first. If that fails, every regional variant the
    /// framework lists is tried in turn, and only when none of them is installed
    /// is the pack really missing.
    static func installedRoute(for route: Route) async -> Route? {
        let availability = LanguageAvailability()
        if await availability.status(from: route.source, to: route.target) == .installed {
            return route
        }

        let supported = await availability.supportedLanguages
        func variants(of language: Locale.Language) -> [Locale.Language] {
            guard let code = language.languageCode?.identifier else { return [language] }
            let matching = supported.filter { $0.languageCode?.identifier == code }
            return matching.isEmpty ? [language] : matching
        }

        for source in variants(of: route.source) {
            for target in variants(of: route.target) {
                if await availability.status(from: source, to: target) == .installed {
                    return Route(source: source, target: target)
                }
            }
        }
        return nil
    }

    func retry() {
        attempt += 1
    }

    func clear() {
        output = ""
        failure = nil
        needsDownload = false
    }

    func reset() {
        input = ""
        clear()
    }

    func run(_ session: TranslationSession) async {
        let text = trimmed
        guard !text.isEmpty else { clear(); return }
        guard let source = session.sourceLanguage, let target = session.targetLanguage else { return }

        // No language pack ships installed. `prepareTranslation()` is what asks
        // for one, but it blocks until its system prompt is answered — and that
        // prompt has nowhere to appear over a borderless panel of an app that
        // never activates, so it would hang forever. Check instead, and send
        // the user to the one place that can actually install it.
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else {
            output = ""
            needsDownload = status == .supported
            failure = needsDownload
                ? localized("The %@ → %@ language pack is not installed.", Self.name(source), Self.name(target))
                : localized("macOS does not translate this pair of languages.")
            return
        }

        do {
            let response = try await session.translate(text)
            guard !Task.isCancelled else { return }
            output = response.targetText
            failure = nil
            needsDownload = false
        } catch {
            guard !Task.isCancelled else { return }
            output = ""
            needsDownload = false
            failure = error.localizedDescription
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    /// "Русский", "English" — for the column headers. Named in the language the
    /// panel itself is in, not in the system's: those two can differ, and a
    /// column headed in one language above a button worded in another reads as
    /// a mistake.
    static func name(_ language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier,
              let name = Locale(identifier: appLanguage).localizedString(forLanguageCode: code) else {
            return language.languageCode?.identifier.uppercased() ?? "?"
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Short code for the header badge — "EN → RU" reads at a glance where a
    /// spelled-out name would not fit in the strip.
    static func code(_ language: Locale.Language) -> String {
        language.languageCode?.identifier.uppercased() ?? "?"
    }

    /// System Settings → General → Language & Region, which is where the
    /// "Translation Languages…" button lives.
    static func openLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
