import Foundation

/// Runs a `run` command (`CustomCommand`): the program starts in the home folder, without a shell,
/// with the user's shell PATH; what it prints becomes the one result. It is stopped after its
/// timeout, when it prints too much, or when the request is cancelled (Esc).
public enum CommandRunner {
    /// Output kept from the program (more stops it).
    static let maxOutputBytes = 64 * 1024

    public enum RunError: Error, LocalizedError, Equatable {
        case notFound(String)
        case failed(status: Int32, message: String)
        case timedOut(Double)
        case tooMuchOutput

        public var errorDescription: String? {
            switch self {
            case let .notFound(program): return "Program not found: \(program)"
            case let .failed(status, message): return message.isEmpty ? "The program failed (exit status \(status))" : message
            case let .timedOut(seconds): return "Stopped after \(Int(seconds.rounded())) seconds"
            case .tooMuchOutput: return "Stopped: too much output"
            }
        }
    }

    /// `environment` nil: `ShellEnvironment.current` (asked for off the caller's thread: the first
    /// time, the user's shell is started to read its PATH).
    public static func run(_ command: CustomCommand, input: String,
                           environment: [String: String]? = nil) -> AsyncThrowingStream<ConversionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let run = Run(command: command, input: input, continuation: continuation)
            continuation.onTermination = { _ in run.cancel() }
            DispatchQueue.global().async { run.start(environment: environment ?? ShellEnvironment.current) }
        }
    }

    /// The program as it will be started: an absolute path, or the first match on `path`.
    public static func resolve(_ program: String, path: String?) -> URL? {
        let fm = FileManager.default
        if program.contains("/") {
            let expanded = (program as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for dir in (path ?? "").split(separator: ":") where !dir.isEmpty {
            let candidate = (String(dir) as NSString).appendingPathComponent(program)
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// Whether `program` would run here: it is found (`resolve`), and if it is one of the stand-ins macOS
    /// keeps in /usr/bin for the developer tools (`python3`, `git`, …), Xcode or the command line tools
    /// are installed (without them, the stand-in only offers to install them).
    public static func isInstalled(_ program: String, path: String?,
                                   developerFolders: [String] = DeveloperTools.folders) -> Bool {
        guard let url = resolve(program, path: path) else { return false }
        return !DeveloperTools.isStandIn(url) || DeveloperTools.installed(in: developerFolders)
    }

    /// What the program printed, as inserted: control characters (colors, bells) removed, line
    /// breaks and tabs kept, trailing blank lines dropped.
    static func cleanOutput(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\t" { out.append(scalar); continue }
            if scalar == "\r" { continue }
            if scalar.properties.generalCategory == .control { continue }
            out.append(scalar)
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One run of a program. Its callbacks arrive on several queues; `lock` guards the state.
    private final class Run: @unchecked Sendable {
        private let command: CustomCommand
        private let input: String
        private let continuation: AsyncThrowingStream<ConversionUpdate, Error>.Continuation
        private let process = Process()
        private let lock = NSLock()
        private var output = Data()
        private var errors = Data()
        private var stopReason: RunError?
        private var cancelled = false
        private var finished = false
        private let started = ContinuousClock.now
        /// Both output pipes closed.
        private let pipes = DispatchGroup()

        init(command: CustomCommand, input: String, continuation: AsyncThrowingStream<ConversionUpdate, Error>.Continuation) {
            self.command = command
            self.input = input
            self.continuation = continuation
        }

        func start(environment: [String: String]) {
            lock.lock()
            let skip = cancelled
            lock.unlock()
            guard !skip else { return }
            let argv = command.arguments(for: input)
            guard let program = argv.first, let url = CommandRunner.resolve(program, path: environment["PATH"]) else {
                continuation.finish(throwing: RunError.notFound(argv.first ?? ""))
                return
            }
            process.executableURL = url
            process.arguments = Array(argv.dropFirst())
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = stdin
            capture(stdout) { $0.output.append($1) }
            capture(stderr) { $0.errors.append($1) }
            process.terminationHandler = { [self] _ in
                // A program it started in the background may keep the pipes open: don't wait for that.
                DispatchQueue.global().async { [self] in
                    _ = pipes.wait(timeout: .now() + 1)
                    finish()
                }
            }
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: RunError.notFound(program))
                return
            }
            let text = command.standardInput(for: input)
            DispatchQueue.global().async {
                // Written off the caller's queue: a program that doesn't read would block the write.
                if let text { try? stdin.fileHandleForWriting.write(contentsOf: Data(text.utf8)) }
                try? stdin.fileHandleForWriting.close()
            }
            let timeout = command.timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in stop(.timedOut(timeout)) }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
            stop(nil)
        }

        /// Reads `pipe` until it closes, keeping at most `maxOutputBytes` in all.
        private func capture(_ pipe: Pipe, into append: @escaping @Sendable (Run, Data) -> Void) {
            pipes.enter()
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    pipes.leave()
                    return
                }
                lock.lock()
                append(self, chunk)
                let tooMuch = output.count + errors.count > CommandRunner.maxOutputBytes
                lock.unlock()
                if tooMuch { stop(.tooMuchOutput) }
            }
        }

        /// Stops the program (once): `reason` is reported, nil when the request was cancelled.
        private func stop(_ reason: RunError?) {
            lock.lock()
            let running = !finished && stopReason == nil && process.isRunning
            if running, let reason { stopReason = reason }
            lock.unlock()
            guard running else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }

        private func finish() {
            lock.lock()
            guard !finished else { return lock.unlock() }
            finished = true
            let reason = stopReason, output = output, errors = errors, cancelled = cancelled
            lock.unlock()
            let status = process.terminationStatus
            if cancelled { return continuation.finish() }
            if let reason { return continuation.finish(throwing: reason) }
            guard status == 0 else {
                // The last line with words says what went wrong (Python's traceback ends with it; markers
                // like "~~^~~" above it are left out).
                let message = CommandRunner.cleanOutput(errors).split(separator: "\n")
                    .last { $0.contains { $0.isLetter } }?.trimmingCharacters(in: .whitespaces) ?? ""
                return continuation.finish(throwing: RunError.failed(status: status, message: String(message.prefix(300))))
            }
            let d = ContinuousClock.now - started
            let elapsed = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            let text = CommandRunner.cleanOutput(output)
            let result = text.isEmpty ? ConversionResult.empty : ConversionResult(versions: [CandidateLine(text)])
            continuation.yield(ConversionUpdate(result: result, rawText: text, isFinal: true, elapsed: elapsed,
                                                firstTokenLatency: nil, fromCache: false))
            continuation.finish()
        }
    }
}

