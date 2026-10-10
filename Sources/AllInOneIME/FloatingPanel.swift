import AllInOneIMECore
import AppKit
import Carbon
import EventKit
import SwiftUI

extension Notification.Name {
    /// The floating panel was turned on or off. userInfo: "enabled" (Bool). Main thread; the settings
    /// window's toggle follows `FloatingPanel.shared`'s.
    static let allInOneIMEFloatingPanelChanged = Notification.Name("AllInOneIMEFloatingPanelChanged")
    /// The interface language changed (`UIText.choice`): the floating panel redraws in it. Main thread.
    static let allInOneIMEInterfaceLanguageChanged = Notification.Name("AllInOneIMEInterfaceLanguageChanged")
}

/// What the panel remembers between launches (its frame, whether it's collapsed, the notes @note
/// saved): UserDefaults; memory in the self-test, which leaves the user's alone.
protocol PanelDefaults: AnyObject {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PanelDefaults {}

final class MemoryDefaults: PanelDefaults {
    private(set) var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// The notes @note saved (`SavedNotes`), as JSON under `savedNotes`.
enum SavedNotesStore {
    static let key = "savedNotes"

    static func load(_ defaults: PanelDefaults) -> SavedNotes {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SavedNotes.self, from: $0) } ?? SavedNotes()
    }

    static func save(_ notes: SavedNotes, to defaults: PanelDefaults) {
        if let data = try? JSONEncoder().encode(notes) { defaults.set(data, forKey: key) }
    }
}

/// Whether the panel may read the reminders: macOS's answer, never a question to the user.
enum ReminderAccess: Equatable {
    case allowed, notDetermined, denied

    /// As macOS has it now. EventKit: off the main thread.
    static var current: ReminderAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied  // denied, restricted, or write-only (which only events have)
        }
    }

    /// System Settings → Privacy & Security → Reminders.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
}

/// Whether this process may send Notes Apple events without asking the user (allowed before, in
/// System Settings → Privacy & Security → Automation). Asked of the system without a prompt; Notes
/// must be running. Off the main thread: it waits for the system's answer.
enum NotesAccess {
    static func allowedWithoutAsking() -> Bool {
        let notes = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes")
        return withExtendedLifetime(notes) {
            guard let target = notes.aeDesc else { return false }
            return AEDeterminePermissionToAutomateTarget(target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
                == OSStatus(noErr)
        }
    }
}

/// Where the panel's rows come from and what its clicks do. `live`: Notes, Reminders and Claude Code;
/// the self-test passes stand-ins, so nothing real is read, changed or opened. Everything is called
/// on the main thread; what would block it (Apple events, EventKit, processes, files) runs elsewhere.
struct DashboardSources {
    /// Whether Notes runs now: only then is it asked about the notes (an Apple event would launch it).
    var notesRunning: @MainActor () -> Bool
    /// The notes in the AllInOneIME folder (`NotesBridge.recent`); nil when that would need the user's
    /// permission first (the panel never asks on its own).
    var listNotes: @MainActor (_ limit: Int) async throws -> [NotesBridge.Note]?
    var showNote: @MainActor (_ id: String) async throws -> Void
    var reminderAccess: @MainActor () async -> ReminderAccess
    /// The reminders not done (`RemindersBridge.incomplete`), the soonest first. Asks the user when
    /// access isn't decided yet: only called then from the panel's button.
    var reminders: @MainActor (_ now: Date) async throws -> [RemindersBridge.Reminder]
    var completeReminder: @MainActor (_ id: String) async throws -> Void
    var openReminders: @MainActor () -> Void
    var openReminderSettings: @MainActor () -> Void
    /// The background sessions `claude agents --json --all` lists; nil when Claude Code isn't installed.
    var listAgents: @MainActor () async throws -> [AgentSession]?
    /// The first lines of the sessions' last replies (session id → line), from their transcripts.
    var lastReplies: @MainActor (_ sessions: [AgentSession]) async -> [String: String]
    /// Whether AgentMonitor looks at the tasks every few seconds now (its looks reach the panel).
    var monitorWatching: @MainActor () -> Bool
    /// The prompt @claude started a task with (short id), for one Claude Code hasn't named yet.
    var prompt: @MainActor (_ id: String) -> String?
    var openAgent: @MainActor (_ id: String) -> Void
    /// Writes the setting (`floatingPanel` in config.json) when the panel is turned on or off from the
    /// input menu or its close button.
    var saveSetting: @MainActor (_ on: Bool) -> Void
    var defaults: PanelDefaults
    var now: @MainActor () -> Date

