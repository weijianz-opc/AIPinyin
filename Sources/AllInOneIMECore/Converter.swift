import Foundation
import os

public struct ConversionUpdate: Equatable, Sendable {
    public var result: ConversionResult
    public var rawText: String
    public var isFinal: Bool
    /// Seconds since the conversion started.
    public var elapsed: TimeInterval
    /// Seconds until the first text delta arrived (nil until then, and for cache hits).
    public var firstTokenLatency: TimeInterval?
    public var fromCache: Bool
}

/// Turns typed input into streamed `ConversionUpdate`s using Bedrock.
/// Config and credentials are re-read for every conversion, so edits apply without a restart.
public final class Converter: Sendable {
    public typealias ConfigLoader = @Sendable () throws -> Config
    public typealias CredentialLoader = @Sendable (_ profile: String) throws -> AWSSharedConfig.Resolved
    /// The user's jargon list for a config (only asked for when the jargon (黑话) style is on).
    public typealias JargonLoader = @Sendable (_ config: Config) -> [JargonEntry]

    private let client: BedrockClient
    private let loadConfig: ConfigLoader
    private let loadCredentials: CredentialLoader
    private let loadJargon: JargonLoader
    private let cache = OSAllocatedUnfairLock(initialState: LRUCache(capacity: 64))

    public init(
        client: BedrockClient = BedrockClient(),
        loadConfig: @escaping ConfigLoader = { try Config.load() },
        loadCredentials: @escaping CredentialLoader = { try AWSSharedConfig.load(profile: $0) },
        loadJargon: @escaping JargonLoader = { JargonLibrary.load(from: $0.jargonURL) }
    ) {
        self.client = client
        self.loadConfig = loadConfig
        self.loadCredentials = loadCredentials
        self.loadJargon = loadJargon
    }

    public func convert(_ input: String) -> AsyncThrowingStream<ConversionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(input, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ input: String, continuation: AsyncThrowingStream<ConversionUpdate, Error>.Continuation) async throws {
        let started = ContinuousClock.now
        func elapsed() -> TimeInterval {
            let d = ContinuousClock.now - started
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }

        let config = try loadConfig()
        let output = config.outputLanguage
        let presets = RewriteStyle.resolve(config.rewriteStyles)
        let styles = presets.map(\.tag).joined(separator: ",")
        let jargon = presets.contains { $0.tag == RewriteStyle.jargonTag } ? loadJargon(config) : []
        let jargonKey = jargon.isEmpty ? "" : "j\(JargonLibrary.fingerprint(jargon))|"
        let key = "\(config.modelId)|\(Prompt.version)|\(output.rawValue)|\(styles)|\(jargonKey)\(input)"
        if let hit = cache.withLock({ $0.get(key) }) {
            continuation.yield(ConversionUpdate(
                result: hit, rawText: "", isFinal: true, elapsed: elapsed(),
                firstTokenLatency: nil, fromCache: true))
            return
        }

        let resolved = try loadCredentials(config.awsProfile)
        let region = config.region ?? resolved.region ?? "us-east-1"
        let stream = client.converseStream(
            Prompt.request(for: input, config: config, jargon: jargon),
            modelId: config.modelId, region: region,
            credentials: resolved.credentials, timeout: config.timeoutSeconds)

        var text = ""
        var firstToken: TimeInterval?
        var stopReason: String?
        var lastResult = ConversionResult.empty
        for try await event in stream {
            if case let .messageStop(reason) = event { stopReason = reason }
            guard case let .textDelta(delta) = event else { continue }
            if firstToken == nil { firstToken = elapsed() }
            text += delta
            // Far more than 3 sentences plus the rewrites; treat the rest as truncated.
            if text.utf8.count > Self.maxOutputBytes {
                stopReason = "max_tokens"
                break
            }
            let result = CandidateParser.parse(text, isFinal: false, output: output)
            // Most deltas only extend a line; skip updates that don't change what is shown.
            guard result != lastResult else { continue }
            lastResult = result
            continuation.yield(ConversionUpdate(
                result: result, rawText: text, isFinal: false, elapsed: elapsed(),
                firstTokenLatency: firstToken, fromCache: false))
        }
        try Task.checkCancellation()

        let final = Self.finalResult(text, stopReason: stopReason, output: output)
        if !final.isEmpty, stopReason != "max_tokens" {
            cache.withLock { $0.set(key, final) }
        }
        continuation.yield(ConversionUpdate(
            result: final, rawText: text, isFinal: true, elapsed: elapsed(),
            firstTokenLatency: firstToken, fromCache: false))
    }

