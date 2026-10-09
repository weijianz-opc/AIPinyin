import Foundation

/// One entry of the pinyin engine's candidate menu.
public struct EngineCandidate: Equatable, Sendable {
    public var label: String
    public var text: String
    public var comment: String

    public init(label: String, text: String, comment: String = "") {
        self.label = label
        self.text = text
        self.comment = comment
    }
}

/// What the level-one engine currently shows.
public struct EngineSnapshot: Equatable, Sendable {
    /// True while the engine holds input that has not been committed.
    public var isComposing: Bool
    /// Inline composition text, e.g. "我今天 you dian".
    public var preedit: String
    /// Caret position in `preedit`, in Characters.
    public var cursor: Int
    /// Candidates on the current page.
    public var candidates: [EngineCandidate]
    public var highlighted: Int
    public var pageNumber: Int
    public var isLastPage: Bool
    /// Latin mode: the engine lets letters through to the application.
    public var isAsciiMode: Bool

    public init(
        isComposing: Bool = false, preedit: String = "", cursor: Int = 0,
        candidates: [EngineCandidate] = [], highlighted: Int = 0,
        pageNumber: Int = 0, isLastPage: Bool = true, isAsciiMode: Bool = false
    ) {
        self.isComposing = isComposing
        self.preedit = preedit
        self.cursor = cursor
        self.candidates = candidates
        self.highlighted = highlighted
        self.pageNumber = pageNumber
        self.isLastPage = isLastPage
        self.isAsciiMode = isAsciiMode
    }

    public static let empty = EngineSnapshot()
}

/// Level one: a local pinyin engine (librime in the app, a fake in tests). Main thread only.
public protocol PinyinEngine: AnyObject {
    /// Feeds one key as an X11 keysym plus modifier mask (see `RimeKey`). Returns true if consumed.
    func processKey(_ keycode: Int32, mask: Int32) -> Bool
    /// Text the engine committed since the last call, if any.
    func takeCommit() -> String?
    func snapshot() -> EngineSnapshot
    /// Selects a candidate on the current page (mouse click). Returns true if it was selected.
    func selectCandidate(onPage index: Int) -> Bool
    /// Commits the current composition as converted text and returns it.
    func commitComposition() -> String?
    /// The typed letters of the current composition.
    var rawInput: String { get }
    func clearComposition()
    func setAsciiMode(_ on: Bool)
}

extension String {
    /// True if the text contains CJK ideographs (i.e. it is Chinese text, not just symbols).
    public var containsHan: Bool {
        unicodeScalars.contains { $0.properties.isIdeographic }
    }

    /// The text without punctuation, whitespace and case: two strings with the same key say the
    /// same thing in the same words (e.g. "我今天有点不舒服" and "我今天有点不舒服。").
    public var wordingKey: String {
        var scalars = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .spaceSeparator, .lineSeparator, .paragraphSeparator, .control, .format:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars).lowercased()
    }
}
