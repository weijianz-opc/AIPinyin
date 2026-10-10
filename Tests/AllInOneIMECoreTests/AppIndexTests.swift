import Foundation
import Testing
@testable import AllInOneIMECore

/// The app index over a folder of stand-in bundles (Info.plist and localized names only).
struct AppIndexTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func plist(_ dictionary: [String: Any], at path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0).write(to: url)
    }

    func strings(_ text: String, at path: String, encoding: String.Encoding = .utf8) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: encoding)!.write(to: url)
    }

    func makeApps() throws {
        // Newer system apps: the names in Info.plist (English), the others in InfoPlist.loctable.
        try plist(["CFBundleDisplayName": "Calculator", "CFBundleName": "Calculator"], at: "Calculator.app/Contents/Info.plist")
        try plist(["zh_CN": ["CFBundleDisplayName": "计算器", "CFBundleName": "计算器"], "zh_TW": ["CFBundleDisplayName": "計算機"],
                   "de": ["CFBundleDisplayName": "Rechner"], "LocProvenance": ["zh_CN": 1]],
                  at: "Calculator.app/Contents/Resources/InfoPlist.loctable")
        try plist(["CFBundleDisplayName": "FindMy"], at: "FindMy.app/Contents/Info.plist")
        try plist(["en": ["CFBundleDisplayName": "Find My"], "zh_CN": ["CFBundleDisplayName": "查找"]],
                  at: "FindMy.app/Contents/Resources/InfoPlist.loctable")
        // Other apps: <language>.lproj/InfoPlist.strings, UTF-16 or UTF-8.
        try plist(["CFBundleDisplayName": "WeChat", "CFBundleName": "WeChat"], at: "WeChat.app/Contents/Info.plist")
        try strings("\"CFBundleDisplayName\" = \"微信\";\n\"NSCameraUsageDescription\" = \"…\";\n",
                    at: "WeChat.app/Contents/Resources/zh-Hans.lproj/InfoPlist.strings", encoding: .utf16)
        try strings("/* Localized */\n\"CFBundleName\" = \"微信\";\n", at: "WeChat.app/Contents/Resources/zh-Hant.lproj/InfoPlist.strings")
        // In a folder inside: found; two levels down: not.
        try plist(["CFBundleName": "Terminal"], at: "Utilities/Terminal.app/Contents/Info.plist")
        try plist(["zh_CN": ["CFBundleName": "终端"]], at: "Utilities/Terminal.app/Contents/Resources/InfoPlist.loctable")
        try plist(["CFBundleName": "Deep"], at: "Games/More/Deep.app/Contents/Info.plist")
        // An iPhone app installed on the Mac: its bundle is wrapped, Chinese is its own language.
        try plist(["CFBundleDisplayName": "小红书", "CFBundleName": "discover"], at: "rednote.app/Wrapper/discover.app/Info.plist")
        try strings("\"CFBundleDisplayName\" = \"rednote\";", at: "rednote.app/Wrapper/discover.app/en.lproj/InfoPlist.strings")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("rednote.app/WrappedBundle").path,
                                                   withDestinationPath: "Wrapper/discover.app")
        // No Info.plist at all, a hidden app, a file: the first by its file name, the others not at all.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Plain.app/Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".Hidden.app/Contents"), withIntermediateDirectories: true)
        try strings("not an app", at: "notes.app.txt")
    }

    func apps(_ index: AppIndex, now: Date) -> [String: AppIndex.App] {
        Dictionary(index.apps(now: now).map { (($0.path as NSString).lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func knowsEveryNameOfEachApp() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApps()
        // The folder inside listed as a folder of its own too, and one that doesn't exist: each app once.
        let index = AppIndex(folders: [root.path, root.appendingPathComponent("Utilities").path, root.path + "/Missing"])
        let all = index.apps(now: Date())
        #expect(all.map { ($0.path as NSString).lastPathComponent }.sorted()
            == ["Calculator.app", "FindMy.app", "Plain.app", "Terminal.app", "WeChat.app", "rednote.app"])
        let apps = apps(index, now: Date())
        #expect(apps["Calculator.app"] == AppIndex.App(path: root.path + "/Calculator.app", english: "Calculator", chinese: "计算器",
                                                       names: ["Calculator", "计算器", "計算機"]))
        #expect(apps["FindMy.app"]?.english == "Find My" && apps["FindMy.app"]?.chinese == "查找")
        #expect(apps["FindMy.app"]?.names == ["FindMy", "Find My", "查找"])
        #expect(apps["WeChat.app"]?.english == "WeChat" && apps["WeChat.app"]?.chinese == "微信" && apps["WeChat.app"]?.names == ["WeChat", "微信"])
        #expect(apps["Terminal.app"]?.chinese == "终端" && apps["Terminal.app"]?.path == root.path + "/Utilities/Terminal.app")
        #expect(apps["rednote.app"] == AppIndex.App(path: root.path + "/rednote.app", english: "rednote", chinese: "小红书",
                                                    names: ["rednote", "小红书", "discover"]))
        #expect(apps["Plain.app"] == AppIndex.App(path: root.path + "/Plain.app", english: "Plain", names: ["Plain"]))
        // What @open makes of them.
        let found = all.map { FileSearchRanking.Found(path: $0.path, names: $0.names) }
        func open(_ query: String) -> [String] {
            FileSearchRanking.search(query, limit: 8, history: OpenHistory(), apps: found, isCandidate: { _ in true },
                                     byName: { _ in [] }, byContent: { _ in [] })
                .map { ($0.path as NSString).lastPathComponent }
        }
        #expect(open("计算器") == ["Calculator.app"] && open("計算機") == ["Calculator.app"] && open("calc") == ["Calculator.app"])
        #expect(open("微信") == ["WeChat.app"] && open("小红书") == ["rednote.app"] && open("终端") == ["Terminal.app"])
        #expect(open("find my") == ["FindMy.app"] && open("utilities 终端") == ["Terminal.app"])
    }

    @Test func isBuiltAgainOnlyWhenAFolderChanged() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApps()
        let index = AppIndex(folders: [root.path], recheckInterval: 30)
        let start = Date()
        #expect(apps(index, now: start)["WeChat.app"]?.chinese == "微信")
        // Inside a bundle: the folders keep their dates, the index stays as it is.
        try strings("\"CFBundleDisplayName\" = \"微信 2\";", at: "WeChat.app/Contents/Resources/zh-Hans.lproj/InfoPlist.strings")
        #expect(apps(index, now: start.addingTimeInterval(31))["WeChat.app"]?.chinese == "微信")
        // A new app: not looked for within 30 seconds of the last look, then found (and the rest read again).
        try plist(["CFBundleName": "Notes"], at: "Notes.app/Contents/Info.plist")
        #expect(apps(index, now: start.addingTimeInterval(40))["Notes.app"] == nil)
        let rebuilt = apps(index, now: start.addingTimeInterval(62))
        #expect(rebuilt["Notes.app"] != nil && rebuilt["WeChat.app"]?.chinese == "微信 2")
        // In a folder inside too.
        try plist(["CFBundleName": "Console"], at: "Utilities/Console.app/Contents/Info.plist")
        #expect(apps(index, now: start.addingTimeInterval(93))["Console.app"] != nil)
        // Removed.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Notes.app"))
        #expect(apps(index, now: start.addingTimeInterval(124))["Notes.app"] == nil)
    }

    @Test func aMissingFolderThatAppearsIsLookedIn() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let later = root.appendingPathComponent("Applications")
        let index = AppIndex(folders: [later.path])
        let start = Date()
        #expect(index.apps(now: start).isEmpty)
        try plist(["CFBundleName": "Safari"], at: "Applications/Safari.app/Contents/Info.plist")
        #expect(index.apps(now: start.addingTimeInterval(31)).map(\.english) == ["Safari"])
    }
}
