import Foundation

/// A command typed at the start of a draft, e.g. "@question 量子计算是什么". The action key then
/// runs it on the rest of the draft. Without one, nothing is sent: the input method just types.
/// The built-in commands come first; the user's own (`Config.customCommands`) follow them
/// (`catalog`).
public struct Command: Hashable, Sendable {
    public let name: String
    public let kind: Kind
    /// The user's definition, for a command from the config (nil for the built-in ones).
    public let custom: CustomCommand?
    /// The installed plugin, for a command from one.
    public let plugin: InstalledPlugin?

    public enum Kind: Equatable, Sendable {
        /// The improve conversion (versions and rewrites).
        case convert
        /// One text written by the model from the input (`Prompt.commandRequest`).
        case generate
        /// A program run in a terminal window with the input.
        case terminal
        /// A Spotlight search; picking a result opens it.
        case search
        /// A program run in the background with the input; what it prints can be inserted.
        case run
        /// The background Claude Code tasks (`@tasks`): picking one opens it.
        case agents
        /// Opens the settings window (`@settings`), right when it is picked.
        case settings
    }

    init(name: String, kind: Kind, custom: CustomCommand? = nil, plugin: InstalledPlugin? = nil) {
        self.name = name
        self.kind = kind
        self.custom = custom
        self.plugin = plugin
    }

    /// Translate or polish, with the rewrites: what the action key does without a command.
    public static let improve = Command(name: "improve", kind: .convert)
    /// Answer a question; the answer can be inserted.
    public static let question = Command(name: "question", kind: .generate)
    /// Start a Claude Code session in Terminal with the text as its first message (long work,
    /// conversations); nothing is inserted.
    public static let claude = Command(name: "claude", kind: .terminal)
    /// Find files and apps by name (Spotlight) or path, as you type, and open the one picked.
    public static let open = Command(name: "open", kind: .search)

    /// A web page's title and text (`WebReader`), mostly inside another command's text as context:
    /// `@question 总结一下 @read https://…`.
    public static let read = Command(name: "read", kind: .run)

    /// The background tasks `@claude` started: how they're doing and what they replied.
    public static let tasks = Command(name: "tasks", kind: .agents)

    /// The settings window.
    public static let settings = Command(name: "settings", kind: .settings)

    public static let builtins: [Command] = [.improve, .question, .claude, .open, .read, .tasks, .settings]

    /// The text after the command is typed as Latin letters (file names, paths, code): picking the
    /// command switches the engine to English, and Chinese comes back when the command is done.
    public var typesLatin: Bool { self == .open || self == .read || custom?.typesLatin == true || plugin?.manifest.typesLatin == true }

    /// The program this command needs on the Mac: `claude` for `@claude`, `argv[0]` for a custom
    /// `run` or `terminal` command; nil when it needs none.
    public var program: String? {
        if self == .claude { return "claude" }
        guard let custom, custom.type != .prompt else { return nil }
        return custom.argv?.first
    }

    /// The built-in commands, then the installed plugins, then the user's valid ones
    /// (`CustomCommand.isValid`) whose names are still free, in the order of the config. When names
    /// clash, built-in > plugin > custom.
    public static func catalog(_ custom: [CustomCommand], plugins: [InstalledPlugin] = []) -> [Command] {
        var taken = Set(builtins.map(\.name))
        let fromPlugins = plugins.compactMap { plugin -> Command? in
            guard taken.insert(plugin.name).inserted else { return nil }
            switch plugin.manifest.type {
            case .script:
                return Command(name: plugin.name, kind: .run, plugin: plugin)
            case .prompt:
                // An AI instruction: the request is built like a custom prompt command's.
                let definition = CustomCommand(name: plugin.name, type: .prompt, summary: plugin.manifest.summary?.en,
                                               prompt: plugin.manifest.prompt, ascii: plugin.manifest.ascii)
                return Command(name: plugin.name, kind: .generate, custom: definition, plugin: plugin)
            }
        }
        return builtins + fromPlugins + custom.compactMap { definition in
            let name = definition.name.lowercased()
            guard definition.isValid, taken.insert(name).inserted else { return nil }
            let kind: Kind
            switch definition.type {
            case .prompt: kind = .generate
            case .run: kind = .run
            case .terminal: kind = .terminal
            }
            return Command(name: name, kind: kind, custom: definition)
        }
    }

    /// The draft's command and the text after it: "@question 量子计算" → (.question, "量子计算").
    /// Nil without a known command (the "@" must be first, the name followed by a space).
    public static func parse(_ draft: String, in commands: [Command] = builtins) -> (command: Command, content: String)? {
        guard draft.hasPrefix("@"), let space = draft.firstIndex(of: " ") else { return nil }
        let name = draft[draft.index(after: draft.startIndex)..<space].lowercased()
        guard let command = commands.first(where: { $0.name == name }) else { return nil }
        return (command, String(draft[draft.index(after: space)...]))
    }

