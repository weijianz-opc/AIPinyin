import Foundation
import Testing
@testable import AllInOneIMECore

/// `@xe` (Plugins/xe): currency conversion, with recorded open.er-api.com / Frankfurter responses.
struct XEPluginTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Plugins/xe")

    static func erAPI(_ base: String) -> String { "https://open.er-api.com/v6/latest/\(base)" }
    static func frankfurter(_ base: String) -> String { "https://api.frankfurter.dev/v1/latest?base=\(base)" }

    /// An open.er-api.com answer (rates recorded on 2026-10-11 00:02 UTC).
    static func rates(_ base: String, _ rates: [String: Double]) -> (Int, String) {
        let list = rates.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        return (200, #"{"result":"success","provider":"https://www.exchangerate-api.com","time_last_update_unix":1791676951,"time_last_update_utc":"Sun, 11 Oct 2026 00:02:31 +0000","base_code":"\#(base)","rates":{\#(list)}}"#)
    }

    /// The recorded responses: USD in full, the others trimmed.
    func fetcher() throws -> StubFetcher {
        let usd = try #require(Bundle.module.url(forResource: "er-api-USD", withExtension: "json", subdirectory: "Fixtures/xe"))
        return StubFetcher([
            Self.erAPI("USD"): (200, try String(contentsOf: usd, encoding: .utf8)),
            Self.erAPI("JPY"): Self.rates("JPY", ["USD": 0.006318, "CNY": 0.04235, "JPY": 1, "EUR": 0.005639, "KRW": 8.48055]),
            Self.erAPI("CNY"): Self.rates("CNY", ["USD": 0.149102, "CNY": 1, "JPY": 23.612922, "EUR": 0.133217, "HKD": 1.16994]),
            Self.erAPI("EUR"): Self.rates("EUR", ["USD": 1.120529, "CNY": 7.506566, "JPY": 177.326719, "EUR": 1]),
            Self.erAPI("HKD"): Self.rates("HKD", ["USD": 0.127417, "CNY": 0.85475, "HKD": 1]),
            Self.erAPI("GBP"): Self.rates("GBP", ["USD": 1.322886, "CNY": 8.872334, "GBP": 1]),
            Self.erAPI("XYZ"): (200, #"{"result":"error","error-type":"unsupported-code"}"#),
        ])
    }

    func script() throws -> String {
        try String(contentsOf: Self.folder.appendingPathComponent("main.js"), encoding: .utf8)
    }

    func xe(_ input: String, _ fetcher: StubFetcher) throws -> String {
        try PluginScript.evaluate(source: try script(), input: input, fetcher: fetcher)
    }

    @Test func manifest() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: Self.folder.appendingPathComponent("plugin.json")))
        #expect(manifest.name == "xe" && manifest.version == "1.0.0" && manifest.type == .script && manifest.minAppVersion == "0.5.0")
        #expect(manifest.hosts == ["open.er-api.com", "api.frankfurter.dev"])
        #expect(manifest.problem(appVersion: "0.5.0") == nil)
        #expect(manifest.summary?.en.contains("ExchangeRate-API") == true && manifest.summary?.zh?.hasPrefix("汇率换算") == true)
        #expect(manifest.icon == "dollarsign.arrow.circlepath" && manifest.color == "green")
        // What the library refuses.
        let source = try script()
        #expect(!source.contains("eval(") && !source.contains("Function("))
        #expect(source.utf8.count <= PluginManifest.maxScriptBytes)
    }

    @Test func convertsWithTheDateOfTheRate() throws {
        let fetcher = try fetcher()
        #expect(try xe("100 USD CNY", fetcher) == "100 USD = 670.69 CNY (1 USD = 6.7069 CNY · 2026-10-11)")
        // One request, from the first currency.
        #expect(fetcher.asked.map(\.url) == [Self.erAPI("USD")])
        // No amount: 1, the rate both ways.
        #expect(try xe("USD JPY", fetcher) == "1 USD = 158.29 JPY (1 JPY = 0.006318 USD · 2026-10-11)")
        // Thousands separators; no decimals for yen and won; small amounts keep two significant digits.
        #expect(try xe("12345.6 USD JPY", fetcher) == "12,345.6 USD = 1,954,151 JPY (1 USD = 158.29 JPY · 2026-10-11)")
        #expect(try xe("10 JPY USD", fetcher) == "10 JPY = 0.063 USD (1 JPY = 0.006318 USD · 2026-10-11)")
        #expect(try xe("1,200.5 EUR USD", fetcher) == "1,200.5 EUR = 1,345.20 USD (1 EUR = 1.1205 USD · 2026-10-11)")
    }

    @Test func readsTheWaysPeopleWriteIt() throws {
        let fetcher = try fetcher()
        let expected = "100 USD = 670.69 CNY (1 USD = 6.7069 CNY · 2026-10-11)"
        for input in ["100 USD CNY", "usd cny 100", "USD 100 CNY", "100 usd cny", "100usd cny", "100USD CNY",
                      "100 USD to CNY", "100 usd in cny", "100 USD → CNY", "100 USD -> CNY", "100 USD = CNY",
                      "100美元 人民币", "100 美金 人民币", "$100 人民币", "US$100 RMB", "100 dollars yuan",
                      "100美元换成多少人民币", "100美元兑人民币", "１００ ＵＳＤ ＣＮＹ", "100 USD"] {
            #expect(try xe(input, fetcher) == expected, "\(input)")
        }
        // Chinese names and symbols.
        #expect(try xe("1000 日元 人民币", fetcher) == "1,000 JPY = 42.35 CNY (1 JPY = 0.04235 CNY · 2026-10-11)")
        #expect(try xe("1000円 元", fetcher).hasPrefix("1,000 JPY = 42.35 CNY"))
        #expect(try xe("€1200.5 美元", fetcher).hasPrefix("1,200.5 EUR = 1,345.20 USD"))
        #expect(try xe("100 英镑", fetcher).hasPrefix("100 GBP = 887.23 CNY"))
        #expect(try xe("1.5万 港币", fetcher).hasPrefix("15,000 HKD = 12,821.25 CNY"))
        #expect(try xe("2k HK$", fetcher).hasPrefix("2,000 HKD = 1,709.50 CNY"))
        // ¥ is the yuan, unless the other currency is the yuan.
        #expect(try xe("¥100 USD", fetcher).hasPrefix("100 CNY = 14.91 USD"))
        #expect(try xe("￥100", fetcher).hasPrefix("100 CNY = 14.91 USD"))
        #expect(try xe("¥1000 人民币", fetcher).hasPrefix("1,000 JPY = 42.35 CNY"))
    }

    @Test func oneCurrencyOrSeveral() throws {
        let fetcher = try fetcher()
        // One currency: to CNY; from CNY: to USD.
        #expect(try xe("100 USD", fetcher).hasPrefix("100 USD = 670.69 CNY"))
        #expect(try xe("100 人民币", fetcher) == "100 CNY = 14.91 USD (1 CNY = 0.1491 USD · 2026-10-11)")
        #expect(try xe("CNY", fetcher) == "1 CNY = 0.1491 USD (1 USD = 6.7068 CNY · 2026-10-11)")
        // Several targets on one line; the source and repeats are left out.
        #expect(try xe("100 USD CNY JPY EUR", fetcher) == "100 USD = 670.69 CNY · 15,829 JPY · 89.24 EUR (2026-10-11)")
        #expect(try xe("100 USD USD cny CNY 日元", fetcher) == "100 USD = 670.69 CNY · 15,829 JPY (2026-10-11)")
    }

    @Test func errors() throws {
        let fetcher = try fetcher()
        func fails(_ input: String, _ message: String, using stub: StubFetcher? = nil) {
            #expect(throws: PluginScriptError.failed(message), "\(input)") { try xe(input, stub ?? fetcher) }
        }
        fails("100 USD XYZ", "Unknown currency: XYZ")
        fails("100 XYZ", "Unknown currency: XYZ")  // the service doesn't know it
        fails("100 USD ABC DEF", "Unknown currency: ABC, DEF")
        fails("100 dollarz CNY", "Unknown currency: dollarz")
        fails("100 卢布布 人民币", "Unknown currency: 布")
        fails("", "Type currencies after @xe, e.g. 100 USD CNY")
        fails("100", "Type currencies after @xe, e.g. 100 USD CNY")
        fails("100 USD 200 CNY", "One amount at a time, e.g. @xe 100 USD CNY")
        // No answer, an error page, garbage: no rates (after trying the fallback).
        fails("100 USD CNY", "Couldn't get exchange rates", using: StubFetcher())
        fails("100 USD CNY", "Couldn't get exchange rates", using: StubFetcher([Self.erAPI("USD"): (500, "oops")]))
        fails("100 USD CNY", "Couldn't get exchange rates", using: StubFetcher([Self.erAPI("USD"): (200, "<html>")]))
    }

    @Test func fallsBackToFrankfurter() throws {
        // ExchangeRate-API limits the rate (429): the ECB's rates, with their date.
        let fetcher = StubFetcher([
            Self.erAPI("USD"): (429, #"{"result":"error","error-type":"rate-limited"}"#),
            Self.frankfurter("USD"): (200, #"{"amount":1.0,"base":"USD","date":"2026-10-09","rates":{"CNY":6.6921,"EUR":0.89238,"JPY":158.25}}"#),
        ])
        #expect(try xe("100 USD CNY", fetcher) == "100 USD = 669.21 CNY (1 USD = 6.6921 CNY · 2026-10-09)")
        #expect(fetcher.asked.map(\.url) == [Self.erAPI("USD"), Self.frankfurter("USD")])
        // A currency only ExchangeRate-API has isn't in the ECB's list.
        #expect(throws: PluginScriptError.failed("Unknown currency: TWD")) { try xe("100 USD TWD", fetcher) }
    }

    /// Inside a sentence the argument is a word plus the following words without lowercase letters
    /// (CommandPlan): `1200 USD CNY` is taken whole; lowercase or Chinese forms need 「…」 or quotes.
    @Test func insideASentence() throws {
        let plugin = InstalledPlugin(manifest: try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: Self.folder.appendingPathComponent("plugin.json"))),
                                     directory: Self.folder, isLocal: true)
        let catalog = Command.catalog([CustomCommand(name: "reply", type: .prompt, prompt: "Reply.")], plugins: [plugin])
        func arguments(_ text: String) -> [String] { CommandPlan.make(text, commands: catalog).inner.map(\.argument) }
        #expect(arguments("报价 @xe 1200 USD CNY 可以吗") == ["1200 USD CNY"])
        #expect(arguments("@xe USD JPY 今天多少") == ["USD JPY"])
        #expect(arguments("报价 @xe 1200 USD to CNY 可以吗") == ["1200 USD"])  // "to" ends it; CNY is the default anyway
        #expect(arguments("报价 @xe 1200 usd cny 可以吗") == ["1200"])  // lowercase: quote it
        #expect(arguments("报价 @xe「1200 usd cny」可以吗") == ["1200 usd cny"])
        #expect(arguments("报价 @xe「1000 日元 人民币」可以吗") == ["1000 日元 人民币"])
        #expect(arguments(#"quote @xe "100 usd in eur" ok?"#) == ["100 usd in eur"])

        let fetcher = try fetcher()
        let plan = CommandPlan.make("报价 @xe 1200 USD CNY 可以吗", commands: catalog)
        let output = try xe(plan.inner[0].argument, fetcher)
        #expect(plan.input(outputs: [output]) == "报价 1,200 USD = 8,048.22 CNY (1 USD = 6.7069 CNY · 2026-10-11) 可以吗")
        #expect(try xe(arguments("报价 @xe「1000 日元 人民币」可以吗")[0], fetcher).hasPrefix("1,000 JPY = 42.35 CNY"))
    }
}
