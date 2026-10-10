import CryptoKit
import Foundation

/// Text in English and Chinese: `"…"` or `{"en": "…", "zh": "…"}` in a manifest.
public struct LocalizedText: Codable, Equatable, Hashable, Sendable {
    public var en: String
    public var zh: String?

    public init(en: String, zh: String? = nil) {
        self.en = en
        self.zh = zh
    }

    public func text(chinese: Bool) -> String { chinese ? (zh ?? en) : en }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            self.init(en: single)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(en: try c.decode(String.self, forKey: .en), zh: try c.decodeIfPresent(String.self, forKey: .zh))
    }
}

/// A plugin's `plugin.json` (see docs/plugins.md).
public struct PluginManifest: Codable, Equatable, Hashable, Sendable {
    public enum PluginType: String, Codable, Sendable {
        /// JavaScript (`script`) run in a child process, with `fetch` to `hosts`.
        case script
        /// An AI instruction (`prompt`), like a custom command.
        case prompt
    }

    public var name: String
    public var version: String
    /// The script contract version (`fetch`, `run`); the app refuses newer ones.
    public var api: Int
    public var minAppVersion: String?
    public var type: PluginType
    public var summary: LocalizedText?
    public var script: String?
    public var prompt: String?
    /// The only hosts a script may contact (HTTPS).
    public var hosts: [String]
    public var timeoutSeconds: Double?
    public var ascii: Bool?
    public var author: String?
    public var homepage: String?
    /// Its icon in the command list: an SF Symbol name and a color (see `CustomCommand.icon`).
    public var icon: String?
    public var color: String?

    public init(name: String, version: String, api: Int = 1, minAppVersion: String? = nil, type: PluginType,
                summary: LocalizedText? = nil, script: String? = nil, prompt: String? = nil, hosts: [String] = [],
                timeoutSeconds: Double? = nil, ascii: Bool? = nil, author: String? = nil, homepage: String? = nil) {
        self.name = name
        self.version = version
        self.api = api
        self.minAppVersion = minAppVersion
        self.type = type
        self.summary = summary
        self.script = script
        self.prompt = prompt
        self.hosts = hosts
        self.timeoutSeconds = timeoutSeconds
        self.ascii = ascii
        self.author = author
        self.homepage = homepage
    }

    public static let supportedAPI = 1
    public static let maxTimeout: Double = 20
    public static let maxScriptBytes = 64 * 1024

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        api = try c.decodeIfPresent(Int.self, forKey: .api) ?? 1
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
        type = try c.decode(PluginType.self, forKey: .type)
        summary = try c.decodeIfPresent(LocalizedText.self, forKey: .summary)
        script = try c.decodeIfPresent(String.self, forKey: .script)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        ascii = try c.decodeIfPresent(Bool.self, forKey: .ascii)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }

    public var timeout: Double { min(max(timeoutSeconds ?? 10, 1), Self.maxTimeout) }
    public var typesLatin: Bool { ascii ?? (type == .script) }

    /// Why this app can't use the plugin, or nil.
    public func problem(appVersion: String) -> String? {
        guard !name.isEmpty, name.count <= 24, name.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else {
            return "the name must be lowercase letters"
        }
        if api > Self.supportedAPI { return "needs a newer AllInOneIME (plugin API \(api))" }
        if let min = minAppVersion, SemVer.compare(appVersion, min) < 0 { return "needs AllInOneIME \(min) or later" }
        switch type {
        case .script:
            guard let script, !script.isEmpty, !script.contains("/"), !script.hasPrefix(".") else { return "no script" }
            if hosts.contains(where: { $0.isEmpty || $0.contains("/") || $0.contains(":") }) { return "invalid hosts" }
        case .prompt:
            if (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "no prompt" }
        }
        return nil
    }
}

/// A plugin as installed: its manifest and folder.
public struct InstalledPlugin: Equatable, Hashable, Sendable {
    public var manifest: PluginManifest
    public var directory: URL
    /// Not from the library (no install record): an author's own, not reviewed.
    public var isLocal: Bool

    public var name: String { manifest.name }
    public var scriptURL: URL? { manifest.script.map { directory.appendingPathComponent($0) } }

    public init(manifest: PluginManifest, directory: URL, isLocal: Bool) {
        self.manifest = manifest
        self.directory = directory
        self.isLocal = isLocal
    }
}

/// What the library writes next to an installed plugin: the version and every file's sha256.
public struct PluginInstallRecord: Codable, Equatable, Sendable {
    public var version: String
    public var files: [String: String]
    public var source: String

    public init(version: String, files: [String: String], source: String = "registry") {
        self.version = version
        self.files = files
        self.source = source
    }
}

/// The plugins in ~/.config/allinoneime/plugins.
public enum PluginStore {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/allinoneime/plugins", isDirectory: true)
    }

    /// A plugin folder that can't be used, and why (shown in Settings).
    public struct Skipped: Equatable, Sendable {
        public var folder: String
        public var reason: String
    }

    /// The usable plugins in `directory`, by name, and the folders skipped. A library plugin whose files
    /// changed since it was installed is skipped (its hashes no longer match the install record).
    public static func load(from directory: URL = directory, appVersion: String = AppVersion.string)
        -> (plugins: [InstalledPlugin], skipped: [Skipped]) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return ([], []) }
        var plugins: [InstalledPlugin] = []
        var skipped: [Skipped] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  !folder.lastPathComponent.hasSuffix(".tmp") else { continue }
            func skip(_ reason: String) { skipped.append(Skipped(folder: folder.lastPathComponent, reason: reason)) }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("plugin.json")),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
                skip("no readable plugin.json")
                continue
            }
            if let problem = manifest.problem(appVersion: appVersion) {
                skip(problem)
                continue
            }
            if manifest.name != folder.lastPathComponent {
                skip("the folder must be named \(manifest.name)")
                continue
            }
            let recordURL = folder.appendingPathComponent("install.json")
            let record = (try? Data(contentsOf: recordURL)).flatMap { try? JSONDecoder().decode(PluginInstallRecord.self, from: $0) }
            if let record {
                let changed = record.files.contains { name, hash in
                    sha256(of: folder.appendingPathComponent(name)) != hash
                }
                if changed {
                    skip("its files changed since it was installed")
                    continue
                }
            }
            plugins.append(InstalledPlugin(manifest: manifest, directory: folder, isLocal: record == nil))
        }
        return (plugins, skipped)
    }

    public static func uninstall(_ plugin: InstalledPlugin) throws {
        try FileManager.default.removeItem(at: plugin.directory)
    }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Version strings like "1.2.10": compared number by number (missing parts are 0; anything after
/// a "-" is ignored).
public enum SemVer {
    public static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            (s.split(separator: "-").first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
