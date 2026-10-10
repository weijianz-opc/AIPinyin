import Foundation
import Testing
@testable import AllInOneIMECore

struct ClaudeAgentsTests {
    @Test func startingAndListing() throws {
        #expect(ClaudeAgents.startArguments("--dangerously-skip-permissions") == ["--bg", "--", "--dangerously-skip-permissions"])
        // What `claude --bg` printed (2.1.296), colors and all.
        let printed = "\u{1B}[2mbackgrounded · 9b90f24f\u{1B}[0m\n  claude agents             list sessions\n  claude attach 9b90f24f    open in this terminal\n"
        #expect(ClaudeAgents.startedID(in: printed) == "9b90f24f")
        #expect(ClaudeAgents.startedID(in: "Workspace not trusted. Run `claude` in /tmp once …") == nil)
        // `claude agents --json --all`: only background sessions count.
        let json = #"""
            [{"pid":13996,"cwd":"/Users/me","kind":"interactive","startedAt":1791574463320,"sessionId":"5bd2e89a-dc95","name":"me-33","status":"busy"},
             {"pid":95911,"id":"9b90f24f","kind":"background","startedAt":1791608404578,"sessionId":"9b90f24f-f73c-49db","name":"ok reply task","status":"idle","state":"done","cwd":"/Users/me"}]
            """#
        let sessions = ClaudeAgents.sessions(from: Data(json.utf8))
        #expect(sessions.map(\.shortID) == ["9b90f24f"] && sessions.first?.progress == .done && sessions.first?.name == "ok reply task")
        #expect(AgentSession(sessionId: "x", state: "working").progress == .working)
        #expect(AgentSession(sessionId: "x", state: "waiting_for_permission").progress == .needsYou)
        #expect(ClaudeAgents.sessions(from: Data("not json".utf8)).isEmpty)
        #expect(sessions.first?.pid == 95911)
        // Opening one: joined while its process runs, resumed (in its folder) once it has exited.
        let done = try #require(sessions.first)
        #expect(ClaudeAgents.openArguments(done, isRunning: true) == (["attach", "9b90f24f"], nil))
        #expect(ClaudeAgents.openArguments(done, isRunning: false) == (["--resume", "9b90f24f-f73c-49db"], "/Users/me"))
    }

    @Test func theLastReplyFromTheTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ClaudeAgents.projectFolder(for: "/Users/me") == "-Users-me")
        #expect(ClaudeAgents.projectFolder(for: "/Users/me/code/my.app") == "-Users-me-code-my-app")
        let folder = root.appendingPathComponent("-Users-me")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Fix the bug"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","name":"Read"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed it: the off-by-one in parse()."}]}}"#,
            "not json",
        ]
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("abc-123.jsonl"), atomically: true, encoding: .utf8)
        #expect(ClaudeAgents.lastReply(sessionId: "abc-123", cwd: "/Users/me", root: root) == "Fixed it: the off-by-one in parse().")
        // Found by its id even when the folder is named some other way.
        #expect(ClaudeAgents.lastReply(sessionId: "abc-123", cwd: "/elsewhere", root: root) == "Fixed it: the off-by-one in parse().")
        #expect(ClaudeAgents.lastReply(sessionId: "nope", cwd: "/Users/me", root: root) == nil)
    }

    @Test func whenToNotify() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var watch = AgentWatch()
        watch.add(.init(id: "aaaa1111", prompt: "fix it", started: t0))
        watch.add(.init(id: "bbbb2222", prompt: "write docs", started: t0))
        func session(_ id: String, _ state: String) -> AgentSession { AgentSession(id: id, sessionId: id + "-x", name: id, state: state) }
        // Running: nothing yet.
        #expect(watch.update(with: [session("aaaa1111", "working"), session("bbbb2222", "working")], now: t0 + 10).isEmpty)
        // One waits for the user: told once, still watched.
        var events = watch.update(with: [session("aaaa1111", "waiting"), session("bbbb2222", "working")], now: t0 + 20)
        #expect(events.count == 1 && { if case .needsYou(let t, _) = events[0] { return t.id == "aaaa1111" }; return false }())
        #expect(watch.update(with: [session("aaaa1111", "waiting"), session("bbbb2222", "working")], now: t0 + 30).isEmpty)
        // Done: told, then no longer watched.
        events = watch.update(with: [session("aaaa1111", "working"), session("bbbb2222", "done")], now: t0 + 40)
        #expect(events.count == 1 && { if case .done(let t, _) = events[0] { return t.id == "bbbb2222" }; return false }())
        #expect(watch.tasks.map(\.id) == ["aaaa1111"])
        // Removed (claude rm): dropped after a grace minute; a new one not listed yet is kept meanwhile.
        watch.add(.init(id: "cccc3333", prompt: "new", started: t0 + 100))
        _ = watch.update(with: [], now: t0 + 120)
        #expect(watch.tasks.map(\.id) == ["cccc3333"])
        let saved = try? JSONDecoder().decode(AgentWatch.self, from: JSONEncoder().encode(watch))
        #expect(saved == watch)
    }

    @Test func claudeInTheBackgroundAndTheTaskList() {
        let c = Composer(engine: FakeEngine())
        c.claudeInBackground = true
        let at = KeyEvent(keyCode: 0x13, characters: "@", charactersIgnoringModifiers: "@", modifiers: .shift)
        let tab = KeyEvent(keyCode: VirtualKey.tab, characters: "\t")
        let enter = KeyEvent(keyCode: VirtualKey.returnKey, characters: "\r")
        _ = c.handleKeyDown(at)
        for ch in "cl" { _ = c.handleKeyDown(k(String(ch))) }
        _ = c.handleKeyDown(tab)
        for ch in "nihao" { _ = c.handleKeyDown(k(String(ch))) }
        let started = c.handleKeyDown(enter).effects
        #expect(started.contains(.startBackgroundAgent(prompt: "你好")) && !started.contains(.runInTerminal(prompt: "你好")))
        #expect(started.contains(.notice(c.messages.startedInBackground)) && c.draft.isEmpty && !c.isLevelTwo)
        // @tasks needs nothing after it; picking a task opens it, ⌘C copies its reply.
        _ = c.handleKeyDown(at)
        for ch in "tas" { _ = c.handleKeyDown(k(String(ch))) }
        _ = c.handleKeyDown(tab)
        let listed = c.handleKeyDown(enter).effects
        #expect(listed.first == .listAgents(id: 1) && c.activeCommand == .tasks)
        _ = c.receiveSearch([SearchResult(name: "✓ fix the bug", path: SearchResult.agentPrefix + "9b90f24f", detail: "Fixed it.")], id: 1)
        #expect(c.choices.map(\.text) == ["✓ fix the bug"] && c.copyableText == "Fixed it.")
        let opened = c.handleKeyDown(enter).effects
        #expect(opened.contains(.open(path: "claude-agent:9b90f24f")))
        #expect(SearchResult(name: "", path: "claude-agent:9b90f24f").agentID == "9b90f24f")
        // Off: Terminal as before.
        let d = Composer(engine: FakeEngine())
        _ = d.handleKeyDown(at)
        for ch in "cl" { _ = d.handleKeyDown(k(String(ch))) }
        _ = d.handleKeyDown(tab)
        for ch in "nihao" { _ = d.handleKeyDown(k(String(ch))) }
        #expect(d.handleKeyDown(enter).effects.contains(.runInTerminal(prompt: "你好")))
    }
}
