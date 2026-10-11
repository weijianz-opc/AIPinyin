import AllInOneIMECore
import Foundation

let usage = """
    usage: allinoneime-cli [options] <sentence>
           allinoneime-cli [options] --bench
           allinoneime-cli [options] --dump FILE <sentence>

    Runs level two (translate / polish + rewrites) with the same Core code the input method uses.
    Settings come from ~/.config/allinoneime/config.json; flags override them.

    options:
      --provider NAME  bedrock, anthropic, gemini or openai (API keys: the keychain, else ANTHROPIC_API_KEY, …)
      --profile NAME   AWS profile
      --region REGION  Bedrock region
      --model ID       model (for Bedrock: model / inference profile ID)
      --output CODES   translation languages in order, comma-separated: en, zh, zh-Hant, ja, ko, fr, …
      --mode MODE      improve (polish + styles), translate, or both (default)
      --styles A,B     rewrite presets, e.g. 简洁,黑话 (presets: \(RewriteStyle.catalog.map(\.name).joined(separator: " ")))
      --jargon FILE    your own jargon list for 黑话 (one term per line, optional "：meaning")
      --raw            also print the raw model output
      --bench          convert built-in samples in one process and report latency
      --dump FILE      save the raw event-stream response bytes to FILE (test fixtures; Bedrock)
      --version        print the version and exit
    """

