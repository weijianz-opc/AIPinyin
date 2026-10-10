import CryptoKit
import Foundation
import os
import Testing
@testable import AllInOneIMECore

/// Serves canned responses by full URL (the library fetches several files from one host); anything else
/// is a 404. Each test uses its own host, so tests run in parallel.
final class LibraryStubProtocol: URLProtocol, @unchecked Sendable {
    private static let state = OSAllocatedUnfairLock(initialState: (responses: [String: (Int, Data)](), asked: [String]()))

    static func serve(_ url: String, _ body: Data, status: Int = 200) {
        state.withLock { $0.responses[url] = (status, body) }
    }

    static func asked(host: String) -> [String] {
        state.withLock { $0.asked.filter { URL(string: $0)?.host == host } }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let (status, body) = Self.state.withLock { state -> (Int, Data) in
            state.asked.append(url.absoluteString)
            return state.responses[url.absoluteString] ?? (404, Data("Not Found".utf8))
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A library served from https://<host>/lib/, signed with a key made for the test, and a plugins folder
/// in a temporary directory.
struct TestLibrary {
    let host: String
    let key = Curve25519.Signing.PrivateKey()
    let directory: URL
    var base: String { "https://\(host)/lib/" }

    init() {
        host = "lib-\(UUID().uuidString.prefix(8).lowercased()).test"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)/plugins")
    }

    func library(publicKey: Data? = nil, appVersion: String = "0.5.0") -> PluginLibrary {
        PluginLibrary(baseURL: URL(string: base)!, publicKey: publicKey ?? key.publicKey.rawRepresentation,
                      session: LibraryStubProtocol.session(), appVersion: appVersion, directory: directory)
    }

    static func manifest(_ name: String, _ version: String, hosts: [String] = ["query1.finance.yahoo.com"],
                         minAppVersion: String = "0.2.0") -> Data {
        Data(#"{"name":"\#(name)","version":"\#(version)","api":1,"minAppVersion":"\#(minAppVersion)","type":"script","script":"main.js","hosts":[\#(hosts.map { "\"\($0)\"" }.joined(separator: ","))],"summary":{"en":"Test","zh":"测试"}}"#.utf8)
    }

    /// Serves `files` for `name` `version` and returns its index entry (hashes of what's served).
    func publish(_ name: String, _ version: String, files: [String: Data]? = nil,
                 hosts: [String] = ["query1.finance.yahoo.com"]) -> [String: Any] {
        let files = files ?? ["plugin.json": Self.manifest(name, version, hosts: hosts),
                              "main.js": Data("function run(input) { return '\(name) \(version) ' + input }".utf8)]
        let folder = "plugins/\(name)/\(version)/"
        for (file, data) in files { LibraryStubProtocol.serve(base + folder + file, data) }
        return ["name": name, "version": version, "api": 1, "minAppVersion": "0.2.0", "type": "script",
                "summary": ["en": "Test", "zh": "测试"], "hosts": hosts, "base": folder,
                "files": files.mapValues { PluginLibrary.sha256($0) }]
    }

    /// Serves index.json with `plugins`, and its signature (nil: none).
    @discardableResult
    func serveIndex(_ plugins: [[String: Any]], schema: Int = 1, signWith signer: Curve25519.Signing.PrivateKey? = nil,
                    signed: Bool = true) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: ["schema": schema, "generated": "2026-10-10T00:00:00Z", "plugins": plugins],
                                              options: [.sortedKeys])
        LibraryStubProtocol.serve(base + "index.json", data)
        if signed {
            let signature = try (signer ?? key).signature(for: data).base64EncodedString()
            LibraryStubProtocol.serve(base + "index.json.sig", Data((signature + "\n").utf8))
        }
        return data
    }

    func folder(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: true) }

    func contents(_ name: String) -> [String: String] {
        let folder = folder(name)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Dictionary(uniqueKeysWithValues: files.map {
            ($0, (try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8)) ?? "")
        })
    }

    func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".tmp") }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
}

struct PluginLibraryTests {
    // MARK: Signature

    @Test func theIndexIsReadOnlyWhenItsSignatureChecksOut() async throws {
        let lib = TestLibrary()
        defer { lib.cleanUp() }
        let entry = lib.publish("stock", "1.0.0")
        let data = try lib.serveIndex([entry])
        let index = try await lib.library().fetchIndex()
        #expect(index.schema == 1 && index.plugins.map(\.id) == ["stock@1.0.0"])
        #expect(index.plugins.first?.hosts == ["query1.finance.yahoo.com"] && index.plugins.first?.summary?.zh == "测试")
        #expect(LibraryStubProtocol.asked(host: lib.host).contains(lib.base + "index.json.sig"))

        // Another key (the app's built-in one, here) refuses it.
        await #expect(throws: PluginLibraryError.badSignature) {
            try await lib.library(publicKey: PluginLibrary.publicKey).fetchIndex()
        }
        // Signed by someone else.
        try lib.serveIndex([entry], signWith: Curve25519.Signing.PrivateKey())
        await #expect(throws: PluginLibraryError.badSignature) { try await lib.library().fetchIndex() }