/// The environment a program started from the input method gets: the input method's own, with the
/// PATH of the user's login shell (an input method started by launchd only has the system folders,
/// so `python3` from Homebrew, pyenv or nvm wouldn't be found). The shell is asked once.
public enum ShellEnvironment {
    public static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static let current: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = login["PATH"] ?? fallbackPath
        return env
    }()

    /// The variables the input method reads from the user's shell: PATH, and the providers' API keys
    /// (`Provider.keyVariables`), for a key that is set there instead of in the keychain.
    public static let login: [String: String] = loginValues(["PATH"] + Provider.allCases.flatMap(\.keyVariables))

    /// `names` as the user's interactive login shell sets them up (unset ones are left out); empty if
    /// the shell couldn't be read in 3 seconds.
    static func loginValues(_ names: [String]) -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__AllInOneIME_\(UUID().uuidString)__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive too: pyenv, nvm and the like are usually set up in .zshrc. Each value is printed
        // between markers, so whatever the shell's startup files print is skipped.
        let script = names.map { "printf '\(marker)\($0)=%s' \"${\($0)}\"" }.joined(separator: "; ") + "; printf '\(marker)'"
        process.arguments = ["-ilc", script]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return [:] }
        if exited.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            return [:]
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var values: [String: String] = [:]
        for part in text.components(separatedBy: marker).dropFirst() {
            guard let eq = part.firstIndex(of: "="), names.contains(String(part[..<eq])) else { continue }
            let value = String(part[part.index(after: eq)...])
            if !value.isEmpty { values[String(part[..<eq])] = value }
        }
        return values
    }
}

/// The stand-ins macOS keeps in /usr/bin for the developer tools: `python3`, `git`, `make`, `swift` and
/// the others are one small program (hard links of one file) that runs the real tool from Xcode or the
/// command line tools, and without those only offers to install them.
public enum DeveloperTools {
    /// Where Xcode or the command line tools may be: the folder chosen with `xcode-select -s`, then the
    /// default places.
    public static var folders: [String] {
        let chosen = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
        return (chosen.map { [$0] } ?? []) + ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools"]
    }

    /// Whether one of `folders` has the tools.
    static func installed(in folders: [String]) -> Bool {
        folders.contains { folder in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder + "/usr/bin", isDirectory: &isFolder) && isFolder.boolValue
        }
    }

    /// Whether `url` (after symbolic links) is the same file as `standIn`: /usr/bin/python3 has been one
    /// of the stand-ins on every macOS since 10.15.
    static func isStandIn(_ url: URL, standIn: String = "/usr/bin/python3") -> Bool {
        var file = stat(), known = stat()
        guard stat(url.path, &file) == 0, stat(standIn, &known) == 0 else { return false }
        return file.st_dev == known.st_dev && file.st_ino == known.st_ino
    }
}
