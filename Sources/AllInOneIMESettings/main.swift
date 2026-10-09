// AllInOneIME Settings (「AllInOneIME 设置」): a small app in ~/Applications so the settings are easy
// to find (Spotlight, Launchpad, Finder). macOS only shows options for its own input methods in
// System Settings, so third-party input methods ship their own entry point like this one.
//
// It opens the input method with --settings: a running input method gets a reopen event and
// shows its settings window; one that isn't running yet starts and shows it.
import AppKit

let inputMethodID = "com.aipinyin.inputmethod.AIPinyin"
let home = FileManager.default.homeDirectoryForCurrentUser
let installed = home.appendingPathComponent("Library/Input Methods/AllInOneIME.app")

/// Chinese if picked in the settings (`uiLanguage`), else if the system prefers Chinese to English,
/// as in the input method.
let chinese: Bool = {
    let config = home.appendingPathComponent(".config/allinoneime/config.json")
    if let data = try? Data(contentsOf: config),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let picked = json["uiLanguage"] as? String {
        return picked == "zh"
    }
    let preferred = Locale.preferredLanguages.first { $0.hasPrefix("zh") || $0.hasPrefix("en") }
    return preferred?.hasPrefix("zh") == true
}()

func fail(_ message: String) -> Never {
    let alert = NSAlert()
    alert.messageText = chinese ? "打不开 AllInOneIME 设置" : "Can't open AllInOneIME Settings"
    alert.informativeText = message
    alert.runModal()
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let url = FileManager.default.fileExists(atPath: installed.path)
    ? installed
    : NSWorkspace.shared.urlForApplication(withBundleIdentifier: inputMethodID)
guard let url else {
    fail(chinese ? "没有找到 AllInOneIME 输入法（~/Library/Input Methods/AllInOneIME.app），请先安装。"
                 : "The AllInOneIME input method isn't installed (~/Library/Input Methods/AllInOneIME.app).")
}

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