struct Options {
    var provider: Provider?
    var profile: String?
    var region: String?
    var model: String?
    var output: [OutputLanguage]?
    var mode: WritingMode = .both
    var styles: [String]?
    var jargon: String?
    var raw = false
    var bench = false
    var dumpPath: String?
    var words: [String] = []
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst()
    func value(_ flag: String) -> String {
        guard let v = args.popFirst() else { fail("\(flag) needs a value") }
        return v
    }
    while let arg = args.popFirst() {
        switch arg {
        case "--provider":
            let raw = value(arg)
            guard let provider = Provider(rawValue: raw) else {
                fail("--provider must be one of \(Provider.allCases.map(\.rawValue).joined(separator: ", ")), not \(raw)")
            }
            options.provider = provider
        case "--profile": options.profile = value(arg)
        case "--region": options.region = value(arg)
        case "--model": options.model = value(arg)
        case "--output":
            options.output = value(arg).split(separator: ",").map { raw in
                guard let language = OutputLanguage.catalog.first(where: { $0.code.lowercased() == raw.lowercased() }) else {
                    fail("--output must be among \(OutputLanguage.catalog.map(\.code).joined(separator: ", ")), not \(raw)")
                }
                return language
            }
        case "--mode":
            let raw = value(arg)
            guard let mode = WritingMode(rawValue: raw) else { fail("--mode must be improve, translate or both, not \(raw)") }
            options.mode = mode
        case "--styles":
            options.styles = value(arg).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        case "--raw": options.raw = true
        case "--jargon": options.jargon = value(arg)
        case "--bench": options.bench = true
        case "--dump": options.dumpPath = value(arg)
        case "-h", "--help": print(usage); exit(0)
        case "--version": print("allinoneime-cli \(AppVersion.string)"); exit(0)
        default:
            if arg.hasPrefix("--") { fail("unknown option \(arg)") }
            options.words.append(arg)
        }
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}

func seconds(_ t: TimeInterval?) -> String {
    t.map { String(format: "%.2fs", $0) } ?? "-"
}

struct Timings {
    var firstToken: TimeInterval?
    var firstEnglish: TimeInterval?
    var total: TimeInterval = 0
}

/// Runs one conversion, printing each line as soon as it completes.
func convert(_ input: String, with converter: Converter, raw: Bool,
             jargon: [JargonEntry] = []) async throws -> (ConversionResult, Timings) {
    var printed = Set<String>()
    var timings = Timings()
    var final = ConversionResult.empty
    var rawText = ""
    for try await update in converter.convert(input, mode: options.mode) {
        timings.firstToken = update.firstTokenLatency
        if timings.firstEnglish == nil, update.result.versions.first?.isComplete == true {
            timings.firstEnglish = update.elapsed
        }
        var rows = update.result.versions.enumerated().map { ("\($0.offset + 1)", $0.element) }
        rows += update.result.translations.map { ($0.language.code, $0.line) }
        rows += update.result.rewrites.map { ($0.style, $0.line) }
        for (label, line) in rows where line.isComplete && !printed.contains(label) {
            printed.insert(label)
            let note = label == RewriteStyle.jargonName ? JargonLibrary.annotation(for: line.text, entries: jargon) : nil
            print("  [\(seconds(update.elapsed))] \(label) \(line.text)" + (note.map { "   (\($0))" } ?? ""))
        }
        if update.isFinal {
            final = update.result
            timings.total = update.elapsed
            rawText = update.rawText
            if update.fromCache { print("  (cache hit)") }
        }
    }
    if raw { print("--- raw ---\n\(rawText)\n-----------") }
    return (final, timings)
}

func dumpRawResponse(_ input: String, config: Config, to path: String) async throws {
    let resolved = try AWSSharedConfig.load(profile: config.awsProfile)
    let region = config.region ?? resolved.region ?? "us-east-1"
    let request = try BedrockClient.makeRequest(
        Prompt.request(for: input, config: config), modelId: config.modelId, region: region,
        credentials: resolved.credentials, timeout: config.timeoutSeconds)
    let (bytes, response) = try await BedrockClient.makeSession().bytes(for: request)
    var data = Data()
    for try await byte in bytes { data.append(byte) }
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard status == 200 else {
        fail("HTTP \(status): \(String(decoding: data.prefix(500), as: UTF8.self))")
    }
    try data.write(to: URL(fileURLWithPath: path))
    print("wrote \(data.count) bytes to \(path)")
}

let benchSamples = [
    "我今天有点不舒服",
    "明天开会我可能要迟到",
    "这个项目的进度太慢了",
    "你吃饭了吗",
    "老板说这个不够，在改一遍",
    "你能帮我看下这个代码的bug吗",
    "不好意思刚才在开会没看到消息",
    "我觉得这个方案还行但是有些地方需要再想想",
    "谢谢你的帮助",
    "好的",
]

/// "改写" (rewritten) if the rewrite changed the wording, "≈原文" (≈ original) if it only changed
/// punctuation, "无" (none) if missing.
func rewriteStatus(_ line: CandidateLine?, original: String) -> String {
    guard let line, !line.text.isEmpty else { return "无" }
    return line.text.wordingKey == original.wordingKey ? "≈原文" : "改写"
}

let options = parseOptions()
LegacyData.migrate()  // settings from the AIPinyin days move to ~/.config/allinoneime first
var config: Config
do {
    config = try Config.load()
} catch {
    fail(describe(error))
}
if let p = options.profile { config.awsProfile = p }
if let r = options.region { config.region = r }
if let p = options.provider { config.provider = p }
if let m = options.model {
    switch config.provider {
    case .bedrock: config.modelId = m
    case .anthropic: config.anthropic.model = m
    case .gemini: config.gemini.model = m
    case .openai: config.openai.model = m
    case .hosted: fail("the hosted service picks its own model")
    }
}
if let o = options.output { config.setOrder(o) }
if let s = options.styles { config.rewriteStyles = s }
if let j = options.jargon { config.jargonFile = j }
let effectiveConfig = config
let converter = Converter(loadConfig: { effectiveConfig })
let input = options.words.joined(separator: " ")
let jargon = JargonLibrary.load(from: config.jargonURL)
if options.jargon != nil, jargon.isEmpty { fail("no entries in \(config.jargonURL.path)") }

if config.provider == .bedrock {
    print("model \(config.modelId) · profile \(config.awsProfile) · region \(config.region ?? "(from profile)") · output \(config.outputLanguages.map(\.code).joined(separator: ",")) · \(options.mode.rawValue)")
} else {
    print("\(config.provider.displayName) · model \(config.settings(for: config.provider).model ?? "-") · output \(config.outputLanguages.map(\.code).joined(separator: ",")) · \(options.mode.rawValue)")
}
do {
    if let path = options.dumpPath {
        guard !input.isEmpty else { fail("--dump needs input text") }
        guard config.provider == .bedrock else { fail("--dump records Bedrock responses only") }
        try await dumpRawResponse(input, config: config, to: path)
    } else if options.bench {
        let styles = RewriteStyle.resolve(config.rewriteStyles).map(\.name)
        print("rewrite styles: \(styles.isEmpty ? "(none)" : styles.joined(separator: " "))")
        var totals: [TimeInterval] = []
        var changed: [String: Int] = [:]
        for (i, sample) in benchSamples.enumerated() {
            print("\(i + 1). \(sample)")
            let (result, t) = try await convert(sample, with: converter, raw: options.raw, jargon: jargon)
            let statuses = styles.map { style -> String in
                let status = rewriteStatus(result.rewrite(style), original: sample)
                if status == "改写" { changed[style, default: 0] += 1 }
                return "\(style) \(status)"
            }
            print("   \(statuses.joined(separator: " · ")) · first token \(seconds(t.firstToken)) · first version \(seconds(t.firstEnglish)) · total \(seconds(t.total))")
            totals.append(t.total)
        }
        let avg = totals.reduce(0, +) / Double(totals.count)
        print("rewrites that changed the wording: "
              + styles.map { "\($0) \(changed[$0, default: 0])/\(benchSamples.count)" }.joined(separator: ", "))
        print(String(format: "average total %.2fs (first request includes connection setup)", avg))
    } else {
        guard !input.isEmpty else { fail("no input") }
        let (result, t) = try await convert(input, with: converter, raw: options.raw, jargon: jargon)
        if result.isEmpty { fail("no candidates returned") }
        print("first token \(seconds(t.firstToken)) · first version \(seconds(t.firstEnglish)) · total \(seconds(t.total))")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(describe(error))\n".utf8))
    exit(1)
}
