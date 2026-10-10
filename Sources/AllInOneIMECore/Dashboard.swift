import Foundation

// The floating panel's logic (「悬浮面板」, off by default: notes saved with @note, reminders added with
// @reminder, @claude's background tasks). The window and its sources are in the input method.

/// The panel's own record of the notes `@note` saved, newest first. Notes isn't read on a timer for
/// this: an Apple event to Notes launches it when it isn't running. Kept as JSON in the input
/// method's defaults (`savedNotes`).
public struct SavedNotes: Codable, Equatable, Sendable {
    public struct Note: Codable, Equatable, Sendable, Identifiable {
        /// Notes' identifier (`x-coredata://…`), to show the note.
        public var id: String
        /// Its first line, at most `SavedNotes.titleLength` characters.
        public var title: String
        /// When @note saved it.
        public var saved: Date

        public init(id: String, title: String, saved: Date) {
            self.id = id
            self.title = SavedNotes.title(title)
            self.saved = saved
        }
    }

    /// How many are kept, and how long a title may be.
    public static let limit = 30
    public static let titleLength = 80

    public private(set) var notes: [Note]

    public init(_ notes: [Note] = []) {
        self.notes = Array(notes.prefix(Self.limit))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode([Note].self, forKey: .notes))
    }

    /// The first line of `text` with something on it, trimmed, at most `titleLength` characters.
    public static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return String(line.prefix(titleLength))
    }

    /// A note @note just saved goes first; saved before (the same id), it moves up. The oldest beyond
    /// `limit` are forgotten.
    public mutating func add(id: String, title: String, at date: Date) {
        notes.removeAll { $0.id == id }
        notes.insert(Note(id: id, title: title, saved: date), at: 0)
        if notes.count > Self.limit { notes.removeLast(notes.count - Self.limit) }
    }

    public mutating func remove(id: String) {
        notes.removeAll { $0.id == id }
    }

    public func newest(_ count: Int) -> [Note] { Array(notes.prefix(max(count, 0))) }

    /// Takes in what Notes lists now (`NotesBridge.recent`: the folder's notes changed last, at most
    /// `limit`). Titles follow edits made in Notes. A note it doesn't list is dropped only when it
    /// would be listed if it were still there: the list is the whole folder (shorter than `limit`),
    /// or the note was saved after the oldest listed one last changed (a minute's margin: Notes
    /// stamps it a moment before @note reports it). Moved to another folder counts as gone.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func reconcile(with listed: [(id: String, title: String, modified: Date)], limit: Int) -> Bool {
        var titles: [String: String] = [:]
        for note in listed where titles[note.id] == nil { titles[note.id] = Self.title(note.title) }
        let wholeFolder = listed.count < limit
        let oldest = listed.map(\.modified).min()
        let before = notes
        notes = notes.compactMap { note in
            if let title = titles[note.id] {
                var note = note
                if !title.isEmpty { note.title = title }  // a note that starts with a picture has no name
                return note
            }
            let wouldBeListed = wholeFolder || oldest.map { note.saved.addingTimeInterval(-60) > $0 } == true
            return wouldBeListed ? nil : note
        }
        return notes != before
    }
}

/// The panel's wording made of numbers and dates, in Chinese or English: fixed wording like
/// `ReminderDraft.when`, since it sits next to the panel's own text.
public enum DashboardText {
    /// How long ago: 「刚刚」「5 分钟前」「2 小时前」「3 天前」 / "just now", "5 min ago", "2 hr ago",
    /// "3 days ago". A time ahead of `now` (another Mac's clock) is 「刚刚」.
    public static func ago(_ date: Date, now: Date, chinese: Bool) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let (minutes, hours, days) = (Int(seconds / 60), Int(seconds / 3600), Int(seconds / 86400))
        if minutes < 1 { return chinese ? "刚刚" : "just now" }
        if hours < 1 { return chinese ? "\(minutes) 分钟前" : "\(minutes) min ago" }
        if days < 1 { return chinese ? "\(hours) 小时前" : "\(hours) hr ago" }
        return chinese ? "\(days) 天前" : days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// The header's counts: 「3 个提醒 · 1 个任务进行中」 / "3 reminders · 1 task running". A zero is
    /// left out (nothing at all: empty); `moreReminders`: more than were read ("100+").
    public static func counts(reminders: Int, moreReminders: Bool = false, running: Int, chinese: Bool) -> String {
        var parts: [String] = []
        let shown = "\(reminders)" + (moreReminders ? "+" : "")
        if reminders > 0 {
            parts.append(chinese ? "\(shown) 个提醒" : reminders == 1 && !moreReminders ? "1 reminder" : "\(shown) reminders")
        }
        if running > 0 {
            parts.append(chinese ? "\(running) 个任务进行中" : running == 1 ? "1 task running" : "\(running) tasks running")
        }
        return parts.joined(separator: " · ")
    }

