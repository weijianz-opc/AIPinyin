import AllInOneIMECore
import AppKit

/// Stand-ins for everything the floating panel reads and opens: sample data, and a record of what it
/// asked for. Nothing reaches Notes, EventKit or Claude Code; the setting, the frame and the saved
/// notes stay in memory.
@MainActor
final class PanelStandIns {
    var now = Date()
    var notesRunning = false
    /// What Notes would list (nil: not allowed without asking).
    var listedNotes: [NotesBridge.Note]?
    var access = ReminderAccess.allowed
    /// The user's answer when the panel's button has macOS ask.
    var answer = ReminderAccess.allowed
    var reminders: [RemindersBridge.Reminder] = []
    /// What `claude agents` lists (nil: Claude Code isn't installed).
    var sessions: [AgentSession]? = []
    var replies: [String: String] = [:]
    var monitorWatching = false
    let defaults = MemoryDefaults()

    private(set) var noteLists = 0, reminderReads = 0, agentLooks = 0, replyReads = 0
    private(set) var shownNotes: [String] = [], completed: [String] = [], openedAgents: [String] = []
    private(set) var openedReminders = 0, openedSettings = 0
    private(set) var savedSetting: [Bool] = []

    var sources: DashboardSources {
        DashboardSources(
            notesRunning: { self.notesRunning },
            listNotes: { _ in
                self.noteLists += 1
                return self.listedNotes
            },
            showNote: { self.shownNotes.append($0) },
            reminderAccess: { self.access },
            reminders: { _ in
                self.reminderReads += 1
                if self.access == .notDetermined { self.access = self.answer }  // macOS asked
                guard self.access == .allowed else { throw RemindersBridge.RemindersError.notPermitted }
                return self.reminders
            },
            completeReminder: { id in
                self.completed.append(id)
                self.reminders.removeAll { $0.id == id }
            },
            openReminders: { self.openedReminders += 1 },
            openReminderSettings: { self.openedSettings += 1 },
            listAgents: {
                self.agentLooks += 1
                return self.sessions
            },
            lastReplies: { sessions in
                self.replyReads += 1
                return self.replies.filter { id, _ in sessions.contains { $0.sessionId == id } }
            },
            monitorWatching: { self.monitorWatching },
            prompt: { _ in nil },
            openAgent: { self.openedAgents.append($0) },
            saveSetting: { self.savedSetting.append($0) },
            defaults: defaults,
            now: { self.now })
    }

    /// Neutral sample data (README images are public), as of a fixed time so the images stay the same:
    /// two notes, a reminder that is overdue and one tomorrow, a task in progress and one done.
    func sample(chinese: Bool) {
        let calendar = ReminderParser.localCalendar
        now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9, minute: 41))!
        reminders = [
            RemindersBridge.Reminder(id: "rent", title: chinese ? "交房租" : "Pay the rent",
                                     due: DateComponents(year: 2026, month: 10, day: 15), hasTime: false, overdue: true),
            RemindersBridge.Reminder(id: "call", title: chinese ? "给张三打电话" : "Call Alex",
                                     due: DateComponents(year: 2026, month: 10, day: 18, hour: 15, minute: 0), hasTime: true,
                                     overdue: false),
        ]
        let ms = now.timeIntervalSince1970 * 1000
        let language = chinese ? "zh" : "en"  // other sessions for the other language (their replies are read anew)
        sessions = [
            AgentSession(id: "a1b2c3d4", sessionId: "a1b2c3d4-\(language)", name: chinese ? "重构登录模块" : "Refactor the login module",
                         state: "working", startedAt: ms - 25 * 60_000),
            AgentSession(id: "e5f6a7b8", sessionId: "e5f6a7b8-\(language)", name: chinese ? "写单元测试" : "Write unit tests",
                         state: "done", startedAt: ms - 2 * 3_600_000),
        ]
        replies = ["a1b2c3d4-\(language)": chinese ? "正在拆分 LoginService，已改完 3 个文件" : "Splitting LoginService: 3 files done so far",
                   "e5f6a7b8-\(language)": chinese ? "写好了 12 个单元测试，全部通过" : "Added 12 unit tests; all of them pass"]
        var notes = SavedNotes()
        notes.add(id: "x-coredata://sample/p2", title: chinese ? "买牛奶和鸡蛋" : "Buy milk and eggs", at: now - 3 * 3600)
        notes.add(id: "x-coredata://sample/p1", title: chinese ? "周会要点" : "Weekly meeting notes", at: now - 10 * 60)
        SavedNotesStore.save(notes, to: defaults)
    }
}

