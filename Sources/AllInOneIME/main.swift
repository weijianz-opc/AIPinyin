import AllInOneIMECore
import AllInOneIMECore
import AllInOneIMERime
import AppKit
import Carbon
import InputMethodKit

let usage = """
    AllInOneIME input method. Launched by macOS without arguments; developer commands:
      --register        register this bundle with Text Input Sources, enable it and add it to
                        your input sources
      --disable         disable, and remove it from your input sources
      --status          show registration, process and configuration status
      --settings        run as the input method and open the settings window
      --selftest [DIR]  drive the input controller (real Rime engine, live Bedrock call) with a
                        fake text field; writes panel snapshots to DIR (default /tmp/allinoneime-selftest)
    """

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Where level one keeps its data: dictionaries shipped in the bundle, learned words per user.
enum RimeDirectories {
    static var shared: URL? {
        Bundle.main.sharedSupportURL?.appendingPathComponent("rime")
    }
    static var user: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AllInOneIME/Rime")
    }
    static var logs: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AllInOneIME")
    }
}

/// Opens the settings window when the input method is "opened" again (the AllInOneIME Settings app does
/// that). The text input system never sends reopen events, so typing is unaffected.
final class IMEAppDelegate: NSObject, NSApplicationDelegate {
    static let shared = IMEAppDelegate()

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsWindow.shared.show() }
        return false
    }
}

func runServer(showSettings: Bool = false) -> Never {
    let app = NSApplication.shared
    app.delegate = IMEAppDelegate.shared
    guard let name = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
          let server = IMKServer(name: name, bundleIdentifier: Bundle.main.bundleIdentifier)
    else {
        log.fault("could not start IMKServer (is the binary inside AllInOneIME.app?)")
        printError("could not start IMKServer; run from inside AllInOneIME.app")
        exit(1)
    }
    log.info("IMKServer started: \(name, privacy: .public)")
    // Older versions kept their sentence mode switch here (first as aiEnabled); nothing reads it now.
    for key in ["sentenceMode", "aiEnabled"] { UserDefaults.standard.removeObject(forKey: key) }
    // Background @claude tasks: notifications, and tasks from before a restart watched again.
    MainActor.assumeIsolated { AgentMonitor.shared.setUp() }
    if showSettings {
        DispatchQueue.main.async { MainActor.assumeIsolated { SettingsWindow.shared.show() } }
    }
    if let shared = RimeDirectories.shared, FileManager.default.fileExists(atPath: shared.path) {
        do {
            try RimeService.shared.start(
                sharedDataDir: shared, userDataDir: RimeDirectories.user, logDir: RimeDirectories.logs)
            RimeReadinessLogger.shared.start()
        } catch {
            log.fault("could not start Rime: \(String(describing: error), privacy: .public)")
        }
    } else {
        log.fault("Rime data missing from the bundle; pinyin input disabled")
    }
    withExtendedLifetime(server) { app.run() }
    exit(0)
}

/// Logs once when librime has finished deploying after launch (keys pass through until then).
final class RimeReadinessLogger: NSObject {
    static let shared = RimeReadinessLogger()
    private let started = Date()

    func start() {
        Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(check(_:)), userInfo: nil, repeats: true)
    }

    @objc private func check(_ timer: Timer) {
        let elapsed = Date().timeIntervalSince(started)
        if RimeService.shared.isReady {
            timer.invalidate()
            log.info("Rime ready \(elapsed, format: .fixed(precision: 2))s after launch")
        } else if elapsed > 300 {
            timer.invalidate()
            log.error("Rime still deploying after 300s")
        }
    }
}