    /// Runs a `.generate` command: the answer streams in as the single version of the result.
    public func generate(_ command: Command, input: String) -> AsyncThrowingStream<ConversionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runCommand(command, input: input, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runCommand(_ command: Command, input: String,
                            continuation: AsyncThrowingStream<ConversionUpdate, Error>.Continuation) async throws {
        let started = ContinuousClock.now
        func elapsed() -> TimeInterval {
            let d = ContinuousClock.now - started
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let config = try loadConfig()
        let key = "@\(command.rawValue)|\(config.modelId)|\(Prompt.commandVersion)|\(input)"
        if let hit = cache.withLock({ $0.get(key) }) {
            continuation.yield(ConversionUpdate(
                result: hit, rawText: "", isFinal: true, elapsed: elapsed(), firstTokenLatency: nil, fromCache: true))
            return
        }
        let resolved = try loadCredentials(config.awsProfile)
        let stream = client.converseStream(
            Prompt.commandRequest(command, input: input, config: config),
            modelId: config.modelId, region: config.region ?? resolved.region ?? "us-east-1",
            credentials: resolved.credentials, timeout: config.timeoutSeconds)
        func answer(_ text: String, complete: Bool) -> ConversionResult {
            ConversionResult(versions: [CandidateLine(Self.oneLine(text), isComplete: complete)])
        }
        var text = ""
        var firstToken: TimeInterval?
        var stopReason: String?
        for try await event in stream {
            if case let .messageStop(reason) = event { stopReason = reason }
            guard case let .textDelta(delta) = event else { continue }
            if firstToken == nil { firstToken = elapsed() }
            text += delta
            if text.utf8.count > Self.maxOutputBytes { stopReason = "max_tokens"; break }
            continuation.yield(ConversionUpdate(
                result: answer(text, complete: false), rawText: text, isFinal: false, elapsed: elapsed(),
                firstTokenLatency: firstToken, fromCache: false))
        }
        try Task.checkCancellation()
        // Cut off at the token limit, the text still reads as an answer: keep it, but don't cache it.
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : answer(text, complete: true)
        if !final.isEmpty, stopReason != "max_tokens" { cache.withLock { $0.set(key, final) } }
        continuation.yield(ConversionUpdate(
            result: final, rawText: text, isFinal: true, elapsed: elapsed(), firstTokenLatency: firstToken, fromCache: false))
    }

    /// Model text as one line that is safe to insert anywhere, including a terminal: controls and
    /// line breaks become spaces (see `CandidateParser.stripControls`), runs of spaces collapse.
    static func oneLine(_ text: String) -> String {
        CandidateParser.stripControls(text).split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    /// When the model hit the token limit, its last line was cut off mid-sentence: drop it rather
    /// than offer a truncated sentence as a finished candidate.
    static let maxOutputBytes = 32 * 1024

    static func finalResult(_ text: String, stopReason: String?, output: Language = .english) -> ConversionResult {
        guard stopReason == "max_tokens" else { return CandidateParser.parse(text, isFinal: true, output: output) }
        var result = CandidateParser.parse(text, isFinal: false, output: output)
        result.versions = result.versions.filter { $0.isComplete }
        result.rewrites = result.rewrites.filter { $0.line.isComplete }
        return result
    }
}

/// Tiny LRU keyed by string; recency tracked with an ordered array (capacity is small).
struct LRUCache: Sendable {
    let capacity: Int
    private var values: [String: ConversionResult] = [:]
    private var order: [String] = []

    init(capacity: Int) { self.capacity = capacity }

    mutating func get(_ key: String) -> ConversionResult? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func set(_ key: String, _ value: ConversionResult) {
        values[key] = value
        touch(key)
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
