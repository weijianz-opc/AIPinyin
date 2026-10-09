import Foundation

/// The key that sends a finished sentence to the model (config `translateKey`).
public enum TranslateKey: String, Codable, CaseIterable, Sendable {
    /// Either Option key pressed and released on its own (holding the right one still dictates).
    /// The default. Space keeps its usual meaning: it picks candidates, and in a draft it is a space.
    case optionTap
    /// ⌥Space. Space keeps its usual meaning, as with `optionTap`.
    case optionSpace
    /// Space on a finished sentence, a double Space in English mode (the original behavior).
    case space

    /// Name in hints and settings ("⌥空格 → 翻译成英文").
    public var displayName: String {
        switch self {
        case .optionSpace: return "⌥空格"
        case .optionTap: return "单按 ⌥"
        case .space: return "空格"
        }
    }

    /// How to press it, as in "打中文按 ⌥空格": "按 ⌥空格", "单按 ⌥", "按空格"; for English input
    /// with `space`, "连按两次空格".
    public func howToPress(english: Bool = false) -> String {
        switch self {
        case .optionSpace: return "按 ⌥空格"
        case .optionTap: return "单按 ⌥"
        case .space: return english ? "连按两次空格" : "按空格"
        }
    }
}
