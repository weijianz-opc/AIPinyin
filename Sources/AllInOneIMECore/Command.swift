import Foundation

/// A command typed at the start of a draft, e.g. "@question 量子计算是什么". The action key then
/// runs it on the rest of the draft. A draft without one is improved (translated or polished,
/// with the rewrites), as `@improve` does.
public enum Command: String, CaseIterable, Sendable {
    /// Translate or polish, with the rewrites: what the action key does without a command.
    case improve
    /// Answer a question; the answer can be inserted.
    case question
    /// Start a Claude Code session in Terminal with the text as its first message (long work,
    /// conversations); nothing is inserted.
    case claude
    /// Find files and apps by name (Spotlight) or path, as you type, and open the one picked.
    case open

    public enum Kind: Equatable, Sendable {
        /// The improve conversion (versions and rewrites).
        case convert
        /// One text written by the model from the input (`Prompt.commandRequest`).
        case generate
        /// A program run in a terminal window with the input.
        case terminal
        /// A Spotlight search; picking a result opens it.
        case search
    }

    public var kind: Kind {
        switch self {
        case .improve: return .convert
        case .question: return .generate
        case .claude: return .terminal
        case .open: return .search
        }
    }

    /// The draft's command and the text after it: "@question 量子计算" → (.question, "量子计算").
    /// Nil without a known command (the "@" must be first, the name followed by a space).
    public static func parse(_ draft: String) -> (command: Command, content: String)? {
        guard draft.hasPrefix("@"), let space = draft.firstIndex(of: " "),
              let command = Command(rawValue: draft[draft.index(after: draft.startIndex)..<space].lowercased())
        else { return nil }
        return (command, String(draft[draft.index(after: space)...]))
    }

    /// Commands whose name starts with `prefix` (case-insensitive), in catalog order.
    public static func matching(_ prefix: String) -> [Command] {
        let prefix = prefix.lowercased()
        return allCases.filter { $0.rawValue.hasPrefix(prefix) }
    }
}

/// A file, folder or app found for `@open`.
public struct SearchResult: Equatable, Sendable {
    /// Shown in the panel ("Calculator", "报告.pdf").
    public var name: String
    public var path: String
    /// A folder (not an app bundle): Tab goes into it.
    public var isFolder: Bool

    public init(name: String, path: String, isFolder: Bool = false) {
        self.name = name
        self.path = path
        self.isFolder = isFolder
    }
}
