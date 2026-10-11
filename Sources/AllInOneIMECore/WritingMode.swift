import Foundation

/// What `@improve` and `@translate` ask the model for. Written together (`@translate @improve …`, in
/// either order) they are one request with both parts: the model is still called once.
public enum WritingMode: String, Equatable, Sendable {
    /// `@improve`: polished versions in the sentence's own language, and the rewrite styles.
    case improve
    /// `@translate`: the sentence in the output languages the user added (`Config.outputLanguages`).
    case translate
    /// Both: the translations, then the rewrite styles.
    case both

    /// The mode for `command` (nil: as `@improve`) and the text without the other command written
    /// inside it: "@translate @improve 你好" → (.both, "你好").
    public static func parse(_ command: Command?, _ text: String) -> (mode: WritingMode, text: String) {
        let own: WritingMode = command == .translate ? .translate : .improve
        let other: Command = own == .translate ? .improve : .translate
        let token = "@" + other.name
        var words = text.components(separatedBy: " ")
        guard let index = words.firstIndex(of: token) else { return (own, text) }
        words.remove(at: index)
        return (.both, words.joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }
}

/// The lines one request asks for, worked out from the mode, the sentence and the settings.
public struct WritingPlan: Equatable, Sendable {
    /// Three versions in this language: the one translation target, or the sentence's own language
    /// when they are polished versions (`@improve`, or nothing to translate into). Nil: none.
    public var versions: OutputLanguage?
    /// One line per language, when translating into several.
    public var translations: [OutputLanguage]
    /// The rewrites, in the sentence's own language.
    public var styles: [RewriteStyle]
    /// The sentence's own language.
    public var input: OutputLanguage

    /// `mode` for `text`: translations go to the added output languages other than the sentence's
    /// own (in the user's order); one target gets three versions, several get a line each.
    public static func make(_ mode: WritingMode, text: String, config: Config) -> WritingPlan {
        let input = OutputLanguage(Language.of(text))
        let styles = mode == .translate ? [] : RewriteStyle.resolve(config.rewriteStyles)
        guard mode != .improve else { return WritingPlan(versions: input, translations: [], styles: styles, input: input) }
        let targets = config.outputLanguages.filter { $0 != input }
        switch targets.count {
        case 0:
            // Nothing else to translate into (the sentence is in the only language added): polish it.
            return WritingPlan(versions: input, translations: [], styles: styles, input: input)
        case 1:
            return WritingPlan(versions: targets[0], translations: [], styles: styles, input: input)
        default:
            return WritingPlan(versions: nil, translations: targets, styles: styles, input: input)
        }
    }

    /// How many lines the answer has.
    var lineCount: Int { (versions == nil ? 0 : 3) + translations.count + styles.count }

    /// Part of the cache key: the same sentence asks for different lines in another plan.
    var key: String {
        [versions?.code ?? "-", translations.map(\.code).joined(separator: "+"), styles.map(\.tag).joined(separator: ",")]
            .joined(separator: "|")
    }
}
