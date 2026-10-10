import AllInOneIMECore
import AppKit
import UserNotifications

/// `@claude` in the background: starts Claude Code background sessions, looks at them every few seconds
/// while any is running, and notifies when one is done (or waits for the user). Clicking the
/// notification opens the session in Terminal (`claude attach`). The tasks being watched survive a
/// restart of the input method.
@MainActor
final class AgentMonitor: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentMonitor()

    private static let key = "agentWatch"
    private var watch: AgentWatch
    private var timer: Timer?
    private var polling = false
    static let interval: TimeInterval = 8

    private override init() {
        watch = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(AgentWatch.self, from: $0) } ?? AgentWatch()
        super.init()
    }

    var claude: String { TerminalLauncher.claudePath ?? "claude" }

    /// At launch: notifications come back here; tasks from before a restart are watched again.
    func setUp() {
        UNUserNotificationCenter.current().delegate = self
        if !watch.isEmpty { schedule() }
    }

    /// Starts `prompt` in the background in the home folder; returns its id.
    func start(_ prompt: String) async throws -> String {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let output = try await Self.run(claude, ClaudeAgents.startArguments(prompt))
        guard let id = ClaudeAgents.startedID(in: output) else {
            throw AgentError.notStarted(String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
        }
        watch.add(AgentWatch.Task(id: id, prompt: prompt))
        save()
        schedule()
        log.notice("background task \(id, privacy: .public) started")
        return id
    }

    /// The background sessions, newest first, with their last replies.
    func list() async throws -> [(session: AgentSession, reply: String?)] {
        let output = try await Self.run(claude, ClaudeAgents.listArguments)
        let sessions = ClaudeAgents.sessions(from: Data(output.utf8)).sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
        return await Task.detached {
            sessions.prefix(9).map { ($0, ClaudeAgents.lastReply(sessionId: $0.sessionId, cwd: $0.cwd)) }
        }.value
    }

    /// Opens the session in Terminal, to read all of it and go on.
    func open(_ id: String) {
        do {
            try TerminalLauncher.launch([claude, "attach", id], name: "claude-attach")
        } catch {
            log.error("could not open background task \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func schedule() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard !polling else { return }
        guard !watch.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        polling = true
        Task { [claude] in
            defer { self.polling = false }
            guard let output = try? await Self.run(claude, ClaudeAgents.listArguments) else { return }
            let sessions = ClaudeAgents.sessions(from: Data(output.utf8))
            for event in self.watch.update(with: sessions) {
                switch event {
                case let .done(task, session):
                    let reply = await Task.detached { ClaudeAgents.lastReply(sessionId: session.sessionId, cwd: session.cwd) }.value
                    self.notify(id: task.id, title: tr("Claude 完成了：", "Claude is done: ") + (session.name ?? task.prompt),
                                body: reply.map { String($0.prefix(240)) } ?? tr("点这里查看", "Click to see it"))
                case let .needsYou(task, session):
                    self.notify(id: task.id, title: tr("Claude 在等你：", "Claude needs you: ") + (session.name ?? task.prompt),
                                body: tr("点这里在终端里继续", "Click to go on in Terminal"))
                }
            }
            self.save()
        }
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(120))
        content.body = body
        content.sound = .default
        content.userInfo = ["agent": id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agent-\(id)-\(Date().timeIntervalSince1970)",
                                                                     content: content, trigger: nil))
        log.notice("background task \(id, privacy: .public) reported")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(watch) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // Clicking the notification opens the task.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["agent"] as? String
        DispatchQueue.main.async {
            if let id { MainActor.assumeIsolated { AgentMonitor.shared.open(id) } }
            completionHandler()
        }
    }

    // Shown even while a text field is active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    enum AgentError: Error, LocalizedError {
        case notStarted(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .notStarted(output):
                return tr("Claude Code 没能在后台开始：", "Claude Code didn't start in the background: ") + output
            case let .failed(message): return message
            }
        }
    }

    /// Runs `claude` in the home folder (a folder it trusts) with the login shell's PATH; its output.
    nonisolated static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                guard let url = CommandRunner.resolve(executable, path: ShellEnvironment.current["PATH"]) else {
                    continuation.resume(throwing: AgentError.failed(tr("找不到 claude 命令", "The claude command isn't installed")))
                    return
                }
                process.executableURL = url
                process.arguments = arguments
                process.environment = ShellEnvironment.current
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // Read both pipes at once so neither fills up.
                var output = Data(), errors = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { output = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                errors = err.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                killer.cancel()
                let text = String(decoding: output, as: UTF8.self)
                guard process.terminationStatus == 0 else {
                    let message = String(decoding: errors.isEmpty ? output : errors, as: UTF8.self)
                    continuation.resume(throwing: AgentError.failed(String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))))
                    return
                }
                continuation.resume(returning: text)
            }
        }
    }
}