    /// Commands whose name starts with `prefix` (case-insensitive), in catalog order.
    public static func matching(_ prefix: String, in commands: [Command] = builtins) -> [Command] {
        let prefix = prefix.lowercased()
        return commands.filter { $0.name.hasPrefix(prefix) }
    }
}

/// A command the user added in the config (`customCommands`), e.g.
///
///     { "name": "python", "type": "run", "argv": ["python3", "-c", "{input}"] }
///
/// - `prompt`: the text goes to the model with `prompt` as the instruction; the answer can be inserted.
/// - `run`: `argv` runs in the background (no shell) with `{input}` replaced by the text, or the text
///   on standard input (`stdin`); what it prints can be inserted.
/// - `terminal`: `argv` runs in a new Terminal window; nothing is inserted.
///
/// `{input}` always stays inside the one argument it is written in: the text is never parsed by a
/// shell unless `argv` itself says so (`["zsh", "-c", "{input}"]`).
public struct CustomCommand: Codable, Hashable, Sendable {
    public enum CommandType: String, Codable, Sendable {
        case prompt, run, terminal
    }

    /// Letters only, as typed after "@" (digits pick from the command list).
    public var name: String
    public var type: CommandType
    /// Shown next to the name in the command list.
    public var summary: String?
    /// `prompt`: the instruction for the model.
    public var prompt: String?
    /// `run`, `terminal`: the program and its arguments. A program without a "/" is looked up in the
    /// user's shell PATH.
    public var argv: [String]?
    /// `run`: what goes to the program's standard input (`{input}` is replaced); nil: nothing.
    public var stdin: String?
    /// Type the text as Latin letters (code, paths). Default: true for `run` and `terminal`.
    public var ascii: Bool?
    /// `run`: the program is stopped after this many seconds (default 10).
    public var timeoutSeconds: Double?
    /// Its icon in the command list: an SF Symbol name ("chart.bar"), and a color (a system color's
    /// name, "blue", or "#RRGGBB"); unset, one for its type.
    public var icon: String?
    public var color: String?

    public init(name: String, type: CommandType, summary: String? = nil, prompt: String? = nil,
                argv: [String]? = nil, stdin: String? = nil, ascii: Bool? = nil, timeoutSeconds: Double? = nil,
                icon: String? = nil, color: String? = nil) {
        self.name = name
        self.type = type
        self.summary = summary
        self.prompt = prompt
        self.argv = argv
        self.stdin = stdin
        self.ascii = ascii
        self.timeoutSeconds = timeoutSeconds
        self.icon = icon
        self.color = color
    }

    public static let placeholder = "{input}"
    public static let defaultTimeout: Double = 10

    /// A name of letters (what the command list can type), and what its type needs.
    public var isValid: Bool {
        guard !name.isEmpty, name.count <= 24, name.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        switch type {
        case .prompt: return !(prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .run, .terminal: return !(argv?.first ?? "").isEmpty
        }
    }

    public var typesLatin: Bool { ascii ?? (type != .prompt) }

    public var timeout: Double { max(timeoutSeconds ?? Self.defaultTimeout, 0.1) }

    /// `argv` with `{input}` replaced in each argument (each stays one argument).
    public func arguments(for input: String) -> [String] {
        let text = typesLatin ? Self.halfWidth(input) : input
        return (argv ?? []).map { $0.replacingOccurrences(of: Self.placeholder, with: text) }
    }

    /// What goes to standard input, if anything.
    public func standardInput(for input: String) -> String? {
        let text = typesLatin ? Self.halfWidth(input) : input
        return stdin.map { $0.replacingOccurrences(of: Self.placeholder, with: text) }
    }

    /// Full-width punctuation a Chinese keyboard layout types, as the ASCII that code means by it:
    /// `print（“牛逼”）` → `print("牛逼")`. Letters and Chinese text stay as they are.
    public static func halfWidth(_ text: String) -> String {
        let map: [Character: String] = [
            "（": "(", "）": ")", "【": "[", "】": "]", "「": "\"", "」": "\"", "『": "'", "』": "'",
            "“": "\"", "”": "\"", "‘": "'", "’": "'", "，": ",", "。": ".", "：": ":", "；": ";",
            "！": "!", "？": "?", "《": "<", "》": ">", "、": "\\", "～": "~", "｜": "|", "＝": "=",
            "＋": "+", "－": "-", "＊": "*", "／": "/", "＃": "#", "＄": "$", "％": "%", "＆": "&",
            "＠": "@", "｛": "{", "｝": "}", "［": "[", "］": "]", "＜": "<", "＞": ">", "…": "...",
            "·": "`", "　": " ",
        ]
        return String(text.flatMap { map[$0].map(Array.init) ?? [$0] })
    }
}

extension CustomCommand {
    /// What keeps a definition from being saved, for the settings' editor.
    public enum Problem: Equatable, Sendable {
        case emptyName
        /// Only letters can be typed after "@" (digits pick from the command list).
        case nameNotLetters
        /// A built-in command, or another custom one, has this name.
        case nameTaken
        case emptyPrompt
        case emptyCommand
        /// A quote in the command line isn't closed.
        case unbalancedQuote
    }

