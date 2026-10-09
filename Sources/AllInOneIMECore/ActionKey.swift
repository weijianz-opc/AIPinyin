import Foundation

/// The key that runs the action on a finished sentence (config `actionKey`): improve it (translate
/// or polish, with rewrites), or the @ command at its start.
public enum ActionKey: String, Codable, CaseIterable, Sendable {
    /// Return (the default). ⇧Return then inserts the sentence as typed.
    case enter
    /// Either Option key pressed and released on its own (holding the right one still dictates).
    /// Space keeps its usual meaning: it picks candidates, and in a draft it is a space.
    case optionTap
    /// ⌥Space. Space keeps its usual meaning, as with `optionTap`.
    case optionSpace
    /// Space on a finished sentence, a double Space in English mode (the original behavior).
    case space

    /// Name in hints and settings ("⏎ → 翻译成英文": ⏎ → translate into English).
    public var displayName: String {
        switch self {
        case .enter: return "⏎"
        case .optionSpace: return "⌥空格"
        case .optionTap: return "单按 ⌥"
        case .space: return "空格"
        }
    }

    /// How to press it, in Chinese, as in "打中文按 ⏎" (type Chinese, press ⏎): "按 ⏎", "按 ⌥空格",
    /// "单按 ⌥", "按空格"; for English input with `space`, "连按两次空格" (press Space twice).
    /// `UIText.howToPress` has the English.
    public func howToPress(english: Bool = false) -> String {
        switch self {
        case .enter: return "按 ⏎"
        case .optionSpace: return "按 ⌥空格"
        case .optionTap: return "单按 ⌥"
        case .space: return english ? "连按两次空格" : "按空格"
        }
    }
}
