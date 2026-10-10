import Foundation

/// The apps in the folders apps are installed in, with every name each goes by. Spotlight knows an app
/// by its file name and its name in the system language only: on an English system 计算器 doesn't find
/// Calculator.app. Built when first asked for (off the main thread: it reads every app's Info.plist and
/// localized names), then kept, and built again when one of the folders changed (by their modification
/// dates, compared at most every `recheckInterval`).
public final class AppIndex: @unchecked Sendable {
    public struct App: Equatable, Sendable {
        public var path: String
        /// Its name in an English interface ("Calculator"), and in a Chinese one (计算器; nil: none known).
        public var english: String
        public var chinese: String?
        /// Every name it goes by, to match what is typed: the file name without ".app", the bundle's names,
        /// its English and Chinese (simplified and traditional) ones.
        public var names: [String]

        public init(path: String, english: String, chinese: String? = nil, names: [String]) {
            self.path = path
            self.english = english
            self.chinese = chinese
            self.names = names
        }
    }

    /// Where apps are installed. The folders directly inside these are looked in too ("Chrome Apps.localized").
    public static let standardFolders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                                         "/System/Applications/Utilities", "~/Applications"]

    public static let shared = AppIndex()

    private let folders: [String]
    private let recheckInterval: TimeInterval
    private let lock = NSLock()
    /// The apps; every folder looked in, with its modification date then (nil: it didn't exist); when
    /// those dates were last compared.
    private var built: (apps: [App], folders: [String: Date?], checked: Date)?

    public init(folders: [String] = standardFolders, recheckInterval: TimeInterval = 30) {
        self.folders = folders.map { ($0 as NSString).expandingTildeInPath }
        self.recheckInterval = recheckInterval
    }

    /// The apps as of `now`: built again first when one of the folders changed.
    public func apps(now: Date = Date()) -> [App] {
        // Held while building (a fraction of a second): a second search waits for the same index.
        lock.withLock {
            if let built {
                if now.timeIntervalSince(built.checked) < recheckInterval { return built.apps }
                if built.folders.allSatisfy({ Self.modificationDate($0.key) == $0.value }) {
                    self.built?.checked = now
                    return built.apps
                }
            }
            let scan = Self.scan(folders)
            built = (scan.apps, scan.folders, now)
            return scan.apps
        }
    }

    /// The apps in `roots` and in the folders directly inside them, each once, and the folders looked in.
    static func scan(_ roots: [String]) -> (apps: [App], folders: [String: Date?]) {
        var apps: [App] = [], seen = Set<String>(), looked: [String: Date?] = [:], inside: [String] = []
        func look(in folder: String, isRoot: Bool) {
            guard looked[folder] == nil else { return }
            looked[folder] = .some(modificationDate(folder))
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                let path = (folder as NSString).appendingPathComponent(entry)
                guard isDirectory(path) else { continue }
                if (entry as NSString).pathExtension.lowercased() == "app" {
                    if seen.insert(path).inserted { apps.append(app(at: path)) }
                } else if isRoot {
                    inside.append(path)
                }
            }
        }
        for root in roots { look(in: root, isRoot: true) }
        for folder in inside { look(in: folder, isRoot: false) }
        return (apps, looked)
    }

    /// What the app at `path` is called: its Info.plist, and its localized InfoPlist strings
    /// (`<language>.lproj/InfoPlist.strings`, or the `InfoPlist.loctable` that newer system apps have
    /// instead). An iPhone or iPad app installed on a Mac keeps them in its wrapped bundle.
    static func app(at path: String) -> App {
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var contents = path + "/Contents", resources = contents + "/Resources"
        let wrapped = path + "/WrappedBundle"
        if !FileManager.default.fileExists(atPath: contents + "/Info.plist"),
           FileManager.default.fileExists(atPath: wrapped + "/Info.plist") {
            contents = wrapped
            resources = wrapped
        }
        let info = bundleNames(dictionary(at: contents + "/Info.plist"))
        let table = dictionary(at: resources + "/InfoPlist.loctable")
        func names(_ languages: [String]) -> [String] {
            languages.flatMap { language in
                bundleNames(table[language] as? [String: Any] ?? dictionary(at: resources + "/\(language).lproj/InfoPlist.strings"))
            }
        }
        let english = names(["en", "English", "en_US", "en-US"])
        let simplified = names(["zh-Hans", "zh_CN", "zh-CN", "zh"])
        let traditional = names(["zh-Hant", "zh_TW", "zh-TW", "zh_HK", "zh-HK"])
        let base = names(["Base"])
        // An app made for China may have its Chinese name in Info.plist itself, and no Chinese strings.
        let chinese = simplified.first ?? (info + base).first(where: \.containsHan)
        var seen = Set<String>()
        let all = ([fileName] + info + english + simplified + traditional + base).filter {
            seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted
        }
        return App(path: path, english: english.first ?? info.first(where: { !$0.containsHan }) ?? fileName,
                   chinese: chinese, names: all)
    }

    /// CFBundleDisplayName and CFBundleName, those that are there.
    static func bundleNames(_ strings: [String: Any]) -> [String] {
        ["CFBundleDisplayName", "CFBundleName"].compactMap {
            (strings[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    /// A property list or strings file (binary, XML, text; UTF-8 or UTF-16) as a dictionary; empty if
    /// there is none.
    static func dictionary(at path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
