import CryptoKit
import Foundation

/// The plugin library's `index.json` (see docs/plugins.md): every plugin version on offer, with the
/// sha256 of each of its files. Only ever built from bytes whose signature was verified.
public struct PluginIndex: Decodable, Equatable, Sendable {
    public var schema: Int
    public var generated: String?
    public var plugins: [Entry]

    public struct Entry: Decodable, Equatable, Hashable, Sendable, Identifiable {
        public var name: String
        public var version: String
        public var api: Int
        public var minAppVersion: String?
        /// Kept as text: a library may offer types this app doesn't know yet (they are left out).
        public var type: String
        public var summary: LocalizedText?
        public var hosts: [String]
        public var author: String?
        public var homepage: String?
        public var icon: String?
        public var color: String?
        /// A `link` plugin's address.
        public var url: String?
        /// The folder of this version, relative to the library: "plugins/stock/1.0.0/".
        public var base: String
        /// File name → sha256 (hex).
        public var files: [String: String]

        public var id: String { name + "@" + version }

        public init(name: String, version: String, api: Int = 1, minAppVersion: String? = nil, type: String = "script",
                    summary: LocalizedText? = nil, hosts: [String] = [], author: String? = nil, homepage: String? = nil,
                    icon: String? = nil, color: String? = nil, url: String? = nil, base: String, files: [String: String]) {
            self.name = name
            self.version = version
            self.api = api
            self.minAppVersion = minAppVersion
            self.type = type
            self.summary = summary
            self.hosts = hosts
            self.author = author
            self.homepage = homepage
            self.icon = icon
            self.color = color
            self.url = url
            self.base = base
            self.files = files
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            version = try c.decode(String.self, forKey: .version)
            api = try c.decodeIfPresent(Int.self, forKey: .api) ?? 1
            minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
            type = try c.decode(String.self, forKey: .type)
            summary = try c.decodeIfPresent(LocalizedText.self, forKey: .summary)
            hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
            author = try c.decodeIfPresent(String.self, forKey: .author)
            homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
            icon = try c.decodeIfPresent(String.self, forKey: .icon)
            color = try c.decodeIfPresent(String.self, forKey: .color)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            base = try c.decode(String.self, forKey: .base)
            files = try c.decode([String: String].self, forKey: .files)
        }

        private enum CodingKeys: String, CodingKey {
            case name, version, api, minAppVersion, type, summary, hosts, author, homepage, icon, color, url, base, files
        }
    }

    public init(schema: Int, generated: String? = nil, plugins: [Entry]) {
        self.schema = schema
        self.generated = generated
        self.plugins = plugins
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        generated = try c.decodeIfPresent(String.self, forKey: .generated)
        // An entry this app can't read (a field a later schema changed) is left out, not the whole index.
        plugins = try c.decode([Lenient].self, forKey: .plugins).compactMap(\.entry)
    }

    private enum CodingKeys: String, CodingKey { case schema, generated, plugins }

    private struct Lenient: Decodable {
        var entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }
}

public enum PluginLibraryError: Error, LocalizedError, Equatable {
    /// The library couldn't be reached (no network, …).
    case unreachable(String)
    case http(status: Int, file: String)
    case tooLarge(String)
    case missingSignature
    /// The index isn't signed by the library's key: tampered with, or caught mid-update.
    case badSignature
    case unsupportedSchema(Int)
    case malformedIndex
    case invalidName(String)
    /// A file name that could leave the plugin's folder, or a bad hash or base in the index.
    case invalidFile(String)
    case hashMismatch(String)
    case invalidManifest(String)
    case incompatible(String)
    /// A local plugin (no install record) has the name: never overwritten by the library.
    case localPlugin(String)

