import Foundation

/// `@claude` in the background: Claude Code's own background sessions (`claude --bg`), followed with
/// `claude agents --json --all` until they are done, their last reply read from the session's
/// transcript. Claude Code keeps its own login, settings and permissions; this only starts, watches
/// and points at sessions.
public enum ClaudeAgents {
    /// The arguments that start `prompt` in the background (`--`: a prompt starting with "-" is still the prompt).
    public static func startArguments(_ prompt: String) -> [String] { ["--bg", "--", prompt] }
    public static let listArguments = ["agents", "--json", "--all"]

    /// The id `claude --bg` prints: "backgrounded · 9b90f24f".
    public static func startedID(in output: String) -> String? {
        let clean = output.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        guard let range = clean.range(of: #"backgrounded\s*·\s*([0-9a-f]{6,})"#, options: .regularExpression) else { return nil }
        return clean[range].components(separatedBy: CharacterSet(charactersIn: "· ")).last { !$0.isEmpty }
    }

    /// The background sessions in `claude agents --json --all`.
    public static func sessions(from data: Data) -> [AgentSession] {
        ((try? JSONDecoder().decode([AgentSession].self, from: data)) ?? []).filter { $0.kind == "background" }
    }

    /// The folder Claude Code keeps a working directory's transcripts in: "/Users/me" → "-Users-me".
    public static func projectFolder(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    public static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// The session's last reply (its last assistant text), from its transcript.
    public static func lastReply(sessionId: String, cwd: String?, root: URL = projectsRoot) -> String? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let cwd { candidates.append(root.appendingPathComponent(projectFolder(for: cwd)).appendingPathComponent("\(sessionId).jsonl")) }
        // Elsewhere if Claude Code names the folder differently.
        if let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            candidates += folders.map { $0.appendingPathComponent("\(sessionId).jsonl") }
        }
        guard let file = candidates.first(where: { fm.fileExists(atPath: $0.path) }),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var last: String?
        for line in text.split(separator: "\n") {
            guard line.contains("\"assistant\""),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let parts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            let joined = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { last = joined }
        }
        return last
    }
}

/// One session in `claude agents --json`.
public struct AgentSession: Codable, Equatable, Sendable {
    public var id: String?
    public var sessionId: String
    public var name: String?
    public var kind: String?
    public var status: String?
    /// "working", "done", or (we take it) waiting for the user in some way.
    public var state: String?
    public var startedAt: Double?
    public var cwd: String?

    public init(id: String? = nil, sessionId: String, name: String? = nil, kind: String? = "background",
                status: String? = nil, state: String? = nil, startedAt: Double? = nil, cwd: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.name = name
        self.kind = kind
        self.status = status
        self.state = state
        self.startedAt = startedAt
        self.cwd = cwd
    }

    /// The short id `claude attach` and the rest take.
    public var shortID: String { id ?? String(sessionId.prefix(8)) }

    public enum Progress: Equatable, Sendable {
        case working, done, needsYou
    }

    public var progress: Progress {
        switch state?.lowercased() {
        case "done", "completed", "finished": return .done
        case "working", "running", "starting", "queued", nil: return .working
        default: return .needsYou
        }
    }
}

/// The background tasks `@claude` started, until each is reported (done, or waiting for the user).
public struct AgentWatch: Codable, Equatable, Sendable {
    public struct Task: Codable, Equatable, Sendable {
        public var id: String
        public var prompt: String
        public var started: Date
        /// Already told the user it waits for them (once per wait).
        public var toldWaiting = false

        public init(id: String, prompt: String, started: Date = Date()) {
            self.id = id
            self.prompt = prompt
            self.started = started
        }
    }

    public enum Event: Equatable, Sendable {
        case done(Task, AgentSession)
        case needsYou(Task, AgentSession)
    }

    public var tasks: [Task] = []

    public init() {}

    public var isEmpty: Bool { tasks.isEmpty }

    public mutating func add(_ task: Task) { tasks.append(task) }

    /// What changed since the last look: done tasks are reported and dropped; a task waiting for the
    /// user is reported once per wait; a task no longer listed (removed) is dropped, as is one
    /// unseen for a day.
    public mutating func update(with sessions: [AgentSession], now: Date = Date()) -> [Event] {
        var events: [Event] = []
        var kept: [Task] = []
        for var task in tasks {
            guard let session = sessions.first(where: { $0.shortID == task.id || $0.sessionId.hasPrefix(task.id) }) else {
                if now.timeIntervalSince(task.started) < 60 { kept.append(task) }  // not listed yet: give it a minute
                continue
            }
            switch session.progress {
            case .done:
                events.append(.done(task, session))
            case .needsYou:
                if !task.toldWaiting { events.append(.needsYou(task, session)) }
                task.toldWaiting = true
                kept.append(task)
            case .working:
                task.toldWaiting = false
                if now.timeIntervalSince(task.started) < 86400 { kept.append(task) }
            }
        }
        tasks = kept
        return events
    }
}