/// Deploys the bundled Rime data into the user's directory now, so the first keystroke after
/// installing doesn't wait for it.
func prepareDictionaries() {
    guard let shared = RimeDirectories.shared, FileManager.default.fileExists(atPath: shared.path) else {
        printError("Rime data missing from the bundle")
        return
    }
    let started = Date()
    do {
        try RimeService.shared.start(
            sharedDataDir: shared, userDataDir: RimeDirectories.user, logDir: RimeDirectories.logs)
    } catch {
        printError("could not start Rime: \(error)")
        return
    }
    let ready = RimeService.shared.waitUntilReady(timeout: 120)
    print(ready
        ? String(format: "dictionaries: ready (%.1fs)", Date().timeIntervalSince(started))
        : "dictionaries: still deploying; the input method finishes it on first use")
}

func register() -> Int32 {
    let url = Bundle.main.bundleURL
    guard url.pathExtension == "app" else {
        printError("run --register from inside AllInOneIME.app")
        return 1
    }
    let status = InputSourceRegistrar.register(bundleURL: url)
    guard status == 0 else {
        printError("TISRegisterInputSource failed: \(status)")
        return 1
    }
    guard let source = InputSourceRegistrar.waitForSource() else {
        printError("registered, but input source \(InputSourceRegistrar.sourceID) did not appear")
        return 1
    }
    if !InputSourceRegistrar.bool(source, kTISPropertyInputSourceIsEnabled) {
        // Recent macOS versions don't let installers enable third-party keyboard input methods:
        // register/enable succeed, System Settings → Keyboard opens, and the user adds it there.
        let enableStatus = TISEnableInputSource(source)
        guard enableStatus == 0 else {
            printError("TISEnableInputSource failed: \(enableStatus)")
            return 1
        }
    }
    let enabled = InputSourceRegistrar.waitUntilEnabled(timeout: 2)
    if enabled {
        // Enabled by a program, it isn't in the user's input sources, which Ctrl+Space goes by:
        // keep it there as well (see InputSourceList).
        switch InputSourceRegistrar.updateUserList({ InputSourceList.adding(InputSourceRegistrar.bundleID, to: $0) }) {
        case .written: print("input list:  added to your input sources (Ctrl+Space reaches it now)")
        case .failed: printError("could not add it to your input sources (\(InputSourceList.domain))")
        case .unchanged: break
        }
    }
    prepareDictionaries()
    _ = printStatus()
    if !enabled {
        // In the interface language (the setting, else the system's): the menu names are the system's.
        UIText.choice = (try? Config.load())?.uiLanguage
        print(tr("""

            macOS 需要你手动添加一次（“键盘”设置应该已经打开）：
              系统设置 → 键盘 → 文字输入 › 输入法「编辑…」→ 左下角 + → 简体中文 → AllInOneIME → 添加
            之后用 Ctrl+Space 或 🌐 键切换到 AllInOneIME。
            """, """

            macOS needs you to add it once (Keyboard settings should have opened):
              System Settings → Keyboard → Text Input › Input Sources "Edit…" → + at the bottom left
              → Chinese, Simplified → AllInOneIME → Add
            Then switch to AllInOneIME with Ctrl+Space or the 🌐 key.
            """))
    }
    return 0
}

func disable() -> Int32 {
    var status: OSStatus = 0
    if let source = InputSourceRegistrar.source() {
        status = TISDisableInputSource(source)
        print(status == 0 ? "disabled \(InputSourceRegistrar.sourceID)" : "TISDisableInputSource failed: \(status)")
    } else {
        print("not registered")
    }
    switch InputSourceRegistrar.updateUserList({ InputSourceList.removing(InputSourceRegistrar.bundleID, from: $0) }) {
    case .written: print("removed from your input sources")
    case .failed: printError("could not remove it from your input sources (\(InputSourceList.domain))")
    case .unchanged: break
    }
    return status == 0 ? 0 : 1
}