extension SelfTest {
    /// The floating panel with stand-ins for every source: what it lists and does on a click, that it
    /// never takes focus, its timers and notices, permissions, the setting (menu, settings window,
    /// close button), and that off means off; with the README render, Chinese and English.
    static func testFloatingPanel(_ controller: AllInOneIMEInputController, snapshotDirectory: URL) {
        print("— floating panel (stand-ins for Notes, Reminders and Claude Code)")
        let realConfig = try? Data(contentsOf: Config.defaultURL)
        let stand = PanelStandIns()
        stand.sample(chinese: true)
        let panel = FloatingPanel(sources: stand.sources)
        panel.prepareWindow = { window in
            // Invisible and click-through (someone may be using this Mac); renders draw the view directly.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
        panel.checksOcclusion = false  // an invisible window never counts as seen
        let (menuPanel, language) = (controller.floatingPanel, UIText.choice)
        controller.floatingPanel = { panel }
        defer {
            panel.apply(false)
            controller.floatingPanel = menuPanel
            UIText.choice = language
        }
        func loaded() -> Bool {
            guard case let .list(items) = panel.reminders, !items.isEmpty, case let .list(rows) = panel.tasks else { return false }
            return rows.allSatisfy { $0.reply != nil }
        }
        func menuItem() -> NSMenuItem? {
            controller.menu()?.items.first { $0.action == #selector(AllInOneIMEInputController.toggleFloatingPanel(_:)) }
        }
        func post(_ name: Notification.Name, _ info: [AnyHashable: Any]? = nil) {
            NotificationCenter.default.post(name: name, object: nil, userInfo: info)
        }
        func reminderIDs() -> [String] {
            if case let .list(items) = panel.reminders { return items.map(\.id) }
            return []
        }
        func taskRows() -> [AgentTaskRow] {
            if case let .list(rows) = panel.tasks { return rows }
            return []
        }

        // Off by default: no window, nothing runs.
        var config = settings
        config.floatingPanel = false
        panel.start(config)
        check(!Config.default.floatingPanel && !panel.isEnabled && panel.isIdle, "off by default: no window, no timers, no observers")
        let item = menuItem()
        check(item?.title == "显示悬浮面板" && item?.state == .off, "the input menu offers 「\(item?.title ?? "-")」, unchecked")

        // The menu item turns it on: shown at once, the setting saved (in memory here).
        let wasActive = NSApp.isActive
        controller.toggleFloatingPanel(item)
        check(panel.isEnabled && panel.window?.isVisible == true && stand.savedSetting == [true] && menuItem()?.state == .on,
              "「显示悬浮面板」 shows it, saves the setting and is checked")
        check(pump(timeout: 3) { loaded() }, "it reads the stand-ins")
        if let window = panel.window {
            window.makeKey()
            check(window.styleMask.contains(.nonactivatingPanel) && window.becomesKeyOnlyIfNeeded && !window.canBecomeKey
                  && !window.canBecomeMain && !window.isKeyWindow && NSApp.isActive == wasActive,
                  "non-activating: it can't become key or main, and the app being typed in keeps the focus")
            check(window.level == .floating && window.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary])
                  && !window.hidesOnDeactivate && window.isMovableByWindowBackground,
                  "floats on every Space and over full-screen apps, movable by its background")
            _ = pump(timeout: 0.5) { window.frame.height == panel.height && panel.listHeight > 0 }
            let screen = NSScreen.screens.first?.visibleFrame ?? .zero
            check(abs(window.frame.maxX - (screen.maxX - 12)) < 1 && abs(window.frame.maxY - (screen.maxY - 12)) < 1
                  && window.frame.width == 300 && window.frame.height == panel.height && panel.height <= 420,
                  "first time: top right, under the menu bar, \(Int(window.frame.width)) × \(Int(window.frame.height)) pt")
        }
        check(panel.notes.map(\.title) == ["周会要点", "买牛奶和鸡蛋"], "notes from the store, newest first: \(panel.notes.map(\.title))")
        if case let .list(items) = panel.reminders, items.count == 2 {
            let due = items.map { panel.due($0) ?? "" }
            check(items.map(\.title) == ["交房租", "给张三打电话"] && due[0].hasPrefix("10月15日") && due[1].hasPrefix("明天")
                  && items[0].overdue, "reminders, due first, the overdue one red: \(zip(items.map(\.title), due).map { "\($0) · \($1)" })")
        } else {
            check(false, "reminders: \(panel.reminders)")
        }
        let rows = taskRows()
        check(rows.map(\.title) == ["重构登录模块", "写单元测试"] && rows.map(\.progress) == [.working, .done]
              && rows.map { $0.reply ?? "" } == ["正在拆分 LoginService，已改完 3 个文件", "写好了 12 个单元测试，全部通过"],
              "Claude tasks, newest first, with their last replies")
        check(panel.counts == "2 个提醒 · 1 个任务进行中", "header: \(panel.counts)")

        // README: the expanded panel, light, Chinese and English (the same sample in English).
        func render(_ name: String) {
            guard let window = panel.window, let view = window.contentView else { return check(false, "no window to render") }
            window.appearance = NSAppearance(named: .aqua)
            defer { window.appearance = nil }
            _ = pump(timeout: 0.5) { false }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = snapshotDirectory.appendingPathComponent("\(name).png")
            if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil {
                print("  snapshot \(url.path) (\(Int(view.bounds.width))×\(Int(view.bounds.height)))")
            }
        }
        render("14-dashboard")
        UIText.choice = .english
        stand.sample(chinese: false)
        panel.refresh()
        check(pump(timeout: 3) { loaded() && taskRows().first?.title == "Refactor the login module" && panel.notes.first?.title == "Weekly meeting notes" }
              && !panel.chinese, "the English interface, at once")
        check(panel.counts == "2 reminders · 1 task running" && FloatingPanel.completeLabel("Pay the rent") == "Complete \u{201C}Pay the rent\u{201D}",
              "English header and VoiceOver labels: \(panel.counts)")
        render("14-dashboard-en")
        UIText.choice = .chinese
        stand.sample(chinese: true)
        panel.refresh()
        _ = pump(timeout: 3) { loaded() && taskRows().first?.title == "重构登录模块" && panel.notes.first?.title == "周会要点" }
        check(panel.chinese && FloatingPanel.completeLabel("交房租") == "完成「交房租」", "back to Chinese; the checkbox says 「完成「交房租」」")

        // Clicks: a checkbox completes the reminder (the stand-in), a row opens what it shows.
        if case let .list(items) = panel.reminders, let rent = items.first {
            panel.complete(rent)
            check(panel.completing.contains(rent.id), "the box is checked at once")
            check(pump(timeout: 2) { reminderIDs() == ["call"] } && stand.completed == ["rent"] && panel.completing.isEmpty,
                  "the checkbox completes it, then it's gone from the list (\(reminderIDs()))")
        }
        if let note = panel.notes.first { panel.open(note) }
        panel.openReminders()
        if let row = taskRows().first { panel.open(row) }
        check(pump(timeout: 1) { !stand.shownNotes.isEmpty } && stand.shownNotes == ["x-coredata://sample/p1"]
              && stand.openedReminders == 1 && stand.openedAgents == ["a1b2c3d4"],
              "a note opens in Notes, a reminder's title opens Reminders, a task opens in Terminal")

        // What it hears: @note, @reminder, EventKit's changes, AgentMonitor's looks.
        post(.allInOneIMENoteSaved, ["id": "x-coredata://sample/p3", "title": String(repeating: "长", count: 100)])
        _ = pump(timeout: 0.3) { false }
        check(panel.notes.first?.id == "x-coredata://sample/p3" && panel.notes.first?.title.count == 80
              && SavedNotesStore.load(stand.defaults).notes.count == 3, "a note saved with @note goes first, its title cut to 80")
        var reads = stand.reminderReads
        stand.reminders.append(RemindersBridge.Reminder(id: "milk", title: "买牛奶", due: nil, hasTime: false, overdue: false))
        post(.allInOneIMEReminderAdded, ["id": "milk"])
        check(pump(timeout: 2) { reminderIDs() == ["call", "milk"] } && stand.reminderReads == reads + 1,
              "@reminder's notice reads them again")
        reads = stand.reminderReads
        for _ in 0..<3 { post(.EKEventStoreChanged) }
        _ = pump(timeout: 1.2) { false }
        check(stand.reminderReads == reads + 1, "EventKit's changes (a burst of 3) read them once (\(stand.reminderReads - reads))")
        var looks = stand.agentLooks
        var polled = stand.sessions ?? []
        polled[0].state = "done"
        post(.allInOneIMEAgentsPolled, ["sessions": polled])
        check(pump(timeout: 2) { taskRows().allSatisfy { $0.progress == .done } } && stand.agentLooks == looks
              && panel.counts == "2 个提醒", "AgentMonitor's look shows up without asking Claude Code again (\(panel.counts))")

        // Its own looks: every 15 s (0.3 s here) while expanded and AgentMonitor isn't looking.
        panel.apply(false)
        (panel.agentInterval, panel.reminderInterval) = (0.3, 0.3)
        panel.apply(true)
        check(pump(timeout: 3) { loaded() }, "turned on again")
        looks = stand.agentLooks
        _ = pump(timeout: 1.1) { false }
        check(stand.agentLooks >= looks + 2, "expanded: it asks Claude Code itself (\(stand.agentLooks - looks) looks in 1.1 s)")
        stand.monitorWatching = true
        looks = stand.agentLooks
        _ = pump(timeout: 1.1) { false }
        check(stand.agentLooks == looks, "…not while AgentMonitor looks anyway")
        stand.monitorWatching = false
        panel.toggleCollapsed()
        (looks, reads) = (stand.agentLooks, stand.reminderReads)
        _ = pump(timeout: 1.1) { false }
        check(panel.collapsed && panel.window?.frame.height == FloatingPanel.headerHeight && stand.agentLooks == looks
              && stand.reminderReads > reads && stand.defaults.bool(forKey: FloatingPanel.collapsedKey),
              "collapsed to the header bar (remembered): no looks at the tasks, the reminders still read (\(panel.counts))")
        render("14b-dashboard-collapsed")  // not in the README
        panel.toggleCollapsed()
        check(!panel.collapsed && pump(timeout: 1) { stand.agentLooks > looks } && !stand.defaults.bool(forKey: FloatingPanel.collapsedKey),
              "expanded again: it looks at once")

        // Notes is asked only while it runs, and then updates titles and drops deleted notes.
        var lists = stand.noteLists
        panel.refresh()
        _ = pump(timeout: 0.3) { false }
        check(stand.noteLists == lists, "Notes isn't asked while it isn't running")
        stand.notesRunning = true
        stand.listedNotes = [NotesBridge.Note(id: "x-coredata://sample/p1", title: "周会要点（改）", modified: stand.now),
                             NotesBridge.Note(id: "x-coredata://sample/p3", title: "长", modified: stand.now)]
        lists = stand.noteLists
        panel.refresh()
        check(pump(timeout: 2) { panel.notes.count == 2 } && stand.noteLists > lists
              && panel.notes.map(\.title) == ["长", "周会要点（改）"], "Notes running: titles follow it, a deleted note goes (\(panel.notes.map(\.title)))")
        stand.listedNotes = nil  // would need asking
        panel.refresh()
        _ = pump(timeout: 0.3) { false }
        check(panel.notes.count == 2, "without Notes' permission given before it changes nothing")
        stand.notesRunning = false

        // Permissions: it never asks on its own; a button has macOS ask; denied, a button opens the settings.
        stand.access = .notDetermined
        reads = stand.reminderReads
        panel.refresh()
        check(pump(timeout: 2) { panel.reminders == .notDetermined } && stand.reminderReads == reads,
              "not decided yet: 「允许读取提醒事项」, nothing read")
        render("14d-dashboard-ask")  // not in the README
        panel.requestReminderAccess()
        check(pump(timeout: 2) { !reminderIDs().isEmpty } && stand.access == .allowed, "the button asks, then they are listed")
        // Denied, and no claude command: a line with a button; the tasks' section says Claude Code isn't there.
        stand.access = .denied
        stand.sessions = nil
        panel.refresh()
        check(pump(timeout: 2) { panel.reminders == .denied && panel.tasks == .notInstalled },
              "denied: a line and a button; Claude Code not installed: the section says so")
        render("14e-dashboard-denied")  // not in the README
        panel.openReminderSettings()
        check(stand.openedSettings == 1 && ReminderAccess.settingsURL.absoluteString.hasSuffix("Privacy_Reminders"),
              "the button opens System Settings → Privacy & Security → Reminders")
        stand.access = .allowed

        // Nothing at all: the empty states.
        stand.sessions = []
        stand.reminders = []
        stand.defaults.set(nil, forKey: SavedNotesStore.key)
        panel.refresh()
        check(pump(timeout: 2) { panel.tasks == .list([]) && panel.reminders == .list([]) } && panel.notes.isEmpty
              && panel.counts.isEmpty, "nothing yet: the three empty lines, no counts")
        render("14c-dashboard-empty")  // not in the README

        // Displays changed: back on a screen. Its frame is remembered.
        if let window = panel.window {
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            post(NSApplication.didChangeScreenParametersNotification)
            check(pump(timeout: 1) { NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) } },
                  "moved back on screen when the displays change")
            let saved = stand.defaults.string(forKey: FloatingPanel.frameKey).map(NSRectFromString)
            check(saved.map { abs($0.maxY - window.frame.maxY) < 1 && abs($0.minX - window.frame.minX) < 1 } == true,
                  "its frame is remembered")
        }

        // The settings window's toggle saves the setting and applies it at once (a temporary config file).
        let dir = snapshotDirectory.appendingPathComponent("panel-config")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try? settings.write(to: url)
        var applied: [Bool] = []
        let model = SettingsModel(configURL: url)
        model.applyFloatingPanel = { applied.append($0) }
        model.setFloatingPanel(true)
        check(applied == [true] && (try? Config.load(from: url))?.floatingPanel == true, "the settings toggle saves it and shows it at once")
        model.setFloatingPanel(false)
        let preview = SettingsModel(configURL: url, persists: false)
        preview.applyFloatingPanel = { applied.append($0) }
        preview.setFloatingPanel(true)
        check(applied == [true, false] && (try? Config.load(from: url))?.floatingPanel == false, "…and hides it; a preview does neither")

        // The close button: the setting goes off, and nothing of it runs any more.
        panel.close()
        check(!panel.isEnabled && panel.isIdle && stand.savedSetting == [true, false] && menuItem()?.state == .off,
              "close turns the setting off (in memory) and stops its timers and observers; the menu item is unchecked")
        let (kept, readsBefore) = (SavedNotesStore.load(stand.defaults).notes.count, stand.reminderReads)
        post(.allInOneIMENoteSaved, ["id": "x-coredata://sample/p4", "title": "x"])
        post(.allInOneIMEReminderAdded, ["id": "x"])
        _ = pump(timeout: 0.7) { false }
        check(SavedNotesStore.load(stand.defaults).notes.count == kept && stand.reminderReads == readsBefore,
              "off: @note and @reminder go unheard, nothing is read")
        check((try? Data(contentsOf: Config.defaultURL)) == realConfig, "the real config file was not touched")
    }
}
