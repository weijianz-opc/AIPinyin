// "AI 拼音设置": a small app in ~/Applications so the settings are easy to find (Spotlight,
// Launchpad, Finder). macOS only shows options for its own input methods in System Settings,
// so third-party input methods ship their own entry point like this one.
//
// It opens the input method with --settings: a running input method gets a reopen event and
// shows its settings window; one that isn't running yet starts and shows it.
import AppKit

let inputMethodID = "com.aipinyin.inputmethod.AIPinyin"
let installed = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Input Methods/AIPinyin.app")

func fail(_ message: String) -> Never {
    let alert = NSAlert()
    alert.messageText = "打不开 AI 拼音设置"
    alert.informativeText = message
    alert.runModal()
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let url = FileManager.default.fileExists(atPath: installed.path)
    ? installed
    : NSWorkspace.shared.urlForApplication(withBundleIdentifier: inputMethodID)
guard let url else { fail("没有找到 AI 拼音输入法（~/Library/Input Methods/AIPinyin.app），请先安装。") }

let configuration = NSWorkspace.OpenConfiguration()
configuration.arguments = ["--settings"]
configuration.activates = true
// macOS 14+ cooperative activation: hand our activation to the input method so its window can
// come to the front.
NSApp.yieldActivation(toApplicationWithBundleIdentifier: inputMethodID)
NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
    DispatchQueue.main.async {
        if let error { fail(error.localizedDescription) }
        exit(0)
    }
}
app.run()
