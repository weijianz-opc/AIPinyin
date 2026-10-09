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