    public var errorDescription: String? {
        switch self {
        case let .unreachable(host): return "Can't reach \(host)"
        case let .http(status, file): return "The plugin library answered HTTP \(status) for \(file)"
        case let .tooLarge(file): return "\(file) is too large"
        case .missingSignature: return "The plugin library's index isn't signed"
        case .badSignature:
            return "The plugin library's index failed its signature check (it may be mid-update: try again in a few minutes)"
        case let .unsupportedSchema(schema): return "The plugin library needs a newer AllInOneIME (index schema \(schema))"
        case .malformedIndex: return "The plugin library's index can't be read"
        case let .invalidName(name): return "Not a valid plugin name: \(name)"
        case let .invalidFile(file): return "Not a valid file in the plugin: \(file)"
        case let .hashMismatch(file): return "\(file) doesn't match the signed index; nothing was changed"
        case let .invalidManifest(detail): return "The plugin's plugin.json \(detail)"
        case let .incompatible(problem): return "The plugin \(problem)"
        case let .localPlugin(name): return "A local plugin named \(name) is installed; remove it first to install the library's"
        }
    }
}

/// The plugin library: a signed index and the plugins' files, served over HTTPS from `baseURL`.
/// Nothing is read from the index before its signature checks out, and nothing is installed before
/// every file matches the index's sha256. Network only when asked (opening or refreshing the library,
/// installing): no background polling.
public struct PluginLibrary: Sendable {
    public static let defaultBaseURL = URL(string: "https://raw.githubusercontent.com/weijianz-opc/AllInOneIME-plugins/main/")!
    /// The library's Ed25519 public key (raw, base64); its private half is in the maintainer's keychain
    /// (the library repo's scripts/build-index signs with it).
    public static let publicKey = Data(base64Encoded: "UPEZUcV35+GKMGKuBUm+EG2M8jro4F23vyskaCLcBIE=")!
    public static let schema = 1
    public static let maxIndexBytes = 1 << 20
    public static let maxFileBytes = 1 << 20

