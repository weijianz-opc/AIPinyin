import Foundation
import os
import Testing
@testable import AIPinyinCore

/// Serves canned responses keyed by host, so tests using different regions can run in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var chunks: [Data]
    }

    private struct State {
        var responses: [String: Response] = [:]
        var requests: [String: URLRequest] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func register(host: String, _ response: Response) {
        state.withLock { $0.responses[host] = response }
    }

    static func lastRequest(host: String) -> URLRequest? {
        state.withLock { $0.requests[host] }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let host = request.url?.host ?? ""
        let response = Self.state.withLock { state -> Response? in
            state.requests[host] = request
            return state.responses[host]
        }
        guard let response, let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                                         headerFields: response.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct ConverterTests {
    let expectedEnglish = [
        "I'm feeling a bit under the weather today.",
        "I'm not feeling great today.",
        "I'm a little off today.",
    ]

    func host(_ region: String) -> String { "bedrock-runtime.\(region).amazonaws.com" }

    func makeConverter(region: String) -> Converter {
        var config = Config.default
        config.region = region
        config.awsProfile = "test"
        let fixed = config
        return Converter(
            client: BedrockClient(session: StubURLProtocol.session()),
            loadConfig: { fixed },
            loadCredentials: { _ in
                AWSSharedConfig.Resolved(
                    credentials: AWSCredentials(accessKeyId: "AKIDTEST", secretAccessKey: "secret"),
                    region: nil)
            })
    }

    func chunks(_ bytes: [UInt8], size: Int) -> [Data] {
        stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0..<min($0 + size, bytes.count)]) }
    }

    func collect(_ stream: AsyncThrowingStream<ConversionUpdate, Error>) async throws -> [ConversionUpdate] {
        var updates: [ConversionUpdate] = []
        for try await update in stream { updates.append(update) }
        return updates
    }

    @Test func streamsRealResponseIntoCandidatesAndCaches() async throws {
        let region = "us-test-1"
        StubURLProtocol.register(host: host(region), .init(
            status: 200, headers: ["Content-Type": "application/vnd.amazon.eventstream"],
            chunks: chunks(try fixture("bedrock-converse-stream"), size: 37)))
        let converter = makeConverter(region: region)

        let updates = try await collect(converter.convert("我今天有点不舒服"))
        let final = try #require(updates.last)
        #expect(final.isFinal)
        #expect(!final.fromCache)
        #expect(final.firstTokenLatency != nil)
        // The capture predates the rewrite lines; its old "ZH:" line is ignored.
        #expect(final.result.rewrites.isEmpty)
        #expect(final.result.versions.map(\.text) == expectedEnglish)
        #expect(updates.count > 3)  // progressive updates while streaming
        #expect(updates.dropLast().allSatisfy { !$0.isFinal })

        let request = try #require(StubURLProtocol.lastRequest(host: host(region)))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString ==
            "https://bedrock-runtime.us-test-1.amazonaws.com/model/us.anthropic.claude-haiku-4-5-20251001-v1%3A0/converse-stream")
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        #expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDTEST/"))
        #expect(auth.contains("/us-test-1/bedrock/aws4_request"))
        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") != nil)

        let cached = try await collect(converter.convert("我今天有点不舒服"))
        #expect(cached.count == 1)
        #expect(cached.first?.fromCache == true)
        #expect(cached.first?.result == final.result)
    }

    @Test func mapsHTTPErrors() async throws {
        let region = "us-test-2"
        StubURLProtocol.register(host: host(region), .init(
            status: 403,
            headers: [
                "x-amzn-ErrorType": "AccessDeniedException:http://internal.amazon.com/coral/com.amazon.coral.service/",
                "Content-Type": "application/json",
            ],
            chunks: [Data(#"{"message":"You don't have access to the model with the specified model ID."}"#.utf8)]))
        let converter = makeConverter(region: region)
        await #expect(throws: BedrockError.http(
            status: 403, type: "AccessDeniedException",
            message: "You don't have access to the model with the specified model ID.")) {
            _ = try await collect(converter.convert("abc"))
        }
    }

    @Test func throwsStreamExceptions() async throws {
        let region = "us-test-3"
        StubURLProtocol.register(host: host(region), .init(
            status: 200, headers: [:], chunks: [Data(try fixture("all-header-types"))]))
        let converter = makeConverter(region: region)
        await #expect(throws: BedrockError.stream(
            type: "ThrottlingException", message: "Too many requests, please wait before trying again.")) {
            _ = try await collect(converter.convert("abc"))
        }
    }

    @Test func truncatedStreamIsAnError() async throws {
        let region = "us-test-4"
        let bytes = try fixture("bedrock-converse-stream")
        StubURLProtocol.register(host: host(region), .init(
            status: 200, headers: [:], chunks: [Data(bytes.dropLast(10))]))
        let converter = makeConverter(region: region)
        await #expect(throws: BedrockError.invalidResponse("stream ended mid-message")) {
            _ = try await collect(converter.convert("abc"))
        }
    }

    @Test func credentialErrorsPropagate() async {
        let converter = Converter(
            client: BedrockClient(session: StubURLProtocol.session()),
            loadConfig: { .default },
            loadCredentials: { throw AWSConfigError.profileNotFound($0) })
        await #expect(throws: AWSConfigError.profileNotFound("default")) {
            _ = try await collect(converter.convert("abc"))
        }
    }

    @Test func requestJSONShape() throws {
        var config = Config.default
        config.temperature = nil
        let data = try JSONEncoder().encode(Prompt.request(for: "你好", config: config))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inference = try #require(json["inferenceConfig"] as? [String: Any])
        #expect(inference["temperature"] == nil)
        #expect(inference["maxTokens"] as? Int == Config.default.maxTokens)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let roles = messages.compactMap { $0["role"] as? String }
        #expect(roles.count == Prompt.examples.count * 2 + 1)
        #expect(roles.enumerated().allSatisfy { $0.element == ($0.offset % 2 == 0 ? "user" : "assistant") })
        let last = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(last.first?["text"] as? String == "你好")
        let system = try #require(json["system"] as? [[String: Any]])
        let systemText = system.first?["text"] as? String ?? ""
        #expect(systemText.contains("EN:"))
        // Default presets: the format asks for exactly those lines, in that order.
        let tags = RewriteStyle.resolve(Config.default.rewriteStyles).map(\.tag)
        #expect(tags == ["POLISH", "CONCISE", "FORMAL"])
        let positions = tags.compactMap { systemText.range(of: "\n\($0): ")?.lowerBound }
        #expect(positions.count == 3 && positions == positions.sorted())
        #expect(!systemText.contains("CASUAL") && !systemText.contains("TACTFUL"))
        // Few-shot answers carry exactly the configured rewrite lines.
        let firstAnswer = try #require((messages[1]["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(CandidateParser.parse(firstAnswer, isFinal: true).rewrites.map(\.style) == ["润色", "简洁", "正式"])
    }

    @Test func promptFollowsConfiguredStyles() {
        var config = Config.default
        config.rewriteStyles = ["正式", "简洁", "不存在", "正式"]
        let request = Prompt.request(for: "你好", config: config)
        let system = request.system.first?.text ?? ""
        #expect(system.contains("\nFORMAL: ") && system.contains("\nCONCISE: ") && !system.contains("\nPOLISH: "))
        let answer = request.messages[1].content.first?.text ?? ""
        #expect(CandidateParser.parse(answer, isFinal: true).rewrites.map(\.style) == ["正式", "简洁"])

        config.rewriteStyles = []
        let plain = Prompt.request(for: "你好", config: config)
        let plainAnswer = plain.messages[1].content.first?.text ?? ""
        #expect(CandidateParser.parse(plainAnswer, isFinal: true).rewrites.isEmpty)
        let plainSystem = plain.system.first?.text ?? ""
        #expect(!plainSystem.contains("CONCISE"), "\(plainSystem)")
    }

    /// The hand-written example rewrites teach the model what each preset means: each must really
    /// reword its input and differ from the other presets.
    @Test func everyPresetExampleReallyRewords() {
        for (index, example) in Prompt.examples.enumerated() {
            var seen: Set<String> = [example.input.wordingKey]
            for style in RewriteStyle.catalog {
                #expect(style.exampleRewrites.count == Prompt.examples.count, "\(style.name)")
                let rewrite = style.exampleRewrites[index]
                #expect(seen.insert(rewrite.wordingKey).inserted, "\(style.name) for \(example.input): \(rewrite)")
            }
            let answer = Prompt.exampleAnswer(index, styles: RewriteStyle.catalog)
            let parsed = CandidateParser.parse(answer, isFinal: true)
            #expect(parsed.versions.count == 3, "\(example.input)")
            #expect(parsed.rewrites.map(\.style) == RewriteStyle.catalog.map(\.name), "\(example.input)")
        }
        let concise = RewriteStyle.named("简洁")!
        for (index, example) in Prompt.examples.enumerated() where example.input.containsHan {
            #expect(concise.exampleRewrites[index].count <= example.input.count, "简洁 is not shorter: \(example.input)")
        }
    }

    @Test func chineseOutputPromptAndExamples() {
        var config = Config.default
        config.outputLanguage = .chinese
        config.rewriteStyles = ["黑话"]
        let request = Prompt.request(for: "this is a blocker bug", config: config)
        let system = request.system.first?.text ?? ""
        #expect(system.contains("\nZH: <how a native Simplified Chinese speaker") && !system.contains("\nEN: "))
        #expect(system.contains("\nJARGON: ") && system.contains("bandwidth"))
        for (index, example) in Prompt.examples.enumerated() {
            let answer = request.messages[index * 2 + 1].content.first?.text ?? ""
            let parsed = CandidateParser.parse(answer, isFinal: true, output: .chinese)
            #expect(parsed.versions.count == 3 && parsed.versions.allSatisfy { $0.text.containsHan }, "\(example.input)")
            #expect(parsed.rewrites.map(\.style) == ["黑话"])
            // Rewrites stay in the input's language.
            #expect(parsed.rewrites[0].line.text.containsHan == example.input.containsHan, "\(example.input)")
        }
        #expect(request.messages.last?.content.first?.text == "this is a blocker bug")
    }

    @Test func everyExampleHasThreeVersionsInBothLanguages() {
        for example in Prompt.examples {
            #expect(example.english.count == 3 && example.chinese.count == 3, "\(example.input)")
            #expect(example.english.allSatisfy { !$0.containsHan } && example.chinese.allSatisfy { $0.containsHan })
            let wordings = Set((example.english + example.chinese).map(\.wordingKey))
            #expect(wordings.count == 6, "\(example.input): versions repeat each other")
        }
    }

    @Test func outputLanguageIsPartOfTheCacheKey() async throws {
        let region = "us-test-5"
        StubURLProtocol.register(host: host(region), .init(
            status: 200, headers: [:], chunks: [Data(try fixture("bedrock-converse-stream"))]))
        var config = Config.default
        config.region = region
        let english = config
        config.outputLanguage = .chinese
        let chinese = config
        let output = OSAllocatedUnfairLock(initialState: english)
        let converter = Converter(
            client: BedrockClient(session: StubURLProtocol.session()),
            loadConfig: { output.withLock { $0 } },
            loadCredentials: { _ in
                AWSSharedConfig.Resolved(credentials: AWSCredentials(accessKeyId: "AKIDTEST", secretAccessKey: "s"), region: nil)
            })
        let first = try await collect(converter.convert("我今天有点不舒服"))
        #expect(first.last?.result.versions.count == 3)
        output.withLock { $0 = chinese }
        let second = try await collect(converter.convert("我今天有点不舒服"))
        #expect(second.last?.fromCache == false)
        // The capture's EN lines don't count for Chinese output; its old "ZH:" line does.
        let versions = second.last?.result.versions ?? []
        #expect(versions.count == 1 && versions.allSatisfy { $0.text.containsHan })
    }

    @Test func jargonListIsReadOnlyWithTheStyleAndPartOfTheCacheKey() async throws {
        let region = "us-test-6"
        StubURLProtocol.register(host: host(region), .init(
            status: 200, headers: [:], chunks: [Data(try fixture("bedrock-converse-stream"))]))
        var config = Config.default
        config.region = region
        config.rewriteStyles = ["简洁"]
        let state = OSAllocatedUnfairLock(initialState: (config: config, list: [JargonEntry(term: "PRFAQ")], reads: 0))
        let converter = Converter(
            client: BedrockClient(session: StubURLProtocol.session()),
            loadConfig: { state.withLock { $0.config } },
            loadCredentials: { _ in
                AWSSharedConfig.Resolved(credentials: AWSCredentials(accessKeyId: "AKIDTEST", secretAccessKey: "s"), region: nil)
            },
            loadJargon: { _ in state.withLock { $0.reads += 1; return $0.list } })
        _ = try await collect(converter.convert("我今天有点不舒服"))
        #expect(state.withLock { $0.reads } == 0)  // no 黑话: the list isn't even read
        state.withLock { $0.config.rewriteStyles = ["黑话"] }
        let first = try await collect(converter.convert("我今天有点不舒服"))
        #expect(first.last?.fromCache == false && state.withLock { $0.reads } == 1)
        let again = try await collect(converter.convert("我今天有点不舒服"))
        #expect(again.last?.fromCache == true)
        state.withLock { $0.list = [JargonEntry(term: "LP")] }
        let changed = try await collect(converter.convert("我今天有点不舒服"))
        #expect(changed.last?.fromCache == false)  // a different list gives a different answer
    }

    @Test func serverErrorTextIsCapped() {
        let huge = String(repeating: "x", count: 100_000)
        guard case let .http(_, type, message) = BedrockClient.httpError(
            status: 500, typeHeader: String(repeating: "T", count: 500),
            body: Array(#"{"message":"\#(huge)"}"#.utf8))
        else { Issue.record("expected an HTTP error"); return }
        #expect(message.count <= 301)
        #expect((type ?? "").count <= 101)
    }

    @Test func truncatedOutputDropsTheCutOffLine() {
        let text = "EN: I'm under the weather.\nEN: I'm not feeling well.\nEN: I feel a bit o"
        let cut = Converter.finalResult(text, stopReason: "max_tokens")
        #expect(cut.versions.map(\.text) == ["I'm under the weather.", "I'm not feeling well."])
        #expect(cut.versions.allSatisfy { $0.isComplete })
        let rewriteCut = Converter.finalResult(text + "ff.\nPOLISH: 我今天", stopReason: "max_tokens")
        #expect(rewriteCut.versions.count == 3)
        #expect(rewriteCut.rewrites.isEmpty)
        let secondCut = Converter.finalResult(text + "ff.\nPOLISH: 我今天身体不太舒服。\nFORMAL: 今天", stopReason: "max_tokens")
        #expect(secondCut.rewrites == [Rewrite(style: "润色", line: CandidateLine("我今天身体不太舒服。"))])
        let normal = Converter.finalResult(text, stopReason: "end_turn")
        #expect(normal.versions.last?.text == "I feel a bit o")  // finished normally: last line is complete
    }

    @Test func lruEvictsOldest() {
        var cache = LRUCache(capacity: 2)
        let r = ConversionResult(versions: [CandidateLine("x")])
        cache.set("a", r)
        cache.set("b", r)
        _ = cache.get("a")
        cache.set("c", r)
        #expect(cache.get("a") == r)
        #expect(cache.get("b") == nil)
        #expect(cache.get("c") == r)
    }
}