func printStatus() -> Int32 {
    typealias R = InputSourceRegistrar
    print("version:     \(AppVersion.string)")
    print("bundle:      \(Bundle.main.bundlePath)")
    let others = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != getpid()
    }
    print("running:     \(others.isEmpty ? "no" : others.map { "pid \($0.processIdentifier)" }.joined(separator: ", "))")

    do {
        let config = try Config.load()
        print("config:      \(Config.defaultURL.path)")
        print("provider:    \(config.provider.displayName)")
        print("model:       \(config.settings(for: config.provider).model ?? "-")")
        if config.provider != .bedrock {
            print("api key:     \(APIKeys.load(config.provider) == nil ? "✗ none" : "found")")
        } else { do {
            let resolved = try AWSSharedConfig.load(profile: config.awsProfile)
            let region = config.region ?? resolved.region ?? "us-east-1"
            print("aws:         profile \(config.awsProfile), region \(region), credentials found")
        } catch {
            print("aws:         ✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        } }
    } catch {
        print("config:      ✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }
    let rimeShared = RimeDirectories.shared?.path ?? "?"
    let hasData = FileManager.default.fileExists(atPath: rimeShared + "/build/rime_ice.table.bin")
    print("rime:        librime \(RimeService.shared.version), data \(hasData ? "bundled" : "✗ missing") (\(rimeShared))")
    print("rime user:   \(RimeDirectories.user.path)")

    guard let source = R.source() else {
        print("registered:  no (\(R.sourceID))")
        return 1
    }
    print("registered:  yes (\(R.sourceID))")
    print("name:        \(R.string(source, kTISPropertyLocalizedName) ?? "?")")
    print("type:        \(R.string(source, kTISPropertyInputSourceType) ?? "?")")
    if let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
       let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String] {
        print("languages:   \(languages.joined(separator: ", "))")
    }
    print("enabled:     \(R.bool(source, kTISPropertyInputSourceIsEnabled))")
    print("listed:      \(R.isInUserList) (in your input sources, which Ctrl+Space goes through)")
    print("selectable:  \(R.bool(source, kTISPropertyInputSourceIsSelectCapable))")
    print("selected:    \(R.bool(source, kTISPropertyInputSourceIsSelected))")
    print("current:     \(R.currentSourceID() ?? "?")")
    return 0
}

let arguments = Array(CommandLine.arguments.dropFirst())

// A script plugin's own process (started by the input method): nothing else runs, nothing else is printed.
if arguments.first == "--run-plugin" {
    exit(arguments.count > 1 ? PluginHost.run(directory: arguments[1]) : 2)
}
// The same for `@js` code (`InlineCode`): the code on standard input, what it prints on standard output.
if arguments.first == InlineCode.javaScriptHostOption {
    exit(InlineCode.runJavaScriptHost())
}

// Data from the AIPinyin days moves to the AllInOneIME folders before anything reads it.
for (path, outcome) in LegacyData.migrate() where outcome != .nothingToMove {
    switch outcome {
    case .moved: log.notice("moved legacy data to \(path, privacy: .public)")
    case .keptBoth: log.notice("legacy data left in place: \(path, privacy: .public) exists")
    case let .failed(error): log.error("could not move legacy data to \(path, privacy: .public): \(error, privacy: .public)")
    case .nothingToMove: break
    }
    if arguments.first?.hasPrefix("--") == true {
        switch outcome {
        case .moved: print("data:        moved from the AIPinyin folder to \(path)")
        case .keptBoth: print("data:        \(path) exists; the old AIPinyin folder was left as it is")
        case let .failed(error): printError("data:        could not move the AIPinyin folder to \(path): \(error)")
        case .nothingToMove: break
        }
    }
}

switch arguments.first {
case "--register":
    exit(register())
case "--disable":
    exit(disable())
case "--status":
    exit(printStatus())
case "--selftest":
    let directory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "/tmp/allinoneime-selftest")
    exit(MainActor.assumeIsolated { SelfTest.run(snapshotDirectory: directory) })
case "--settings":
    // Started by the AllInOneIME Settings app: serve as the input method and show the settings window.
    runServer(showSettings: true)
case "-h", "--help":
    print(usage)
    exit(0)
case let flag? where flag.hasPrefix("--"):
    printError("unknown option \(flag)\n\n\(usage)")
    exit(2)
default:
    // Launched by the system (possibly with -psn_… or other AppKit arguments).
    runServer()
}