    @MainActor static var live: DashboardSources {
        DashboardSources(
            notesRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty },
            listNotes: { limit in
                guard await Task.detached(priority: .utility, operation: { NotesAccess.allowedWithoutAsking() }).value else {
                    return nil
                }
                return try await NotesBridge.recent(limit: limit)
            },
            showNote: { try await NotesBridge.show(id: $0) },
            reminderAccess: { await Task.detached(priority: .utility) { ReminderAccess.current }.value },
            reminders: { try await RemindersBridge.incomplete(limit: FloatingPanel.reminderReadLimit, now: $0) },
            completeReminder: { try await RemindersBridge.complete(id: $0) },
            openReminders: { RemindersBridge.openApp() },
            openReminderSettings: { NSWorkspace.shared.open(ReminderAccess.settingsURL) },
            listAgents: {
                let claude = AgentMonitor.shared.claude
                return try await Task.detached(priority: .utility) { () -> [AgentSession]? in
                    // Where Terminal finds it, else on the login shell's PATH (read here, off the main thread).
                    guard TerminalLauncher.claudePath != nil
                            || CommandRunner.resolve("claude", path: ShellEnvironment.current["PATH"]) != nil else { return nil }
                    let output = try await AgentMonitor.run(claude, ClaudeAgents.listArguments)
                    return ClaudeAgents.sessions(from: Data(output.utf8))
                }.value
            },
            lastReplies: { sessions in
                await Task.detached(priority: .utility) {
                    var replies: [String: String] = [:]
                    for session in sessions {
                        let reply = ClaudeAgents.lastReply(sessionId: session.sessionId, cwd: session.cwd)
                        if let line = DashboardText.firstLine(reply) { replies[session.sessionId] = line }
                    }
                    return replies
                }.value
            },
            monitorWatching: { AgentMonitor.shared.isWatching },
            prompt: { AgentMonitor.shared.prompt(for: $0) },
            openAgent: { AgentMonitor.shared.open($0) },
            saveSetting: { FloatingPanel.saveSetting($0) },
            defaults: UserDefaults.standard,
            now: { Date() })
    }
}

/// The floating panel (「悬浮面板」, off by default): a small window that stays on screen with what
/// AllInOneIME started: the notes saved with @note, the reminders added with @reminder, @claude's
/// background tasks. It never takes focus from the app being typed in.
///
/// The setting `floatingPanel` turns it on and off: the settings window, the input menu and its own
/// close button. While it's on it listens for @note and @reminder (AppEvents), for EventKit's changes
/// and for AgentMonitor's looks at the tasks, reads the reminders again every 60 s, and asks Claude
/// Code itself every 15 s, but only while it's expanded and AgentMonitor isn't looking anyway. Notes
/// is asked (for edited titles and deleted notes) only when it's running already. Off, nothing of it
/// runs: no timers, no observers, no window.
@MainActor
final class FloatingPanel: ObservableObject {
    static let shared = FloatingPanel(sources: .live)

    static let width: CGFloat = 300
    static let headerHeight: CGFloat = 42
    static let maxHeight: CGFloat = 420
    static let notesShown = 5
    static let remindersShown = 8
    /// Read in full for the header's count (EventKit reads the whole list anyway); 8 are shown.
    static let reminderReadLimit = 100
    /// Asked of Notes when it runs (the script reads the whole folder anyway).
    static let noteListLimit = 200

    static let frameKey = "floatingPanelFrame"
    static let collapsedKey = "floatingPanelCollapsed"

    enum RemindersState: Equatable {
        case loading
        /// macOS hasn't asked the user yet: a button asks.
        case notDetermined
        /// Not allowed: a button opens System Settings.
        case denied
        /// Not done, the soonest first (all of them, up to `reminderReadLimit`; the first 8 are shown).
        case list([RemindersBridge.Reminder])
        case failed(String)
    }

    enum TasksState: Equatable {
        case loading
        case notInstalled
        case list([AgentTaskRow])
        case failed(String)
    }