    /// How an index entry stands against what's installed.
    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        /// Installed from the library, an older version.
        case update(from: String)
        /// A local plugin has the name: the library leaves it alone.
        case local
    }

    public var baseURL: URL
    public var publicKey: Data
    public var session: URLSession
    public var appVersion: String
    public var directory: URL

    public init(baseURL: URL = PluginLibrary.defaultBaseURL, publicKey: Data = PluginLibrary.publicKey, session: URLSession? = nil,
                appVersion: String = AppVersion.string, directory: URL = PluginStore.directory) {
        // A base without the trailing "/" would resolve "index.json" next to it, not inside.
        self.baseURL = baseURL.absoluteString.hasSuffix("/") ? baseURL : URL(string: baseURL.absoluteString + "/")!
        self.publicKey = publicKey
        self.session = session ?? Self.makeSession()
        self.appVersion = appVersion
        self.directory = directory
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }

    /// Where the library lives, for "downloads from …".
    public var host: String { baseURL.host ?? baseURL.absoluteString }

    // MARK: Index

    /// Downloads index.json and its signature and returns the index, once the signature checks out.
    public func fetchIndex() async throws -> PluginIndex {
        async let index = get("index.json", limit: Self.maxIndexBytes)
        async let signature = get("index.json.sig", limit: 4096, missing: PluginLibraryError.missingSignature)
        return try Self.verify(index: try await index, signature: try await signature, publicKey: publicKey)
    }

    /// The index in `data`, if `signature` (base64) is the library key's signature of exactly these bytes.
    /// The signature is checked before the index is parsed at all.
    public static func verify(index data: Data, signature: Data, publicKey: Data) throws -> PluginIndex {
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PluginLibraryError.missingSignature }
        guard let raw = Data(base64Encoded: text),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(raw, for: data) else { throw PluginLibraryError.badSignature }
        struct Schema: Decodable { var schema: Int }
        guard let schema = try? JSONDecoder().decode(Schema.self, from: data).schema else { throw PluginLibraryError.malformedIndex }
        guard schema == Self.schema else { throw PluginLibraryError.unsupportedSchema(schema) }
        guard let index = try? JSONDecoder().decode(PluginIndex.self, from: data) else { throw PluginLibraryError.malformedIndex }
        return index
    }

    /// What this app can install: per plugin, the newest version whose `api`, `minAppVersion` and type
    /// it supports, by name.
    public func available(_ index: PluginIndex) -> [PluginIndex.Entry] {
        var newest: [String: PluginIndex.Entry] = [:]
        for entry in index.plugins where Self.isValidName(entry.name)
            && entry.api <= PluginManifest.supportedAPI
            && PluginManifest.PluginType(rawValue: entry.type) != nil
            && (entry.minAppVersion.map { SemVer.compare(appVersion, $0) >= 0 } ?? true) {
            if let other = newest[entry.name], SemVer.compare(other.version, entry.version) >= 0 { continue }
            newest[entry.name] = entry
        }
        return newest.values.sorted { $0.name < $1.name }
    }

    // MARK: Installing

    /// `entry` against the plugins folder: not there, installed (this version or newer), an older
    /// library install, or a local plugin of the same name.
    public func status(of entry: PluginIndex.Entry) -> Status {
        let folder = directory.appendingPathComponent(entry.name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return .notInstalled }
        guard let record = Self.installRecord(in: folder) else { return .local }
        return SemVer.compare(record.version, entry.version) < 0 ? .update(from: record.version) : .installed
    }

    /// Installs (or updates to) `entry`: downloads every file into `<name>.tmp/`, checks each sha256 and
    /// the manifest, writes install.json, then swaps the folder into place in one step. Any failure
    /// leaves the existing install as it was and removes the temporary folder. Local plugins are refused.
    @discardableResult
    public func install(_ entry: PluginIndex.Entry) async throws -> InstalledPlugin {
        let base = try Self.validate(entry, baseURL: baseURL)
        let fm = FileManager.default
        let destination = directory.appendingPathComponent(entry.name, isDirectory: true)
        if fm.fileExists(atPath: destination.path), Self.installRecord(in: destination) == nil {
            throw PluginLibraryError.localPlugin(entry.name)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(entry.name + ".tmp", isDirectory: true)
        try? fm.removeItem(at: temporary)  // left over from an interrupted install
        do {
            try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
            for (file, hash) in entry.files.sorted(by: { $0.key < $1.key }) {
                let data = try await get(base.appendingPathComponent(file), name: file, limit: Self.maxFileBytes)
                guard Self.sha256(data) == hash.lowercased() else { throw PluginLibraryError.hashMismatch(file) }
                try data.write(to: temporary.appendingPathComponent(file))
            }
            let manifest = try Self.checkManifest(in: temporary, for: entry, appVersion: appVersion)
            let record = PluginInstallRecord(version: entry.version, files: entry.files.mapValues { $0.lowercased() })
            try JSONEncoder().encode(record).write(to: temporary.appendingPathComponent("install.json"))
            // Checked again right before the swap: a local plugin may have been put there meanwhile.
            if fm.fileExists(atPath: destination.path), Self.installRecord(in: destination) == nil {
                throw PluginLibraryError.localPlugin(entry.name)
            }
            try Self.moveIntoPlace(temporary, destination)
            return InstalledPlugin(manifest: manifest, directory: destination, isLocal: false)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// Plugin names, as folder names: 1-24 lowercase ASCII letters.
    public static func isValidName(_ name: String) -> Bool {
        // Unicode scalars, not Characters: "a" with a combining accent is one Character that sorts between "a" and "z".
        (1...24).contains(name.unicodeScalars.count) && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
    }

    /// A file name the index may list: plain, inside the plugin's folder ("main.js", not "../x", ".hidden"
    /// or "a/b"), and not the install record.
    public static func isValidFileName(_ name: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return (1...64).contains(name.unicodeScalars.count) && name.unicodeScalars.allSatisfy { allowed.contains(Character($0)) }
            && !name.hasPrefix(".")
            && name != "install.json"
    }

    /// The entry's folder URL, once its name, files, hashes and base are safe to use.
    static func validate(_ entry: PluginIndex.Entry, baseURL: URL) throws -> URL {
        guard isValidName(entry.name) else { throw PluginLibraryError.invalidName(entry.name) }
        guard entry.files["plugin.json"] != nil else { throw PluginLibraryError.invalidFile("plugin.json") }
        for (file, hash) in entry.files {
            guard isValidFileName(file) else { throw PluginLibraryError.invalidFile(file) }
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw PluginLibraryError.invalidFile(file) }
        }
        // The base is a plain relative path under the library ("plugins/stock/1.0.0/"): no "..", no
        // percent escapes, no scheme or leading "/" that would point the download elsewhere.
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        let parts = entry.base.split(separator: "/", omittingEmptySubsequences: false).dropLast()
        guard entry.base.hasSuffix("/"), !entry.base.hasPrefix("/"), entry.base.unicodeScalars.allSatisfy({ allowed.contains(Character($0)) }),
              !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let url = URL(string: entry.base, relativeTo: baseURL)?.absoluteURL,
              url.absoluteString.hasPrefix(baseURL.absoluteString) else {
            throw PluginLibraryError.invalidFile(entry.base)
        }
        return url
    }

    /// The downloaded plugin.json: the plugin the index describes (name, version, hosts shown before
    /// installing), usable by this app, with its script among the checked files.
    static func checkManifest(in folder: URL, for entry: PluginIndex.Entry, appVersion: String) throws -> PluginManifest {
        guard let manifest = try? JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: folder.appendingPathComponent("plugin.json"))) else {
            throw PluginLibraryError.invalidManifest("can't be read")
        }
        // A link plugin's address is where the text goes: it must be the one shown before installing.
        guard manifest.name == entry.name, manifest.version == entry.version, Set(manifest.hosts) == Set(entry.hosts),
              manifest.url == entry.url else {
            throw PluginLibraryError.invalidManifest("doesn't match the index")
        }
        if let problem = manifest.problem(appVersion: appVersion) { throw PluginLibraryError.incompatible(problem) }
        if let script = manifest.script, entry.files[script] == nil { throw PluginLibraryError.invalidManifest("names a file the index doesn't list") }
        return manifest
    }

    static func installRecord(in folder: URL) -> PluginInstallRecord? {
        (try? Data(contentsOf: folder.appendingPathComponent("install.json")))
            .flatMap { try? JSONDecoder().decode(PluginInstallRecord.self, from: $0) }
    }

    /// Puts `source` at `destination` in one step: swapped with the old folder (then removed), or renamed
    /// into place. Whoever reads the plugins folder meanwhile sees the old plugin or the new, never half.
    static func moveIntoPlace(_ source: URL, _ destination: URL) throws {
        let exists = FileManager.default.fileExists(atPath: destination.path)
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                renamex_np(from, to, UInt32(exists ? RENAME_SWAP : RENAME_EXCL))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if exists { try? FileManager.default.removeItem(at: source) }  // now holds the old version
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Network

    private func get(_ path: String, limit: Int, missing: PluginLibraryError? = nil) async throws -> Data {
        try await get(baseURL.appendingPathComponent(path), name: path, limit: limit, missing: missing)
    }

    private func get(_ url: URL, name: String, limit: Int, missing: PluginLibraryError? = nil) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw PluginLibraryError.unreachable(url.absoluteString) }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PluginLibraryError.unreachable(url.host ?? url.absoluteString)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404, let missing { throw missing }
        guard status == 200 else { throw PluginLibraryError.http(status: status, file: name) }
        guard data.count <= limit else { throw PluginLibraryError.tooLarge(name) }
        return data
    }
}
