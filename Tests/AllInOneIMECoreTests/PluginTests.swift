import Foundation
import Testing
@testable import AllInOneIMECore

/// Answers requests from a table of URL → (status, body), and records what was asked.
final class StubFetcher: PluginFetcher, @unchecked Sendable {
    var answers: [String: (Int, String)]
    private(set) var asked: [PluginRequest] = []

    init(_ answers: [String: (Int, String)] = [:]) { self.answers = answers }

    func fetch(_ requests: [PluginRequest]) -> [PluginResponse] {
        asked += requests
        return requests.map { request in
            guard let (status, body) = answers[request.url] else { return PluginResponse(error: "can't reach the host") }
            return PluginResponse(status: status, text: body)
        }
    }
}

struct PluginTests {
    func stockFolder() throws -> URL {
        try #require(Bundle.module.url(forResource: "stock", withExtension: nil, subdirectory: "Fixtures/plugins"))
    }

    func stockScript() throws -> String {
        try String(contentsOf: stockFolder().appendingPathComponent("main.js"), encoding: .utf8)
    }

    static func chart(_ symbol: String, _ name: String, _ price: Double, _ before: Double, _ currency: String) -> (Int, String) {
        (200, #"{"chart":{"result":[{"meta":{"symbol":"\#(symbol)","shortName":"\#(name)","currency":"\#(currency)","regularMarketPrice":\#(price),"chartPreviousClose":\#(before)}}],"error":null}}"#)
    }

    static func url(_ symbol: String) -> String {
        "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? symbol)?range=1d&interval=1d"
    }

    // MARK: Manifest and store

    @Test func manifests() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: stockFolder().appendingPathComponent("plugin.json")))
        #expect(manifest.name == "stock" && manifest.type == .script && manifest.hosts == ["query1.finance.yahoo.com"])
        #expect(manifest.summary?.text(chinese: true).hasPrefix("股票行情") == true)
        #expect(manifest.problem(appVersion: "0.2.0") == nil)
        #expect(manifest.problem(appVersion: "0.1.9") == "needs AllInOneIME 0.2.0 or later")
        var newer = manifest
        newer.api = 2
        #expect(newer.problem(appVersion: "9.9.9")?.contains("plugin API") == true)
        var bad = manifest
        bad.script = "../evil.js"
        #expect(bad.problem(appVersion: "1.0") == "no script")
        bad = manifest
        bad.name = "Stock"
        #expect(bad.problem(appVersion: "1.0") != nil)
        // A summary may be plain text.
        let plain = try JSONDecoder().decode(PluginManifest.self, from: Data(#"{"name":"x","version":"1","type":"prompt","prompt":"Do it.","summary":"Plain"}"#.utf8))
        #expect(plain.summary == LocalizedText(en: "Plain") && plain.api == 1 && plain.hosts.isEmpty)
        #expect(SemVer.compare("0.10.0", "0.9.1") == 1 && SemVer.compare("1.0", "1.0.0") == 0 && SemVer.compare("1.2.0-beta", "1.3") == -1)
    }

    @Test func storeLoadsPluginsAndNoticesChangedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        // A library plugin (with its install record) and a local one.
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.copyItem(at: stockFolder(), to: root.appendingPathComponent("stock"))
        let files = ["plugin.json", "main.js"]
        let record = PluginInstallRecord(version: "1.0.0", files: Dictionary(uniqueKeysWithValues: files.map {
            ($0, PluginStore.sha256(of: root.appendingPathComponent("stock/\($0)"))!)
        }))
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent("stock/install.json"))
        let local = root.appendingPathComponent("tone")
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try Data(#"{"name":"tone","version":"0.1","type":"prompt","prompt":"Make it friendlier."}"#.utf8)
            .write(to: local.appendingPathComponent("plugin.json"))
        // Skipped: a folder named unlike its plugin, one without a manifest.
        try fm.copyItem(at: stockFolder(), to: root.appendingPathComponent("quotes"))
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)

        var loaded = PluginStore.load(from: root, appVersion: "0.2.0")
        #expect(loaded.plugins.map(\.name) == ["stock", "tone"])
        #expect(loaded.plugins.map(\.isLocal) == [false, true])
        #expect(loaded.skipped.map(\.folder) == ["empty", "quotes"])

        // A library plugin edited after installing isn't used.
        try "function run() { return 'changed' }".write(to: root.appendingPathComponent("stock/main.js"), atomically: true, encoding: .utf8)
        loaded = PluginStore.load(from: root, appVersion: "0.2.0")
        #expect(loaded.plugins.map(\.name) == ["tone"])
        #expect(loaded.skipped.contains(PluginStore.Skipped(folder: "stock", reason: "its files changed since it was installed")))
    }

    @Test func pluginsInTheCommandList() throws {
        let stock = InstalledPlugin(manifest: try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: stockFolder().appendingPathComponent("plugin.json"))),
                                    directory: try stockFolder(), isLocal: true)
        let tone = InstalledPlugin(manifest: PluginManifest(name: "tone", version: "1", type: .prompt, prompt: "Make it friendlier."),
                                   directory: URL(fileURLWithPath: "/tmp/tone"), isLocal: true)
        var open = stock
        open.manifest.name = "open"  // a built-in's name: the built-in wins
        let custom = [CustomCommand(name: "stock", type: .run, argv: ["x"]), CustomCommand(name: "bc", type: .run, argv: ["bc"])]
        let catalog = Command.catalog(custom, plugins: [stock, tone, open])
        #expect(catalog.map(\.name) == ["improve", "question", "claude", "open", "read", "note", "reminder", "calc", "py", "js", "tasks", "settings",
                                        "stock", "tone", "bc"])
        let stockCommand = try #require(catalog.first { $0.name == "stock" })
        #expect(stockCommand.kind == .run && stockCommand.plugin == stock && stockCommand.custom == nil)  // not the custom one
        #expect(stockCommand.typesLatin && stockCommand.program == nil)  // never hidden for a missing program
        let toneCommand = try #require(catalog.first { $0.name == "tone" })
        #expect(toneCommand.kind == .generate && Prompt.commandSystem(toneCommand).hasSuffix("Make it friendlier."))
        // The editor won't take a plugin's name.
        #expect(CustomCommand(name: "stock", type: .run, argv: ["x"]).problem(among: [], plugins: ["stock"]) == .nameTaken)
        // The plugin runs in a child process of the given program, the text on standard input.
        let run = PluginRunner.command(for: stock, executable: "/Apps/AllInOneIME")
        #expect(run.argv == ["/Apps/AllInOneIME", "--run-plugin", try stockFolder().path])
        #expect(run.standardInput(for: "aapl") == "aapl" && run.timeout == 10)
    }

    // MARK: JavaScript

    @Test func scriptsGetNothingButFetch() throws {
        let fetcher = StubFetcher(["https://a.test/x": (200, #"{"v": 41}"#)])
        let source = """
            function run(input) {
              const r = fetch("https://a.test/x", { headers: { "X-Test": "1" } });
              const env = [typeof require, typeof process, typeof setTimeout, typeof XMLHttpRequest].join(",");
              return input + " " + (r.json().v + 1) + " " + env;
            }
            """
        #expect(try PluginScript.evaluate(source: source, input: "hi", fetcher: fetcher) == "hi 42 undefined,undefined,undefined,undefined")
        #expect(fetcher.asked == [PluginRequest(url: "https://a.test/x", headers: ["X-Test": "1"])])
        // Errors: thrown, a syntax error, no run, not text, a failed fetch.
        #expect(throws: PluginScriptError.failed("nope")) {
            try PluginScript.evaluate(source: "function run() { throw new Error('nope') }", input: "", fetcher: fetcher)
        }
        #expect(throws: PluginScriptError.self) { try PluginScript.evaluate(source: "function run( {", input: "", fetcher: fetcher) }
        #expect(throws: PluginScriptError.noRunFunction) { try PluginScript.evaluate(source: "var x = 1", input: "", fetcher: fetcher) }
        #expect(throws: PluginScriptError.failed("run(input) must return text")) {
            try PluginScript.evaluate(source: "function run() { return 3 }", input: "", fetcher: fetcher)
        }
        #expect(throws: PluginScriptError.failed("can't reach the host")) {
            try PluginScript.evaluate(source: "function run() { return fetch('https://b.test/').text }", input: "", fetcher: fetcher)
        }
    }

    @Test func fetchOnlyReachesTheListedHosts() {
        let fetcher = URLSessionFetcher(hosts: ["query1.finance.yahoo.com"])
        #expect(fetcher.allows(URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/AAPL")))
        #expect(fetcher.allows(URL(string: "https://QUERY1.finance.yahoo.com/x")))
        #expect(!fetcher.allows(URL(string: "http://query1.finance.yahoo.com/x")))  // HTTPS only
        #expect(!fetcher.allows(URL(string: "https://evil.test/?q=query1.finance.yahoo.com")))
        #expect(!fetcher.allows(URL(string: "https://query1.finance.yahoo.com.evil.test/")))
        #expect(!fetcher.allows(URL(string: "file:///etc/passwd")))
        let refused = fetcher.fetch([PluginRequest(url: "https://evil.test/", headers: [:])])
        #expect(refused.first?.error?.hasPrefix("not allowed: evil.test") == true)
    }

    // MARK: @stock

    @Test func stockQuotes() throws {
        let fetcher = StubFetcher([
            Self.url("AAPL"): Self.chart("AAPL", "Apple Inc.", 336.64, 340.42, "USD"),
            Self.url("TSLA"): Self.chart("TSLA", "Tesla, Inc.", 382.7, 375.0, "USD"),
            Self.url("600519.SS"): Self.chart("600519.SS", "KWEICHOW MOUTAI", 1263, 1255.79, "CNY"),
            Self.url("000001.SZ"): Self.chart("000001.SZ", "PING AN BANK", 11.5, 11.5, "CNY"),
            Self.url("0700.HK"): Self.chart("0700.HK", "TENCENT", 424.8, 411.4, "HKD"),
            Self.url("^GSPC"): Self.chart("^GSPC", "S&P 500", 7811.54, 7765.36, "USD"),
            Self.url("NOPE"): (404, #"{"chart":{"result":null,"error":{"code":"Not Found"}}}"#),
        ])
        let script = try stockScript()
        func stock(_ input: String) throws -> String { try PluginScript.evaluate(source: script, input: input, fetcher: fetcher) }
        #expect(try stock("AAPL") == "Apple Inc. AAPL 336.64 USD −1.11%")
        #expect(try stock("aapl, tsla") == "Apple Inc. AAPL 336.64 USD −1.11% · Tesla, Inc. TSLA 382.70 USD +2.05%")
        // A shares and Hong Kong without the suffix; thousands separators; no change.
        #expect(try stock("600519 000001 700") == "KWEICHOW MOUTAI 600519.SS 1,263.00 CNY +0.57% · PING AN BANK 000001.SZ 11.50 CNY +0.00% · TENCENT 0700.HK 424.80 HKD +3.26%")
        #expect(try stock("^gspc").hasPrefix("S&P 500 ^GSPC 7,811.54 USD"))
        // One symbol missing: the others still show; all missing: an error.
        #expect(try stock("nope aapl") == "NOPE: not found · Apple Inc. AAPL 336.64 USD −1.11%")
        #expect(throws: PluginScriptError.failed("NOPE: not found")) { try stock("nope") }
        #expect(throws: PluginScriptError.failed("Type a stock symbol after @stock, e.g. AAPL")) { try stock("  ") }
        // At most 8 symbols a request; the browser User-Agent Yahoo wants.
        _ = try? stock("a b c d e f g h i j")
        #expect(fetcher.asked.suffix(8).count == 8 && fetcher.asked.last?.url.contains("/H?") == true)
        #expect(fetcher.asked.allSatisfy { $0.headers["User-Agent"] == "Mozilla/5.0" })
    }
}