    let sources: DashboardSources
    /// How often the reminders are read and Claude Code is asked (the self-test makes them shorter).
    var reminderInterval: TimeInterval = 60
    var agentInterval: TimeInterval = 15
    /// Called with the window once it's made (the self-test makes it invisible and click-through).
    var prepareWindow: (NSPanel) -> Void = { _ in }
    /// Looks are skipped while the window can't be seen (screen locked, display asleep). The
    /// self-test's invisible window never can, so it turns this off.
    var checksOcclusion = true

    @Published private(set) var isEnabled = false
    @Published private(set) var collapsed: Bool
    @Published private(set) var notes: [SavedNotes.Note] = []
    @Published private(set) var reminders: RemindersState = .loading
    /// Reminders being ticked off (their box is checked until they're gone from the list).
    @Published private(set) var completing: Set<String> = []
    @Published private(set) var tasks: TasksState = .loading
    /// What went wrong with a click, for a few seconds.
    @Published private(set) var message: String?
    /// The time the rows are shown for ("10 分钟前", "明天 15:00").
    @Published private(set) var now: Date
    /// The interface language it was drawn in: it redraws when that changes.
    @Published private(set) var chinese = UIText.chinese
    /// The lists' height, measured by the view: the window is as tall as they need, up to `maxHeight`.
    @Published var listHeight: CGFloat = 0 {
        didSet { if listHeight != oldValue { resize() } }
    }

    private(set) var window: DashboardWindow?
    private var observers: [NSObjectProtocol] = []
    private var reminderTimer: Timer?
    private var agentTimer: Timer?
    private var changeTimer: Timer?
    private var messageTimer: Timer?
    /// Counts the times it was turned on: what an earlier time started is dropped when it arrives.
    private var generation = 0
    private var readingReminders = false, readRemindersAgain = false
    private var askingAgents = false, readingReplies = false, readRepliesAgain = false, askingNotes = false
    /// What the last look at the tasks listed (AgentMonitor's or its own).
    private var sessions: [AgentSession]?
    private var replies = AgentReplyCache()
    /// The window was hidden from view (looks skipped meanwhile): caught up once it's seen again.
    private var unseen = false

    init(sources: DashboardSources) {
        self.sources = sources
        collapsed = sources.defaults.bool(forKey: Self.collapsedKey)
        now = sources.now()
    }

    // MARK: - On and off

    /// At launch (runServer): shown when the setting is on.
    func start(_ config: Config) {
        guard config.floatingPanel else { return }
        UIText.choice = config.uiLanguage  // the language it's drawn in, before any text field set it
        apply(true)
    }

    /// The input menu's item and the close button: turns it on or off and saves that in config.json.
    func setEnabled(_ on: Bool) {
        sources.saveSetting(on)
        apply(on)
    }

    /// Shows or hides it at once (the settings window saves the setting itself).
    func apply(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        generation += 1
        if on { open() } else { shut() }
        NotificationCenter.default.post(name: .allInOneIMEFloatingPanelChanged, object: self, userInfo: ["enabled": on])
        log.notice("floating panel \(on ? "on" : "off", privacy: .public)")
    }

    /// The close button: the setting goes off (the input menu turns it on again).
    func close() { setEnabled(false) }

    /// Whether anything of it still runs (the self-test checks that off means off).
    var isIdle: Bool {
        observers.isEmpty && reminderTimer == nil && agentTimer == nil && changeTimer == nil && window == nil
    }

    private func open() {
        chinese = UIText.chinese
        now = sources.now()
        notes = SavedNotesStore.load(sources.defaults).newest(Self.notesShown)
        (reminders, tasks, completing, message, sessions, replies) = (.loading, .loading, [], nil, nil, AgentReplyCache())
        unseen = false
        let window = makeWindow()
        place(window)
        window.orderFrontRegardless()
        observe(window)
        reminderTimer = repeating(reminderInterval) { $0.tick() }
        scheduleAgents()
        refreshReminders()
        lookAtTasks(force: true)  // once, for the header's count even when collapsed
        refreshNoteTitles()
    }

