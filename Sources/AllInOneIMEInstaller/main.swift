// 「安装 AllInOneIME」 (Install AllInOneIME): the installer on the release disk image (`make dmg`).
// Opened from Finder it asks first, then installs, updates or uninstalls AllInOneIME for this user
// (see Installer). --install and --uninstall do the same from a terminal without asking.
import AllInOneIMECore
import AppKit

/// Chinese if picked in the settings (`uiLanguage`), else if the system prefers Chinese to English,
/// as in the input method.
let chinese: Bool = {
    if let picked = (try? Config.load())?.uiLanguage { return picked == .chinese }
    let preferred = Locale.preferredLanguages.first { $0.hasPrefix("zh") || $0.hasPrefix("en") }
    return preferred?.hasPrefix("zh") == true
}()

func tr(_ zh: String, _ en: String) -> String { chinese ? zh : en }

/// The version this installer carries.
let newVersion = Installer.version

let manualAddHint = tr(
    """
    AllInOneIME 还不在你的输入法列表里，请自己添加一次：
    系统设置 → 键盘 → 文字输入 › 输入法「编辑…」→ 左下角 + → 简体中文 → AllInOneIME → 添加
    之后用 Ctrl+空格 切换到 AllInOneIME。
    """,
    """
    AllInOneIME isn't in your input sources yet, so add it once yourself:
    System Settings → Keyboard → Text Input → Input Sources → Edit… → + (bottom left) → Chinese, Simplified → AllInOneIME → Add
    Then switch to it with Ctrl+Space.
    """)

// MARK: Terminal

let usage = """
    Install AllInOneIME \(newVersion). Opened from Finder, it asks first; from a terminal:
      --install     install or update AllInOneIME for this user, without asking
      --uninstall   uninstall it, without asking (settings and learned words are kept)
    """

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func runFromTerminal(install: Bool) -> Int32 {
    do {
        if install {
            let output = try Installer.install { print($0) }
            print(output)
            // --register prints how to add it by hand when it couldn't enable it; not when it's
            // enabled but couldn't go into the list.
            let state = Installer.inputSourceState()
            if state.enabled && !state.listed { print("\n" + manualAddHint) }
            print("\n" + tr("AllInOneIME \(newVersion) 装好了。", "AllInOneIME \(newVersion) is installed."))
        } else {
            let output = try Installer.uninstall()
            if !output.isEmpty { print(output) }
            print(tr("AllInOneIME 已卸载。", "AllInOneIME is uninstalled."))
        }
        return 0
    } catch {
        printError(error.localizedDescription)
        return 1
    }
}

// MARK: Finder

/// Shown while the work runs off the main thread.
final class ProgressWindow {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 72),
                                  styleMask: [.titled], backing: .buffered, defer: false)
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init(_ text: String) {
        window.title = "AllInOneIME"
        window.isReleasedWhenClosed = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
        self.text = text
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            spinner.setAccessibilityLabel(newValue)
        }
    }

    func close() { window.orderOut(nil) }
}

final class InstallerDelegate: NSObject, NSApplicationDelegate {
    /// While installing or uninstalling: quitting then could leave half the apps in place.
    var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        DispatchQueue.main.async { self.ask() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        busy ? .terminateCancel : .terminateNow
    }

    /// Esc picks Cancel whatever the interface language (AppKit only does that for a button titled
    /// in the system's language).
    func addCancelButton(to alert: NSAlert) {
        alert.addButton(withTitle: tr("取消", "Cancel")).keyEquivalent = "\u{1b}"
    }