    /// The first line of `text` with something on it, as a one-line preview: without the Markdown
    /// marks a reply starts lines with (a heading's #, a list's -, a quote's >) and without bold and
    /// code marks. Nil when there is none.
    public static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let plain = line.replacingOccurrences(of: #"^\s*((#{1,6}|[-*+>]|\d+\.)\s+)+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !plain.isEmpty { return plain }
        }
        return nil
    }
}

/// Where the panel goes on the screens. Frames are in AppKit's screen coordinates (y grows upward);
/// `visible` frames are the screens' areas below the menu bar and beside the Dock.
public enum PanelPlacement {
    /// The top-right corner of `visible`, `margin` in from both edges.
    public static func topRight(_ size: CGSize, in visible: CGRect, margin: CGFloat = 12) -> CGRect {
        CGRect(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin,
               width: size.width, height: size.height)
    }

    /// `frame` moved (never resized) to lie on a screen: where it is when it does; else into the screen
    /// it overlaps most (the top kept when it's taller); else (that screen is gone) to the top right
    /// of the first screen.
    public static func onScreen(_ frame: CGRect, visible screens: [CGRect], margin: CGFloat = 12) -> CGRect {
        guard let first = screens.first else { return frame }
        if screens.contains(where: { $0.contains(frame) }) { return frame }
        let overlaps = screens.map { screen -> CGFloat in
            let common = screen.intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else {
            return topRight(frame.size, in: first, margin: margin)
        }
        let screen = screens[best]
        var moved = frame
        moved.origin.x = frame.width > screen.width ? screen.minX : min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        moved.origin.y = frame.height > screen.height ? screen.maxY - frame.height
                                                      : min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        return moved
    }
}

/// A background task as the panel lists it.
public struct AgentTaskRow: Equatable, Sendable, Identifiable {
    /// The short id, which opening it takes (`claude attach`).
    public var id: String
    /// Its name (else the prompt @claude started it with, else its id), on one line.
    public var title: String
    public var progress: AgentSession.Progress
    public var started: Date?
    /// The first line of its last reply.
    public var reply: String?

    public init(id: String, title: String, progress: AgentSession.Progress, started: Date?, reply: String?) {
        self.id = id
        self.title = title
        self.progress = progress
        self.started = started
        self.reply = reply
    }
}

public enum AgentTaskList {
    /// How many the panel shows.
    public static let limit = 6

    /// When the session started: `claude agents --json` gives milliseconds since 1970 (seconds are
    /// read too).
    public static func started(_ session: AgentSession) -> Date? {
        guard let value = session.startedAt, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }

    /// The newest `limit` sessions, newest first.
    public static func newest(_ sessions: [AgentSession], limit: Int = limit) -> [AgentSession] {
        let time = { (session: AgentSession) in started(session)?.timeIntervalSince1970 ?? 0 }
        return Array(sessions.sorted { time($0) > time($1) }.prefix(max(limit, 0)))
    }

    /// The rows of the newest sessions, with the replies read so far (session id → first line) and the
    /// prompts of the tasks @claude started (short id → prompt) for those Claude Code hasn't named yet.
    public static func rows(_ sessions: [AgentSession], replies: [String: String],
                            prompt: (String) -> String? = { _ in nil }) -> [AgentTaskRow] {
        newest(sessions).map { session in
            let title = [session.name, prompt(session.shortID)].lazy.compactMap { $0.map(oneLine) }.first { !$0.isEmpty }
            return AgentTaskRow(id: session.shortID, title: title ?? session.shortID, progress: session.progress,
                                started: started(session), reply: replies[session.sessionId])
        }
    }

    /// Runs of spaces and line breaks as one space.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

/// The last replies the panel shows, read from the transcripts (files that grow with the session)
/// only when they can have changed: once for a finished task, at every look for one still running
/// or waiting for the user.
public struct AgentReplyCache: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var progress: AgentSession.Progress
        var reply: String?
    }

    /// Session id → what was read.
    private var entries: [String: Entry] = [:]

    public init() {}

    /// Which of `sessions` to read (again).
    public func stale(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { session in
            guard let entry = entries[session.sessionId] else { return true }
            return !(entry.progress == .done && session.progress == .done)
        }
    }

    /// What was read for `sessions` (session id → the reply's first line; missing: none yet).
    public mutating func store(_ replies: [String: String], for sessions: [AgentSession]) {
        for session in sessions {
            entries[session.sessionId] = Entry(progress: session.progress, reply: replies[session.sessionId])
        }
    }

    /// Forgets the sessions not among `sessions` (no longer shown).
    public mutating func keep(only sessions: [AgentSession]) {
        let ids = Set(sessions.map(\.sessionId))
        entries = entries.filter { ids.contains($0.key) }
    }

    /// Session id → the reply's first line.
    public var replies: [String: String] { entries.compactMapValues(\.reply) }
}
