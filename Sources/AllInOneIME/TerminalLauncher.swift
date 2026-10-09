import AppKit

/// `@claude`: a Claude Code session in a Terminal window, with the typed text as its first message.
/// Claude Code asks before it changes files or runs commands, as it always does.
enum TerminalLauncher {
    /// Where the `claude` command was found (absolute, so the window doesn't depend on PATH).
    static let claudePath: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Opens a new Terminal window in the home folder that runs `claude <prompt>`. The script deletes
    /// itself when it starts; the prompt is passed as one quoted argument, never as shell code.
    static func claude(_ prompt: String) throws {
        let command = shellQuote(claudePath ?? "claude")
        let script = """
            #!/bin/zsh -l
            rm -f -- "$0"
            cd ~ || exit 1
            exec \(command) \(shellQuote(prompt))

            """
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AllInOneIME", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("claude-\(UUID().uuidString).command")
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// `text` as one single-quoted shell word.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