        // Tampered with after signing: a host added, the signature left as it was.
        try lib.serveIndex([entry])
        let tampered = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "query1.finance.yahoo.com", with: "evil.test")
        LibraryStubProtocol.serve(lib.base + "index.json", Data(tampered.utf8))
        await #expect(throws: PluginLibraryError.badSignature) { try await lib.library().fetchIndex() }

        // Garbage and empty signatures, a missing one.
        try lib.serveIndex([entry])
        LibraryStubProtocol.serve(lib.base + "index.json.sig", Data("not base64!".utf8))
        await #expect(throws: PluginLibraryError.badSignature) { try await lib.library().fetchIndex() }
        LibraryStubProtocol.serve(lib.base + "index.json.sig", Data("\n".utf8))
        await #expect(throws: PluginLibraryError.missingSignature) { try await lib.library().fetchIndex() }
        LibraryStubProtocol.serve(lib.base + "index.json.sig", Data(), status: 404)
        await #expect(throws: PluginLibraryError.missingSignature) { try await lib.library().fetchIndex() }

        // The index itself missing.
        LibraryStubProtocol.serve(lib.base + "index.json", Data(), status: 404)
        await #expect(throws: PluginLibraryError.http(status: 404, file: "index.json")) { try await lib.library().fetchIndex() }
    }

    @Test func unknownSchemasAndUnreadableIndexesAreRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        func verify(_ json: String) throws -> PluginIndex {
            let data = Data(json.utf8)
            return try PluginLibrary.verify(index: data, signature: Data(try key.signature(for: data).base64EncodedString().utf8),
                                            publicKey: key.publicKey.rawRepresentation)
        }
        #expect(throws: PluginLibraryError.unsupportedSchema(2)) { try verify(#"{"schema":2,"plugins":[]}"#) }
        #expect(throws: PluginLibraryError.malformedIndex) { try verify(#"{"plugins":[]}"#) }
        #expect(throws: PluginLibraryError.malformedIndex) { try verify("not json") }
        // An entry this app can't read is left out; the rest of the index stays.
        let index = try verify(#"{"schema":1,"plugins":[{"name":"a","version":"1","type":"script","base":"plugins/a/1/","files":{}},{"name":"b"}]}"#)
        #expect(index.plugins.map(\.name) == ["a"])
    }

    // MARK: Filtering

    @Test func onlyWhatThisAppCanRunIsOffered() async throws {
        let lib = TestLibrary()
        defer { lib.cleanUp() }
        func entry(_ name: String, _ version: String, _ changes: [String: Any] = [:]) -> [String: Any] {
            var e: [String: Any] = ["name": name, "version": version, "api": 1, "type": "script", "hosts": [String](),
                                    "base": "plugins/\(name)/\(version)/", "files": ["plugin.json": String(repeating: "0", count: 64)]]
            e.merge(changes) { $1 }
            return e
        }
        try lib.serveIndex([
            entry("stock", "1.2.0", ["minAppVersion": "9.0.0"]),  // newest, but for a later app
            entry("stock", "1.1.0", ["minAppVersion": "0.5.0"]),
            entry("stock", "1.0.0"),
            entry("future", "1.0.0", ["api": 2]),
            entry("widget", "1.0.0", ["type": "widget"]),  // a type this app doesn't know
            entry("Bad", "1.0.0"),
            entry("tone", "0.9", ["type": "prompt", "minAppVersion": "0.4.0"]),
        ])
        let index = try await lib.library(appVersion: "0.5.0").fetchIndex()
        #expect(lib.library(appVersion: "0.5.0").available(index).map(\.id) == ["stock@1.1.0", "tone@0.9"])
        #expect(lib.library(appVersion: "0.4.0").available(index).map(\.id) == ["stock@1.0.0", "tone@0.9"])
        #expect(lib.library(appVersion: "0.3.9").available(index).map(\.id) == ["stock@1.0.0"])
        #expect(lib.library(appVersion: "10.0").available(index).map(\.id) == ["stock@1.2.0", "tone@0.9"])
    }

    // MARK: Installing

    @Test func installsAndUpdates() async throws {
        let lib = TestLibrary()
        defer { lib.cleanUp() }
        let library = lib.library()
        var v1 = lib.publish("stock", "1.0.0", files: ["plugin.json": TestLibrary.manifest("stock", "1.0.0"),
                                                       "main.js": Data("function run() { return 'one' }".utf8),
                                                       "old.txt": Data("dropped in 1.1.0".utf8)])
        try lib.serveIndex([v1])
        var entry = try #require(library.available(try await library.fetchIndex()).first)
        #expect(library.status(of: entry) == .notInstalled)

        let installed = try await library.install(entry)
        #expect(installed.name == "stock" && !installed.isLocal && installed.directory == lib.folder("stock"))
        #expect(Set(lib.contents("stock").keys) == ["plugin.json", "main.js", "old.txt", "install.json"])
        let record = try JSONDecoder().decode(PluginInstallRecord.self, from: Data(contentsOf: lib.folder("stock/install.json")))
        #expect(record.version == "1.0.0" && record.source == "registry" && record.files == entry.files)
        #expect(library.status(of: entry) == .installed)
        // The store takes it as a library plugin (its hashes match the record).
        var loaded = PluginStore.load(from: lib.directory, appVersion: "0.5.0")
        #expect(loaded.plugins.map(\.name) == ["stock"] && loaded.plugins.first?.isLocal == false && loaded.skipped.isEmpty)

        // A newer version: an update, installed by hand; files it no longer has are gone.
        v1["version"] = "0.9.0"  // an older one listed too doesn't matter
        let v2 = lib.publish("stock", "1.1.0")
        try lib.serveIndex([v2, v1])
        entry = try #require(library.available(try await library.fetchIndex()).first)
        #expect(entry.version == "1.1.0" && library.status(of: entry) == .update(from: "1.0.0"))
        try await library.install(entry)
        #expect(Set(lib.contents("stock").keys) == ["plugin.json", "main.js", "install.json"])
        #expect(lib.contents("stock")["main.js"]?.contains("stock 1.1.0") == true)
        #expect(library.status(of: entry) == .installed && lib.leftovers().isEmpty)
        loaded = PluginStore.load(from: lib.directory, appVersion: "0.5.0")
        #expect(loaded.plugins.first?.manifest.version == "1.1.0")
        // Only the library's host was contacted.
        #expect(LibraryStubProtocol.asked(host: lib.host).allSatisfy { $0.hasPrefix(lib.base) })
    }

    @Test func linkPlugins() async throws {
        let lib = TestLibrary()
        defer { lib.cleanUp() }
        let library = lib.library()
        func link(_ version: String, url: String, indexURL: String) -> [String: Any] {
            let manifest = Data(#"{"name":"x","version":"\#(version)","api":1,"minAppVersion":"0.5.0","type":"link","url":"\#(url)"}"#.utf8)
            var entry = lib.publish("x", version, files: ["plugin.json": manifest], hosts: [])
            entry["type"] = "link"
            entry["url"] = indexURL
            return entry
        }
        // Installed like the others: only plugin.json, the address it opens checked against the index.
        try lib.serveIndex([link("1.0.0", url: "https://x.com/intent/post?text={input}", indexURL: "https://x.com/intent/post?text={input}")])
        let entry = try #require(library.available(try await library.fetchIndex()).first)
        let installed = try await library.install(entry)
        #expect(installed.manifest.type == .link && installed.manifest.destinationHosts == ["x.com"])
        // A manifest sending the text elsewhere than the index showed isn't installed.
        try lib.serveIndex([link("1.1.0", url: "https://evil.test/?q={input}", indexURL: "https://x.com/intent/post?text={input}")])
        let swapped = try #require(library.available(try await library.fetchIndex()).first)
        await #expect(throws: PluginLibraryError.invalidManifest("doesn't match the index")) { try await library.install(swapped) }
        #expect(library.status(of: swapped) == .update(from: "1.0.0") && lib.leftovers().isEmpty)
    }

    @Test func aFailedUpdateLeavesTheInstalledVersionAlone() async throws {
        let lib = TestLibrary()
        defer { lib.cleanUp() }
        let library = lib.library()
        try lib.serveIndex([lib.publish("stock", "1.0.0")])
        try await library.install(try #require(library.available(try await library.fetchIndex()).first))
        let before = lib.contents("stock")

        // A file that doesn't match its hash (damaged, or swapped on the server).
        var bad = lib.publish("stock", "1.1.0")
        LibraryStubProtocol.serve(lib.base + "plugins/stock/1.1.0/main.js", Data("function run() { return 'evil' }".utf8))
        try lib.serveIndex([bad])
        let update = try #require(library.available(try await library.fetchIndex()).first)
        await #expect(throws: PluginLibraryError.hashMismatch("main.js")) { try await library.install(update) }
        #expect(lib.contents("stock") == before && lib.leftovers().isEmpty)

        // A file missing on the server.
        bad = lib.publish("stock", "1.2.0")
        var files = bad["files"] as! [String: String]
        files["extra.js"] = String(repeating: "a", count: 64)
        bad["files"] = files
        try lib.serveIndex([bad])
        let missing = try #require(library.available(try await library.fetchIndex()).first)
        await #expect(throws: PluginLibraryError.http(status: 404, file: "extra.js")) { try await library.install(missing) }
        #expect(lib.contents("stock") == before && lib.leftovers().isEmpty)

        // A manifest unlike its index entry: more hosts than the user was shown.
        bad = lib.publish("stock", "1.3.0", files: ["plugin.json": TestLibrary.manifest("stock", "1.3.0", hosts: ["query1.finance.yahoo.com", "evil.test"]),
                                                    "main.js": Data("function run() { return '' }".utf8)])
        bad["hosts"] = ["query1.finance.yahoo.com"]
        try lib.serveIndex([bad])
        let mismatched = try #require(library.available(try await library.fetchIndex()).first)
        await #expect(throws: PluginLibraryError.invalidManifest("doesn't match the index")) { try await library.install(mismatched) }
        #expect(lib.contents("stock") == before && lib.leftovers().isEmpty)
        #expect(library.status(of: mismatched) == .update(from: "1.0.0"))
    }

    @Test func fileNamesCantLeaveThePluginFolder() async throws {
        let lib = TestLibrary()
        defer { lib.cleanUp() }
        let library = lib.library()
        let hash = String(repeating: "0", count: 64)
        func entry(name: String = "stock", base: String = "plugins/stock/1.0.0/", files: [String: String]) -> PluginIndex.Entry {
            PluginIndex.Entry(name: name, version: "1.0.0", base: base, files: files)
        }
        for file in ["../evil.js", "../../.zshrc", "a/b.js", ".hidden", "/etc/passwd", "install.json", "", "..", "a\\b"] {
            await #expect(throws: PluginLibraryError.invalidFile(file)) {
                try await library.install(entry(files: ["plugin.json": hash, file: hash]))
            }
        }
        for name in ["../stock", "Stock", "", "stock.tmp", String(repeating: "a", count: 25), "股票"] {
            await #expect(throws: PluginLibraryError.invalidName(name)) {
                try await library.install(entry(name: name, files: ["plugin.json": hash]))
            }
        }
        for base in ["../other/", "plugins/../../x/", "/plugins/stock/", "https://evil.test/", "plugins/%2e%2e/x/", "plugins/stock", "./", ""] {
            await #expect(throws: PluginLibraryError.invalidFile(base)) {
                try await library.install(entry(base: base, files: ["plugin.json": hash]))
            }
        }
        await #expect(throws: PluginLibraryError.invalidFile("main.js")) {  // not a sha256
            try await library.install(entry(files: ["plugin.json": hash, "main.js": "abc"]))
        }
        await #expect(throws: PluginLibraryError.invalidFile("plugin.json")) {  // no manifest
            try await library.install(entry(files: ["main.js": hash]))
        }
        #expect(!FileManager.default.fileExists(atPath: lib.directory.path))  // nothing written, nothing asked
        #expect(LibraryStubProtocol.asked(host: lib.host).isEmpty)
    }

    @Test func localPluginsAreNeverOverwritten() async throws {
        let lib = TestLibrary()
        defer { lib.cleanUp() }
        let library = lib.library()
        try FileManager.default.createDirectory(at: lib.folder("stock"), withIntermediateDirectories: true)
        try TestLibrary.manifest("stock", "0.1").write(to: lib.folder("stock/plugin.json"))
        try Data("function run() { return 'mine' }".utf8).write(to: lib.folder("stock/main.js"))
        let before = lib.contents("stock")

        try lib.serveIndex([lib.publish("stock", "2.0.0")])
        let entry = try #require(library.available(try await library.fetchIndex()).first)
        #expect(library.status(of: entry) == .local)
        await #expect(throws: PluginLibraryError.localPlugin("stock")) { try await library.install(entry) }
        #expect(lib.contents("stock") == before && lib.leftovers().isEmpty)
        #expect(!LibraryStubProtocol.asked(host: lib.host).contains { $0.contains("/plugins/stock/") })
        #expect(PluginStore.load(from: lib.directory, appVersion: "0.5.0").plugins.first?.isLocal == true)
    }

    @Test func errorsReadInEnglish() {
        #expect(PluginLibraryError.hashMismatch("main.js").errorDescription == "main.js doesn't match the signed index; nothing was changed")
        #expect(PluginLibraryError.localPlugin("stock").errorDescription?.hasPrefix("A local plugin named stock") == true)
        #expect(PluginLibrary.defaultBaseURL.absoluteString == "https://raw.githubusercontent.com/weijianz-opc/AllInOneIME-plugins/main/")
        #expect(PluginLibrary.publicKey.count == 32)
    }
}
