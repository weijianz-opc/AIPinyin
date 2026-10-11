import Foundation

/// The two languages the input method writes in: the default input mode and the output language.
public enum Language: String, Codable, CaseIterable, Sendable {
    case chinese = "zh"
    case english = "en"

    /// Name shown in the UI.
    public var displayName: String { self == .chinese ? "中文" : "英文" }

    /// Tag of the level-two lines in this language ("EN: …", "ZH: …").
    var tag: String { self == .chinese ? "ZH" : "EN" }

    /// Name used in the prompt.
    var promptName: String { self == .chinese ? "Simplified Chinese" : "English" }

    /// The language a typed sentence is written in: Chinese as soon as it contains Chinese characters.
    public static func of(_ text: String) -> Language { text.containsHan ? .chinese : .english }
}

/// A language the three main versions (1–3) can be written in: the user adds the ones they want
/// (`Config.outputLanguages`) and picks one (`Config.outputLanguage`). Stored as its code ("en",
/// "zh", "ja", …), so config files from before keep working.
public struct OutputLanguage: Hashable, Codable, Sendable, Identifiable {
    /// A BCP-47 code: "en", "zh", "zh-Hant", "ja".
    public let code: String

    public init(_ code: String) { self.code = code }

    public init(_ language: Language) { code = language.rawValue }

    public var id: String { code }

    public static let english = OutputLanguage("en")
    public static let chinese = OutputLanguage("zh")

    /// The languages that can be added, in the order the settings offer them.
    public static let catalog: [OutputLanguage] = [
        "en", "zh", "zh-Hant", "ja", "ko", "fr", "de", "es", "pt", "it", "ru", "vi", "th", "id", "ar",
    ].map(OutputLanguage.init)

    /// The input language this is, when it is one ("zh" is Chinese; "zh-Hant" is not: Chinese typed in
    /// pinyin comes out simplified, so it is translated into traditional).
    public var input: Language? { Language(rawValue: code) }

    /// Tag of the level-two lines in this language ("EN: …", "ZH: …", "ZHHANT: …").
    var tag: String { code.uppercased().filter(\.isLetter) }

    /// Name used in the prompt ("English", "Simplified Chinese", "Traditional Chinese", "Japanese").
    var promptName: String {
        switch code {
        case "zh": return "Simplified Chinese"
        case "zh-Hant": return "Traditional Chinese"
        default: return Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
        }
    }

    /// Its name in the interface language: "英文", "日语" / "English", "Japanese".
    public func name(chinese: Bool) -> String {
        switch (code, chinese) {
        case ("en", true): return "英文"
        case ("zh", true): return "中文"
        case ("zh", false): return "Chinese"
        case ("zh-Hant", true): return "繁体中文"
        case ("zh-Hant", false): return "Traditional Chinese"
        default:
            return Locale(identifier: chinese ? "zh-Hans" : "en").localizedString(forIdentifier: code) ?? code
        }
    }

    public init(from decoder: Decoder) throws {
        code = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(code)
    }
}

extension Language {
    /// Whether a sentence in this language is polished (not translated) for `output`.
    public func matches(_ output: OutputLanguage) -> Bool { output.input == self }
}
