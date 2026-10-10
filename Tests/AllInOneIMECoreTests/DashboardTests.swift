import Foundation
import Testing
@testable import AllInOneIMECore

/// The floating panel's logic: the notes @note saved, its wording, where it goes on the screens, and
/// the background tasks it lists.
struct DashboardTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func savedNotesNewestFirstCutAndCapped() throws {
        var saved = SavedNotes()
        saved.add(id: "a", title: "周会要点\n第二行", at: t0)
        saved.add(id: "b", title: "  \n  买牛奶和鸡蛋  ", at: t0 + 60)
        #expect(saved.notes.map(\.id) == ["b", "a"] && saved.notes.map(\.title) == ["买牛奶和鸡蛋", "周会要点"])
        // Saved again (the same id): moves up, with the new title.
        saved.add(id: "a", title: "周会要点（改）", at: t0 + 120)
        #expect(saved.notes.map(\.id) == ["a", "b"] && saved.notes.first?.title == "周会要点（改）")
        // Titles are cut to 80 characters (characters, not UTF-16 units).
        saved.add(id: "long", title: String(repeating: "长", count: 100) + "\nmore", at: t0 + 180)
        #expect(saved.notes.first?.title == String(repeating: "长", count: 80))
        // At most 30, the oldest forgotten; the panel shows the newest 5.
        for i in 0..<40 { saved.add(id: "n\(i)", title: "note \(i)", at: t0 + Double(1000 + i)) }
        #expect(saved.notes.count == SavedNotes.limit && saved.notes.first?.id == "n39" && saved.notes.last?.id == "n10")
        #expect(saved.newest(5).map(\.id) == ["n39", "n38", "n37", "n36", "n35"] && saved.newest(-1).isEmpty)
        saved.remove(id: "n39")
        #expect(saved.notes.first?.id == "n38")
        // Kept as JSON; a longer list than the limit (written by hand) is cut when read.
        let decoded = try JSONDecoder().decode(SavedNotes.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
        let many = try JSONEncoder().encode(["notes": Array(repeating: SavedNotes.Note(id: "x", title: "x", saved: t0), count: 40)])
        #expect(try JSONDecoder().decode(SavedNotes.self, from: many).notes.count == SavedNotes.limit)
        #expect(SavedNotes(Array(repeating: SavedNotes.Note(id: "x", title: "x", saved: t0), count: 40)).notes.count == 30)
        #expect(SavedNotes.title("") == "" && SavedNotes.title("\n \n") == "")
    }

    @Test func notesListedByNotesUpdateAndDrop() {
        func saved() -> SavedNotes {
            var notes = SavedNotes()
            notes.add(id: "old", title: "旧笔记", at: t0)
            notes.add(id: "mid", title: "中间", at: t0 + 3600)
            notes.add(id: "new", title: "新笔记", at: t0 + 7200)
            return notes
        }
        // The whole folder (fewer than asked for): titles follow edits, a missing note is gone; a note
        // whose first line is a picture (no name) keeps the title it had.
        var notes = saved()
        let changed = notes.reconcile(with: [("new", "新笔记（改过）", t0 + 9000), ("old", "", t0 + 10)], limit: 200)
        #expect(changed && notes.notes.map(\.id) == ["new", "old"] && notes.notes.map(\.title) == ["新笔记（改过）", "旧笔记"])
        let again = notes.reconcile(with: [("new", "新笔记（改过）", t0 + 9000), ("old", "", t0 + 10)], limit: 200)
        #expect(!again)
        // A full list (as many as asked for): only notes saved after the oldest listed change can be
        // told to be gone (a minute's margin); older ones may just be further down the folder.
        notes = saved()
        notes.reconcile(with: [("x", "x", t0 + 5000), ("y", "y", t0 + 1800)], limit: 2)
        #expect(notes.notes.map(\.id) == ["old"])
        notes = saved()
        notes.reconcile(with: [("x", "x", t0 + 3590), ("y", "y", t0 + 3595)], limit: 2)
        #expect(notes.notes.map(\.id) == ["mid", "old"])  // "mid" was saved within the minute: kept
        // No folder (an empty list): everything is gone.
        notes = saved()
        let emptied = notes.reconcile(with: [], limit: 200)
        #expect(emptied && notes.notes.isEmpty)
    }

    @Test func howLongAgo() {
        let cases: [(TimeInterval, String, String)] = [
            (-30, "刚刚", "just now"), (59, "刚刚", "just now"), (60, "1 分钟前", "1 min ago"),
            (25 * 60, "25 分钟前", "25 min ago"), (3599, "59 分钟前", "59 min ago"), (3600, "1 小时前", "1 hr ago"),
            (2 * 3600 + 59 * 60, "2 小时前", "2 hr ago"), (86_399, "23 小时前", "23 hr ago"),
            (86_400, "1 天前", "1 day ago"), (3 * 86_400 + 5, "3 天前", "3 days ago"),
        ]
        for (seconds, chinese, english) in cases {
            #expect(DashboardText.ago(t0, now: t0 + seconds, chinese: true) == chinese)
            #expect(DashboardText.ago(t0, now: t0 + seconds, chinese: false) == english)
        }
    }

    @Test func headerCounts() {
        #expect(DashboardText.counts(reminders: 3, running: 1, chinese: true) == "3 个提醒 · 1 个任务进行中")
        #expect(DashboardText.counts(reminders: 3, running: 1, chinese: false) == "3 reminders · 1 task running")
        #expect(DashboardText.counts(reminders: 1, running: 2, chinese: false) == "1 reminder · 2 tasks running")
        #expect(DashboardText.counts(reminders: 0, running: 2, chinese: true) == "2 个任务进行中")
        #expect(DashboardText.counts(reminders: 5, running: 0, chinese: true) == "5 个提醒")
        #expect(DashboardText.counts(reminders: 0, running: 0, chinese: true).isEmpty)
        #expect(DashboardText.counts(reminders: 100, moreReminders: true, running: 0, chinese: true) == "100+ 个提醒")
        #expect(DashboardText.counts(reminders: 1, moreReminders: true, running: 0, chinese: false) == "1+ reminders")
    }