    func ask() {
        let isInstalled = Installer.exists(Installer.inputMethod)
        let installed = Installer.installedVersion() ?? ""
        let alert = NSAlert()
        var details = [tr("输入法装到 ~/Library/Input Methods，「AllInOneIME 设置」装到 ~/Applications，并把 AllInOneIME 加进你的输入法列表。只装给当前用户，不需要管理员密码。",
                          "The input method goes into ~/Library/Input Methods and \"AllInOneIME Settings\" into ~/Applications, and AllInOneIME is added to your input sources. For this user only; no administrator password needed.")]
        let action: String
        // An installed copy whose version can't be read counts as older.
        switch isInstalled ? installed.compare(newVersion, options: .numeric) : nil {
        case nil:
            alert.messageText = tr("安装 AllInOneIME \(newVersion)？", "Install AllInOneIME \(newVersion)?")
            action = tr("安装", "Install")
        case .orderedAscending?:
            let from = installed.isEmpty ? "" : " \(installed)"
            alert.messageText = tr("把 AllInOneIME\(from) 更新到 \(newVersion)？", "Update AllInOneIME\(from) to \(newVersion)?")
            action = tr("更新", "Update")
        case .orderedSame?:
            alert.messageText = tr("重新安装 AllInOneIME \(newVersion)？", "Reinstall AllInOneIME \(newVersion)?")
            action = tr("重新安装", "Reinstall")
        case .orderedDescending?:
            alert.messageText = tr("安装 AllInOneIME \(newVersion)？", "Install AllInOneIME \(newVersion)?")
            details.append(tr("已安装的 \(installed) 比它新，会被换成 \(newVersion)。", "The installed \(installed) is newer; it will be replaced by \(newVersion)."))
            action = tr("安装", "Install")
        }
        if isInstalled {
            details.append(tr("设置、黑话库和学到的词都会保留。", "Your settings, jargon list and learned words are kept."))
        }
        if Installer.hasLegacyInstall {
            details.append(tr("旧的 AI 拼音（AIPinyin）会被替换，设置和学到的词会搬过来。",
                              "The old AIPinyin (AI 拼音) is replaced; its settings and learned words move over."))
        }
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: action)
        addCancelButton(to: alert)
        if isInstalled || Installer.hasLegacyInstall {
            alert.addButton(withTitle: tr("卸载…", "Uninstall…"))
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            perform(tr("正在安装…", "Installing…"), { step in try Installer.install(step: step) }, then: { _ in self.installed() })
        case .alertThirdButtonReturn:
            confirmUninstall()
        default:
            NSApp.terminate(nil)
        }
    }

    func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = tr("卸载 AllInOneIME？", "Uninstall AllInOneIME?")
        alert.informativeText = tr(
            "会停用 AllInOneIME、把它移出输入法列表，并删掉输入法和「AllInOneIME 设置」。\n\n设置、黑话库和学到的词会保留（~/.config/allinoneime 和 ~/Library/Application Support/AllInOneIME），以后重新安装还能用。",
            "This disables AllInOneIME, removes it from your input sources, and deletes the input method and \"AllInOneIME Settings\".\n\nYour settings, jargon list and learned words are kept (~/.config/allinoneime and ~/Library/Application Support/AllInOneIME) for when you install it again.")
        alert.addButton(withTitle: tr("卸载", "Uninstall")).hasDestructiveAction = true
        addCancelButton(to: alert)
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }
        perform(tr("正在卸载…", "Uninstalling…"), { _ in try Installer.uninstall() }, then: { _ in
            self.finish(tr("AllInOneIME 已卸载", "AllInOneIME is uninstalled"),
                        tr("设置、黑话库和学到的词还留着。要一起删掉，见 Wiki「安装与排查」里的「卸载」。",
                           "Your settings, jargon list and learned words are still there. To delete them too, see \"Uninstall\" in Installation and Troubleshooting on the wiki."))
        })
    }

    /// Runs `work` off the main thread with a progress window, then `then` or the error.
    func perform(_ title: String, _ work: @escaping (@escaping (String) -> Void) throws -> String,
                 then: @escaping (String) -> Void) {
        let progress = ProgressWindow(title)
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work { step in DispatchQueue.main.async { progress.text = step } } }
            DispatchQueue.main.async {
                self.busy = false
                progress.close()
                switch result {
                case let .success(output): then(output)
                case let .failure(error):
                    self.finish(tr("没有完成", "That didn't work"), error.localizedDescription, style: .critical)
                }
            }
        }
    }

    func installed() {
        let state = Installer.inputSourceState()
        guard state.enabled && state.listed else {
            finish(tr("还差一步：添加输入法", "One more step: add the input source"), manualAddHint,
                   button: tr("打开键盘设置", "Open Keyboard Settings")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                NSApp.terminate(nil)
            }
            return
        }
        finish(tr("AllInOneIME \(newVersion) 装好了", "AllInOneIME \(newVersion) is installed"),
               tr("用 Ctrl+空格 切换到 AllInOneIME，或者在菜单栏的输入法菜单里选它。\n\n要用 @improve 和 @question，先在「AllInOneIME 设置」里配置 Amazon Bedrock（用你自己的 AWS 账号）。",
                  "Switch to AllInOneIME with Ctrl+Space, or choose it in the input menu in the menu bar.\n\nFor @improve and @question, set up Amazon Bedrock (your own AWS account) in AllInOneIME Settings first."),
               button: tr("打开 AllInOneIME 设置", "Open AllInOneIME Settings")) {
            NSWorkspace.shared.openApplication(at: Installer.settingsApp, configuration: .init()) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    /// The last dialog: `button` (runs `action`, which quits when it's done) and Done (quits).
    func finish(_ message: String, _ details: String, style: NSAlert.Style = .informational,
                button: String? = nil, action: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = details
        if let button { alert.addButton(withTitle: button) }
        alert.addButton(withTitle: tr("完成", "Done"))
        let response = alert.runModal()
        if button != nil, response == .alertFirstButtonReturn, let action {
            action()
            return
        }
        NSApp.terminate(nil)
    }
}

// MARK: Start

switch CommandLine.arguments.dropFirst().first {
case "--install":
    exit(runFromTerminal(install: true))
case "--uninstall":
    exit(runFromTerminal(install: false))
case "-h", "--help":
    print(usage)
    exit(0)
case let flag? where flag.hasPrefix("--"):
    printError("unknown option \(flag)\n\n\(usage)")
    exit(2)
default:
    // Opened from Finder (possibly with -psn_… or other AppKit arguments).
    let app = NSApplication.shared
    let delegate = InstallerDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    let quit = NSMenuItem(title: tr("退出", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let appMenu = NSMenuItem()
    appMenu.submenu = NSMenu()
    appMenu.submenu?.addItem(quit)
    app.mainMenu = NSMenu()
    app.mainMenu?.addItem(appMenu)
    app.run()
}