    /// The first problem with this definition among `others` (the other custom commands) and the
    /// installed plugins' names, or nil.
    public func problem(among others: [CustomCommand], plugins: [String] = []) -> Problem? {
        let name = name.lowercased()
        if name.isEmpty { return .emptyName }
        if !name.allSatisfy({ $0.isASCII && $0.isLetter }) || name.count > 24 { return .nameNotLetters }
        if Command.builtins.contains(where: { $0.name == name }) || plugins.contains(name)
            || others.contains(where: { $0.name.lowercased() == name }) {
            return .nameTaken
        }
        switch type {
        case .prompt:
            if (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyPrompt }
        case .run, .terminal:
            if (argv?.first ?? "").isEmpty { return .emptyCommand }
        }
        return nil
    }

    /// Arguments as one line, quoted where needed: ["python3", "-c", "{input}"] → `python3 -c {input}`.
    public static func commandLine(_ argv: [String]) -> String {
        argv.map { arg in
            guard arg.isEmpty || arg.contains(where: { " \t\"'\\".contains($0) }) else { return arg }
            return "\"" + arg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: " ")
    }

    /// A command line split into arguments: spaces separate them, "…" and '…' quote, \ escapes the
    /// next character. No other shell syntax: `;`, `|`, `$` are plain text. Nil if a quote isn't closed.
    public static func arguments(fromCommandLine line: String) -> [String]? {
        var args: [String] = []
        var current = ""
        var inArgument = false
        var quote: Character?
        var escaped = false
        for c in line {
            if escaped {
                current.append(c)
                escaped = false
                continue
            }
            if c == "\\", quote != "'" {
                escaped = true
                inArgument = true
                continue
            }
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
                continue
            }
            if c == "\"" || c == "'" {
                quote = c
                inArgument = true
            } else if c == " " || c == "\t" {
                if inArgument { args.append(current) }
                current = ""
                inArgument = false
            } else {
                current.append(c)
                inArgument = true
            }
        }
        if quote != nil || escaped { return nil }
        if inArgument { args.append(current) }
        return args
    }
}

/// A file, folder or app found for `@open`.
public struct SearchResult: Equatable, Sendable {
    /// Shown in the panel ("Calculator", "报告.pdf").
    public var name: String
    public var path: String
    /// A folder (not an app bundle): Tab goes into it.
    public var isFolder: Bool
    /// Shown next to the name; what ⌘C copies instead of the path (a task's reply).
    public var detail: String?

    public init(name: String, path: String, isFolder: Bool = false, detail: String? = nil) {
        self.name = name
        self.path = path
        self.isFolder = isFolder
        self.detail = detail
    }

    /// A background task in the list (`@tasks`): its "path" names the session to open.
    public static let agentPrefix = "claude-agent:"
    public var agentID: String? { path.hasPrefix(Self.agentPrefix) ? String(path.dropFirst(Self.agentPrefix.count)) : nil }

    /// A web address in the list (`@open github.com`): opened in the default browser.
    public var webURL: URL? {
        guard path.hasPrefix("http://") || path.hasPrefix("https://") else { return nil }
        return URL(string: path)
    }

    /// The query as a web address to open, or nil: "https://…" and "www.…" always; a bare
    /// "name.tld/…" only for common top-level domains, so "report.pdf" or "Safari.app" stay file names.
    public static func web(_ query: String) -> SearchResult? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace), !text.hasPrefix("/"), !text.hasPrefix("~") else { return nil }
        let lower = text.lowercased()
        let explicit = lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")
        guard let url = WebReader.url(from: text), let host = url.host?.lowercased() else { return nil }
        if !explicit {
            guard let tld = host.split(separator: ".").last, commonDomains.contains(String(tld)) else { return nil }
        }
        return SearchResult(name: host + (url.path.count > 1 ? url.path : ""), path: url.absoluteString)
    }

    static let commonDomains: Set<String> = [
        "com", "org", "net", "io", "ai", "dev", "co", "me", "gov", "edu", "info", "xyz", "tech", "site", "so", "gg", "tv",
        "cn", "hk", "tw", "jp", "kr", "sg", "uk", "us", "ca", "au", "de", "fr", "eu", "in", "ru", "br",
    ]
}