    private func shut() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        for timer in [reminderTimer, agentTimer, changeTimer, messageTimer] { timer?.invalidate() }
        (reminderTimer, agentTimer, changeTimer, messageTimer) = (nil, nil, nil, nil)
        window?.orderOut(nil)
        window = nil
        (readingReminders, readRemindersAgain, askingAgents, askingNotes) = (false, false, false, false)
        (readingReplies, readRepliesAgain) = (false, false)
    }

    /// Writes the setting into config.json (a file that doesn't parse is left as it is).
    static func saveSetting(_ on: Bool) {
        do {
            var config = try Config.load()
            guard config.floatingPanel != on else { return }
            config.floatingPanel = on
            try config.write()
        } catch {
            log.error("could not save the floating panel setting: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - The window

    private func makeWindow() -> DashboardWindow {
        let window = DashboardWindow()
        let host = DashboardHostingView(rootView: FloatingPanelView(panel: self))
        host.sizingOptions = []  // sized here, keeping its top edge in place
        window.contentView = host
        prepareWindow(window)
        self.window = window
        return window
    }

    /// The window's height now: the header, and the lists up to `maxHeight`.
    var height: CGFloat {
        collapsed ? Self.headerHeight : min(Self.headerHeight + 1 + listHeight, Self.maxHeight)
    }

    /// Where it was left (its top-left corner), else the top right of the screen with the menu bar.
    private func place(_ window: NSWindow) {
        let size = CGSize(width: Self.width, height: height)
        var frame: CGRect
        if let saved = sources.defaults.string(forKey: Self.frameKey).map(NSRectFromString), saved.width > 0 {
            frame = CGRect(x: saved.minX, y: saved.maxY - size.height, width: size.width, height: size.height)
        } else {
            let screen = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
            frame = PanelPlacement.topRight(size, in: screen)
        }
        window.setFrame(PanelPlacement.onScreen(frame, visible: NSScreen.screens.map(\.visibleFrame)), display: false)
    }

    /// To the height the lists need, its top edge in place (moved up if it would leave the screen).
    private func resize() {
        guard let window else { return }
        let frame = CGRect(x: window.frame.minX, y: window.frame.maxY - height, width: Self.width, height: height)
        let placed = PanelPlacement.onScreen(frame, visible: NSScreen.screens.map(\.visibleFrame))
        guard placed != window.frame else { return }
        window.setFrame(placed, display: true)
        window.invalidateShadow()
    }

    /// Back on a screen after the displays changed (one was unplugged, the resolution changed).
    private func moveOnScreen() {
        guard let window else { return }
        let placed = PanelPlacement.onScreen(window.frame, visible: NSScreen.screens.map(\.visibleFrame))
        if placed != window.frame { window.setFrame(placed, display: true) }
    }

    private var isOnScreen: Bool {
        guard let window, window.isVisible else { return false }
        return !checksOcclusion || window.occlusionState.contains(.visible)
    }

    func toggleCollapsed() {
        collapsed.toggle()
        sources.defaults.set(collapsed, forKey: Self.collapsedKey)
        resize()
        scheduleAgents()
        if !collapsed {
            now = sources.now()
            lookAtTasks(force: false)
            refreshNoteTitles()
        }
    }

    // MARK: - Listening and looking

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ object: AnyObject? = nil, _ handle: @escaping (FloatingPanel, Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, self.isEnabled else { return }
                    handle(self, note)
                }
            })
        }
        on(.allInOneIMENoteSaved) { $0.noteSaved($1.userInfo) }
        on(.allInOneIMEReminderAdded) { panel, _ in panel.refreshReminders() }
        // Reminders changed anywhere (the Reminders app, another Mac); they come in bursts.
        on(.EKEventStoreChanged) { panel, _ in panel.remindersChanged() }
        on(.allInOneIMEAgentsPolled) { panel, note in
            if let sessions = note.userInfo?["sessions"] as? [AgentSession] { panel.show(sessions) }
        }
        on(NSApplication.didChangeScreenParametersNotification) { panel, _ in panel.moveOnScreen() }
        on(.allInOneIMEInterfaceLanguageChanged) { panel, _ in panel.chinese = UIText.chinese }
        on(NSWindow.didMoveNotification, window) { panel, _ in
            if let frame = panel.window?.frame { panel.sources.defaults.set(NSStringFromRect(frame), forKey: Self.frameKey) }
        }
        // Seen again after a while unseen (the screen unlocked, the display awake): what changed meanwhile.
        on(NSWindow.didChangeOcclusionStateNotification, window) { panel, _ in
            guard panel.isOnScreen else {
                panel.unseen = true
                return
            }
            guard panel.unseen else { return }
            panel.unseen = false
            panel.tick()
            if !panel.collapsed { panel.lookAtTasks(force: false) }
        }
    }

    private func repeating(_ interval: TimeInterval, _ work: @escaping (FloatingPanel) -> Void) -> Timer {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { work(self) } }
        }
        timer.tolerance = interval / 10
        return timer
    }

    /// Every 60 s: the reminders (also when collapsed: the header counts them), the times shown, and
    /// the notes' titles when Notes runs.
    private func tick() {
        guard isOnScreen else { return }
        now = sources.now()
        refreshReminders()
        if !collapsed { refreshNoteTitles() }
    }

    /// Its own looks at the tasks, every 15 s while it's expanded (skipped while AgentMonitor looks).
    private func scheduleAgents() {
        let wanted = isEnabled && !collapsed
        if wanted, agentTimer == nil {
            agentTimer = repeating(agentInterval) { panel in
                if panel.isOnScreen { panel.lookAtTasks(force: false) }
            }
        } else if !wanted {
            agentTimer?.invalidate()
            agentTimer = nil
        }
    }

    /// The refresh button: everything, now.
    func refresh() {
        now = sources.now()
        notes = SavedNotesStore.load(sources.defaults).newest(Self.notesShown)
        refreshReminders()
        lookAtTasks(force: true)
        refreshNoteTitles()
    }

    // MARK: - Notes

    private func noteSaved(_ info: [AnyHashable: Any]?) {
        guard let id = info?["id"] as? String, !id.isEmpty else { return }
        var saved = SavedNotesStore.load(sources.defaults)
        saved.add(id: id, title: info?["title"] as? String ?? "", at: sources.now())
        SavedNotesStore.save(saved, to: sources.defaults)
        now = sources.now()
        notes = saved.newest(Self.notesShown)
        log.notice("floating panel: a note was saved (\(saved.notes.count) kept)")
    }

    /// Titles edited in Notes, notes deleted there: asked only when Notes runs already, and only with
    /// its permission given before.
    private func refreshNoteTitles() {
        guard !askingNotes, !SavedNotesStore.load(sources.defaults).notes.isEmpty, sources.notesRunning() else { return }
        askingNotes = true
        let generation = self.generation
        Task { [weak self] in
            let listed: [NotesBridge.Note]?
            do {
                listed = try await self?.sources.listNotes(Self.noteListLimit) ?? nil
            } catch {
                listed = nil
                log.error("floating panel: Notes didn't list the notes: \(String(describing: error), privacy: .public)")
            }
            guard let self, generation == self.generation else { return }
            self.askingNotes = false
            guard let listed else { return }
            var saved = SavedNotesStore.load(self.sources.defaults)
            if saved.reconcile(with: listed.map { ($0.id, $0.title, $0.modified) }, limit: Self.noteListLimit) {
                SavedNotesStore.save(saved, to: self.sources.defaults)
                log.notice("floating panel: \(saved.notes.count) notes after asking Notes")
            }
            self.notes = saved.newest(Self.notesShown)
        }
    }

    /// Shows the note in Notes; a note that's gone is dropped once Notes (running now) lists the folder.
    func open(_ note: SavedNotes.Note) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sources.showNote(note.id)
            } catch let error as NotesBridge.NotesError where error == .notPermitted {
                self.say(UIText.describe(error))
            } catch {
                log.error("floating panel: could not show a note: \(String(describing: error), privacy: .public)")
                self.say(tr("打不开这条笔记", "Couldn't open this note"))
            }
            self.refreshNoteTitles()
        }
    }

    // MARK: - Reminders

    private func remindersChanged() {
        changeTimer?.invalidate()
        changeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.changeTimer = nil
                self?.refreshReminders()
            }
        }
    }

    /// Reads them if allowed (never asks: when macOS hasn't asked the user yet, a button does).
    private func refreshReminders() {
        guard !readingReminders else {
            readRemindersAgain = true
            return
        }
        readingReminders = true
        let generation = self.generation
        Task { [weak self] in
            guard let self else { return }
            let state: RemindersState
            switch await self.sources.reminderAccess() {
            case .notDetermined: state = .notDetermined
            case .denied: state = .denied
            case .allowed:
                do {
                    state = .list(try await self.sources.reminders(self.sources.now()))
                } catch RemindersBridge.RemindersError.notPermitted {
                    state = .denied
                } catch {
                    log.error("floating panel: could not read the reminders: \(String(describing: error), privacy: .public)")
                    state = .failed(UIText.describe(error))
                }
            }
            guard generation == self.generation else { return }
            self.readingReminders = false
            self.reminders = state
            if case let .list(items) = state { self.completing.formIntersection(items.map(\.id)) }
            if self.readRemindersAgain {
                self.readRemindersAgain = false
                self.refreshReminders()
            }
        }
    }

    /// The button 「允许读取提醒事项」: macOS asks the user now.
    func requestReminderAccess() {
        let generation = self.generation
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sources.reminders(self.sources.now())
            } catch {
                log.notice("floating panel: reminders not allowed: \(String(describing: error), privacy: .public)")
            }
            if generation == self.generation { self.refreshReminders() }
        }
    }

    func openReminderSettings() { sources.openReminderSettings() }

    func openReminders() { sources.openReminders() }

    /// The checkbox: ticks it off in Reminders; its box stays checked until it's gone from the list.
    func complete(_ reminder: RemindersBridge.Reminder) {
        guard !completing.contains(reminder.id) else { return }
        completing.insert(reminder.id)
        let generation = self.generation
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sources.completeReminder(reminder.id)
                log.notice("floating panel: a reminder was completed")
            } catch {
                log.error("floating panel: could not complete a reminder: \(String(describing: error), privacy: .public)")
                self.completing.remove(reminder.id)
                self.say(UIText.describe(error))
            }
            if generation == self.generation { self.refreshReminders() }
        }
    }

    // MARK: - Claude Code

    /// Asks Claude Code for the tasks, unless AgentMonitor looks every few seconds anyway (`force`:
    /// asks all the same, as when shown or refreshed by hand).
    private func lookAtTasks(force: Bool) {
        if !force, sources.monitorWatching(), let sessions {
            readReplies(of: AgentTaskList.newest(sessions))
            return
        }
        guard !askingAgents else { return }
        askingAgents = true
        let generation = self.generation
        Task { [weak self] in
            guard let self else { return }
            let result: Result<[AgentSession]?, Error>
            do { result = .success(try await self.sources.listAgents()) } catch { result = .failure(error) }
            guard generation == self.generation else { return }
            self.askingAgents = false
            switch result {
            case .success(nil):
                self.tasks = .notInstalled
            case let .success(sessions?):
                self.show(sessions)
            case let .failure(error):
                // Not the error's text: Claude Code's message may quote a task.
                log.error("floating panel: could not list the background tasks")
                // A list shown before stays up: the next look may work again.
                if case .list = self.tasks {} else { self.tasks = .failed(UIText.describe(error)) }
            }
        }
    }

    /// A look at the tasks (its own or AgentMonitor's): the newest 6, with the replies read so far;
    /// those that can have changed are read again while it's expanded.
    private func show(_ sessions: [AgentSession]) {
        self.sessions = sessions
        let newest = AgentTaskList.newest(sessions)
        replies.keep(only: newest)
        tasks = .list(AgentTaskList.rows(newest, replies: replies.replies, prompt: sources.prompt))
        if !collapsed { readReplies(of: newest) }
    }

    private func readReplies(of newest: [AgentSession]) {
        guard !readingReplies else {
            readRepliesAgain = true
            return
        }
        let stale = replies.stale(newest)
        guard !stale.isEmpty else { return }
        readingReplies = true
        let generation = self.generation
        Task { [weak self] in
            guard let self else { return }
            let read = await self.sources.lastReplies(stale)
            guard generation == self.generation else { return }
            self.readingReplies = false
            self.replies.store(read, for: stale)
            if let sessions = self.sessions {
                let newest = AgentTaskList.newest(sessions)
                self.tasks = .list(AgentTaskList.rows(newest, replies: self.replies.replies, prompt: self.sources.prompt))
                if self.readRepliesAgain {
                    self.readRepliesAgain = false
                    if !self.collapsed { self.readReplies(of: newest) }
                }
            }
        }
    }

    func open(_ task: AgentTaskRow) { sources.openAgent(task.id) }

    // MARK: - What the header and the rows say

    /// 「3 个提醒 · 1 个任务进行中」 (nothing when there's nothing).
    var counts: String {
        var reminderCount = 0, more = false
        if case let .list(items) = reminders {
            reminderCount = items.count
            more = items.count >= Self.reminderReadLimit
        }
        var running = 0
        if case let .list(rows) = tasks { running = rows.filter { $0.progress != .done }.count }
        return DashboardText.counts(reminders: reminderCount, moreReminders: more, running: running, chinese: UIText.chinese)
    }

    /// When a reminder is due, as @reminder says it (nil without a date).
    func due(_ reminder: RemindersBridge.Reminder) -> String? {
        guard reminder.due != nil else { return nil }
        return UIText.when(ReminderDraft(title: reminder.title, due: reminder.due, hasTime: reminder.hasTime), now: now)
    }

    /// The checkbox's VoiceOver label: 「完成「交房租」」 / "Complete “Pay the rent”".
    static func completeLabel(_ title: String) -> String {
        tr("完成「\(title)」", "Complete \u{201C}\(title)\u{201D}")
    }

    static func progressName(_ progress: AgentSession.Progress) -> String {
        switch progress {
        case .working: return tr("进行中", "running")
        case .done: return tr("完成了", "done")
        case .needsYou: return tr("在等你", "waiting for you")
        }
    }

    private func say(_ text: String) {
        message = text
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.message = nil
                self?.messageTimer = nil
            }
        }
    }
}