    @Test func aReplysFirstLine() {
        #expect(DashboardText.firstLine("## 完成了\n\n细节……") == "完成了")
        #expect(DashboardText.firstLine("\n\n- **Fixed** the `parse()` bug\n- more") == "Fixed the parse() bug")
        #expect(DashboardText.firstLine("> quoted\nnext") == "quoted")
        #expect(DashboardText.firstLine("1. First step\n2. Second") == "First step")
        #expect(DashboardText.firstLine("3.5 hours left") == "3.5 hours left")
        #expect(DashboardText.firstLine("#hashtag stays") == "#hashtag stays")
        #expect(DashboardText.firstLine("  \n ### \n ok") == "ok")
        #expect(DashboardText.firstLine("   ") == nil && DashboardText.firstLine(nil) == nil)
    }

    @Test func placementOnTheScreens() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 875)  // below a 25 pt menu bar
        let size = CGSize(width: 300, height: 420)
        let first = PanelPlacement.topRight(size, in: main)
        #expect(first == CGRect(x: 1128, y: 443, width: 300, height: 420))
        // On a screen: stays.
        #expect(PanelPlacement.onScreen(first, visible: [main]) == first)
        let side = CGRect(x: 1440, y: -200, width: 1920, height: 1055)
        let there = CGRect(x: 2000, y: 300, width: 300, height: 420)
        #expect(PanelPlacement.onScreen(there, visible: [main, side]) == there)
        // That screen gone: to the top right of the first one.
        #expect(PanelPlacement.onScreen(there, visible: [main]) == first)
        // Partly off a screen: moved in, onto the screen it overlaps most.
        #expect(PanelPlacement.onScreen(CGRect(x: 1300, y: 700, width: 300, height: 420), visible: [main])
                == CGRect(x: 1140, y: 455, width: 300, height: 420))
        #expect(PanelPlacement.onScreen(CGRect(x: 1400, y: 100, width: 300, height: 420), visible: [main, side])
                == CGRect(x: 1440, y: 100, width: 300, height: 420))
        // Taller than the screen: its top (the header) stays on it.
        let small = CGRect(x: 0, y: 0, width: 800, height: 300)
        #expect(PanelPlacement.onScreen(CGRect(x: 100, y: 50, width: 300, height: 420), visible: [small])
                == CGRect(x: 100, y: -120, width: 300, height: 420))
        #expect(PanelPlacement.onScreen(there, visible: []) == there)
    }

    @Test func theTasksListed() {
        func session(_ id: String, _ state: String?, started: Double?, name: String? = nil) -> AgentSession {
            AgentSession(id: id, sessionId: id + "-session", name: name, state: state, startedAt: started)
        }
        let ms = t0.timeIntervalSince1970 * 1000
        #expect(AgentTaskList.started(session("a", nil, started: ms)) == t0)
        #expect(AgentTaskList.started(session("a", nil, started: t0.timeIntervalSince1970)) == t0)  // seconds
        #expect(AgentTaskList.started(session("a", nil, started: nil)) == nil)
        // The newest 6, newest first; the name, else the prompt @claude started it with, else the id.
        var sessions = (0..<8).map { session("t\($0)", "done", started: ms + Double($0) * 1000, name: "task \($0)") }
        sessions.append(session("nameless", "working", started: ms + 60_000))
        sessions.append(session("blank", "waiting_for_input", started: ms + 50_000, name: "  "))
        let rows = AgentTaskList.rows(sessions, replies: ["t7-session": "Done: 3 files"],
                                      prompt: { $0 == "nameless" ? "fix the\nlogin  bug" : nil })
        #expect(rows.count == AgentTaskList.limit)
        #expect(rows.map(\.id) == ["nameless", "blank", "t7", "t6", "t5", "t4"])
        #expect(rows.map(\.title) == ["fix the login bug", "blank", "task 7", "task 6", "task 5", "task 4"])
        #expect(rows.map(\.progress) == [.working, .needsYou, .done, .done, .done, .done])
        #expect(rows[2].reply == "Done: 3 files" && rows[0].reply == nil && rows[2].started == t0 + 7)
    }

    @Test func repliesAreReadAgainOnlyWhileRunning() {
        let running = AgentSession(id: "a", sessionId: "a-1", state: "working")
        let done = AgentSession(id: "b", sessionId: "b-1", state: "done")
        var cache = AgentReplyCache()
        #expect(cache.stale([running, done]) == [running, done])
        cache.store(["a-1": "working on it", "b-1": "all done"], for: [running, done])
        #expect(cache.replies == ["a-1": "working on it", "b-1": "all done"])
        // Finished and read once: not again. Still running: again at every look.
        #expect(cache.stale([running, done]) == [running])
        // Done now: read once more for the final reply.
        let finished = AgentSession(id: "a", sessionId: "a-1", state: "done")
        #expect(cache.stale([finished, done]) == [finished])
        cache.store([:], for: [finished])
        #expect(cache.stale([finished, done]).isEmpty && cache.replies == ["b-1": "all done"])
        // Sessions no longer shown are forgotten.
        cache.keep(only: [done])
        #expect(cache.replies == ["b-1": "all done"] && cache.stale([finished]) == [finished])
    }
}