/// The floating panel's window: it never takes focus from the app being typed in (it can't become
/// key or main, and clicking it doesn't activate the input method), floats on every Space and over
/// full-screen apps, and moves when dragged by its background.
final class DashboardWindow: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: FloatingPanel.width, height: FloatingPanel.headerHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        title = "AllInOneIME"  // for VoiceOver; a borderless window shows none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Clicks reach the buttons at once, in a window that's never key.
final class DashboardHostingView: NSHostingView<FloatingPanelView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// What the floating panel shows: a header with the counts and three buttons, then the notes, the
/// reminders and the Claude tasks. Follows light and dark mode and the interface language (`tr`).
struct FloatingPanelView: View {
    @ObservedObject var panel: FloatingPanel

    private static let cornerRadius: CGFloat = 12

    var body: some View {
        let _ = panel.chinese  // drawn again in the other language
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            header
            if !panel.collapsed {
                Divider()
                ScrollView(.vertical) {
                    lists.background(GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                    })
                }
                .frame(height: max(0, min(panel.listHeight, FloatingPanel.maxHeight - FloatingPanel.headerHeight - 1)))
            }
        }
        .frame(width: FloatingPanel.width)
        .background(shape.fill(Color(nsColor: CandidateView.background)))
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .clipShape(shape)
        .onPreferenceChange(ListHeightKey.self) { height in
            // Collapsed, the lists are gone: their height is kept for when they're back.
            MainActor.assumeIsolated { if !panel.collapsed { panel.listHeight = height } }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AllInOneIME").font(.system(size: 12, weight: .semibold))
                let counts = panel.counts
                if !counts.isEmpty {
                    Text(counts).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            headerButton("arrow.clockwise", tr("刷新", "Refresh")) { panel.refresh() }
            headerButton(panel.collapsed ? "chevron.down" : "chevron.up",
                         panel.collapsed ? tr("展开", "Expand") : tr("收起", "Collapse")) { panel.toggleCollapsed() }
            headerButton("xmark", tr("关闭悬浮面板", "Close Floating Panel")) { panel.close() }
        }
        .padding(.horizontal, 12)
        .frame(height: FloatingPanel.headerHeight)
    }

    private func headerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Lists

    private var lists: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = panel.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            section(tr("备忘录", "Notes"), CommandIcons.icon(for: .note)) { notes }
            section(tr("提醒事项", "Reminders"), CommandIcons.icon(for: .reminder)) { reminders }
            section(tr("Claude 任务", "Claude Tasks"), CommandIcons.icon(for: .claude)) { tasks }
        }
        .frame(maxWidth: .infinity, alignment: .leading)  // short lines (the empty ones) stay on the left
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var notes: some View {
        if panel.notes.isEmpty {
            line(tr("用 @note 存的笔记会显示在这里", "Notes saved with @note show up here"))
        }
        ForEach(panel.notes) { note in
            let title = note.title.isEmpty ? tr("（无标题）", "(Untitled)") : note.title
            Button { panel.open(note) } label: {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(DashboardText.ago(note.saved, now: panel.now, chinese: UIText.chinese))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(tr("在备忘录里打开", "Opens it in Notes"))
        }
    }

    @ViewBuilder
    private var reminders: some View {
        switch panel.reminders {
        case .loading:
            line(tr("正在读取…", "Loading…"))
        case .notDetermined:
            line(tr("要列出提醒事项，需要你允许 AllInOneIME 读取。", "To list your reminders, AllInOneIME needs your permission."))
            Button(tr("允许读取提醒事项", "Allow Access to Reminders")) { panel.requestReminderAccess() }
                .buttonStyle(.link).font(.system(size: 12))
        case .denied:
            HStack(spacing: 6) {
                line(tr("没有读取提醒事项的权限", "No access to Reminders"))
                Spacer(minLength: 4)
                Button(tr("打开系统设置", "Open System Settings")) { panel.openReminderSettings() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        case let .failed(text):
            Text(text).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case let .list(items) where items.isEmpty:
            line(tr("用 @reminder 加的提醒会显示在这里", "Reminders added with @reminder show up here"))
        case let .list(items):
            ForEach(items.prefix(FloatingPanel.remindersShown), id: \.id) { reminder in reminderRow(reminder) }
            if items.count > FloatingPanel.remindersShown {
                let more = items.count - FloatingPanel.remindersShown
                Button { panel.openReminders() } label: {
                    Text(items.count >= FloatingPanel.reminderReadLimit ? tr("还有更多…", "More…") : tr("还有 \(more) 个…", "\(more) more…"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityHint(tr("打开提醒事项", "Opens Reminders"))
            }
        }
    }

    private func reminderRow(_ reminder: RemindersBridge.Reminder) -> some View {
        let done = panel.completing.contains(reminder.id)
        let due = panel.due(reminder)
        return HStack(spacing: 6) {
            Button { panel.complete(reminder) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(done ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(FloatingPanel.completeLabel(reminder.title))
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(done ? tr("已完成", "completed") : "")
            Button { panel.openReminders() } label: {
                HStack(spacing: 6) {
                    Text(reminder.title).font(.system(size: 13)).lineLimit(1)
                        .foregroundStyle(done ? Color.secondary : Color.primary)
                    Spacer(minLength: 6)
                    if let due {
                        Text(due).font(.system(size: 11)).lineLimit(1)
                            .foregroundStyle(reminder.overdue ? Color.red : Color.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.title + (due.map { tr("，", ", ") + $0 } ?? ""))
            .accessibilityHint(tr("打开提醒事项", "Opens Reminders"))
        }
    }

    @ViewBuilder
    private var tasks: some View {
        switch panel.tasks {
        case .loading:
            line(tr("正在读取…", "Loading…"))
        case .notInstalled:
            line(tr("没有安装 Claude Code（找不到 claude 命令）", "Claude Code isn't installed (no claude command)"))
        case let .failed(text):
            Text(text).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3)
        case let .list(rows) where rows.isEmpty:
            line(tr("用 @claude 交给后台的任务会显示在这里", "Tasks @claude runs in the background show up here"))
        case let .list(rows):
            ForEach(rows) { row in taskRow(row) }
        }
    }

    private func taskRow(_ row: AgentTaskRow) -> some View {
        let ago = row.started.map { DashboardText.ago($0, now: panel.now, chinese: UIText.chinese) }
        return Button { panel.open(row) } label: {
            HStack(alignment: .top, spacing: 8) {
                IconView(icon: CommandIcons.icon(for: row.progress), size: 16).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.title).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 6)
                        if let ago { Text(ago).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    if let reply = row.reply {
                        Text(reply).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.title, FloatingPanel.progressName(row.progress), ago, row.reply].compactMap { $0 }
            .joined(separator: tr("，", ", ")))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(tr("在终端里打开", "Opens it in Terminal"))
    }

    // MARK: Parts

    private func section<Content: View>(_ title: String, _ icon: CandidateView.Icon,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                IconView(icon: icon, size: 16)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A symbol drawn white on a colored rounded square, like the command list's icons.
private struct IconView: View {
    let icon: CandidateView.Icon
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: icon.symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(Color(nsColor: icon.color)))
            .accessibilityHidden(true)
    }
}
