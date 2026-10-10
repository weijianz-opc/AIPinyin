import Foundation
import Testing
@testable import AllInOneIMECore

struct ProviderTests {
    let body = ConverseRequest(
        system: [.init("You are the writing assistant.")],
        messages: [.init(role: "user", text: "辛苦了"), .init(role: "assistant", text: "EN: Thanks."), .init(role: "user", text: "你好")],
        inferenceConfig: .init(maxTokens: 1000, temperature: 0.3))

    func json(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func request(_ provider: Provider, _ settings: ProviderSettings = ProviderSettings()) throws -> URLRequest {
        try HTTPProviders.makeRequest(body, provider: provider, settings: settings.resolved(for: provider),
                                      key: "sk-test", maxTokens: 1000, timeout: 15)
    }

    @Test func claudeRequest() throws {
        let r = try request(.anthropic, ProviderSettings(model: "claude-opus-5-5"))
        #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let j = try json(r)
        #expect(j["model"] as? String == "claude-opus-5-5" && j["stream"] as? Bool == true)
        #expect(try json(request(.anthropic))["model"] as? String == "claude-haiku-5-5")  // the default
        #expect(j["system"] as? String == "You are the writing assistant.")
        #expect((j["messages"] as? [[String: String]])?.map { $0["role"]! } == ["user", "assistant", "user"])
        #expect((j["output_config"] as? [String: String])?["effort"] == "low")
        #expect(j["max_tokens"] as? Int == 1000 + HTTPProviders.thinkingHeadroom)  // thinking counts toward it
        #expect(j["temperature"] == nil)  // current Claude models reject other values
        // The refusal fallback, on the models that take it.
        #expect(j["fallbacks"] as? String == "default")
        #expect(r.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let haiku = try request(.anthropic, ProviderSettings(effort: ""))
        let h = try json(haiku)
        #expect(h["fallbacks"] == nil && haiku.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(h["output_config"] == nil && h["max_tokens"] as? Int == 1000)
    }

    @Test func geminiRequest() throws {
        let r = try request(.gemini)
        #expect(r.url?.absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse")
        #expect(r.value(forHTTPHeaderField: "x-goog-api-key") == "sk-test")
        let j = try json(r)
        #expect(((j["systemInstruction"] as? [String: Any])?["parts"] as? [[String: String]])?.first?["text"]
            == "You are the writing assistant.")
        let contents = try #require(j["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])
        let generation = try #require(j["generationConfig"] as? [String: Any])
        #expect((generation["thinkingConfig"] as? [String: String])?["thinkingLevel"] == "low")
        #expect(generation["temperature"] == nil)
    }

    @Test func openAICompatibleRequest() throws {
        #expect(try json(request(.openai))["model"] as? String == "gpt-6-luna")  // the default, at OpenAI
        // Another service has no default model: a clear error rather than OpenAI's model sent there.
        #expect(throws: ProviderError.missingModel(.openai)) {
            try request(.openai, ProviderSettings(baseURL: "https://api.moonshot.cn/v1"))
        }
        #expect(throws: ProviderError.missingModel(.openai)) {
            try HTTPProviders.makeRequest(body, provider: .openai, settings: ProviderSettings(model: "", baseURL: "https://x.test"),
                                          key: "k", maxTokens: 10, timeout: 5)
        }
        let deepseek = try request(.openai, ProviderSettings(model: "deepseek-chat", baseURL: "https://api.deepseek.com/v1/",
                                                             temperature: 0.5))
        #expect(deepseek.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(deepseek.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let j = try json(deepseek)
        let messages = try #require(j["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"]! } == ["system", "user", "assistant", "user"])
        #expect(j["max_tokens"] as? Int == 1000 && j["temperature"] as? Double == 0.5 && j["reasoning_effort"] == nil)
        // OpenAI itself takes max_completion_tokens.
        let openai = try json(request(.openai, ProviderSettings(model: "some-model", effort: "low")))
        #expect(openai["max_completion_tokens"] as? Int == 1000 && openai["max_tokens"] == nil)
        #expect(openai["reasoning_effort"] as? String == "low")
        #expect(throws: ProviderError.invalidBaseURL("not a url")) {
            try request(.openai, ProviderSettings(model: "m", baseURL: "not a url"))
        }
    }

    @Test func claudeEvents() throws {
        func events(_ s: String) throws -> [BedrockStreamEvent] { try HTTPProviders.events(fromData: s, provider: .anthropic) }
        #expect(try events(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi"}}"#) == [.textDelta("Hi")])
        #expect(try events(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#).isEmpty)
        #expect(try events(#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#) == [.messageStop(reason: "max_tokens")])
        #expect(throws: ProviderError.refused(.anthropic)) {
            try events(#"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)
        }
        #expect(throws: ProviderError.stream(provider: .anthropic, type: "overloaded_error", message: "Overloaded")) {
            try events(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }

    @Test func geminiAndOpenAIEvents() throws {
        let gemini = #"{"candidates":[{"content":{"role":"model","parts":[{"text":"…","thought":true},{"text":"EN: Hi"}]},"finishReason":"MAX_TOKENS"}]}"#
        #expect(try HTTPProviders.events(fromData: gemini, provider: .gemini) == [.textDelta("EN: Hi"), .messageStop(reason: "max_tokens")])
        #expect(throws: ProviderError.refused(.gemini)) {
            try HTTPProviders.events(fromData: #"{"promptFeedback":{"blockReason":"SAFETY"}}"#, provider: .gemini)
        }
        let openai = #"{"choices":[{"index":0,"delta":{"content":"Hi","reasoning_content":"hmm"},"finish_reason":null}]}"#
        #expect(try HTTPProviders.events(fromData: openai, provider: .openai) == [.textDelta("Hi")])
        #expect(try HTTPProviders.events(fromData: #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#, provider: .openai)
            == [.messageStop(reason: "max_tokens")])
    }

    @Test func httpErrors() {
        let claude = Array(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        #expect(HTTPProviders.httpError(provider: .anthropic, status: 401, body: claude)
            == .http(provider: .anthropic, status: 401, type: "authentication_error", message: "invalid x-api-key"))
        let gemini = Array(#"{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT"}}"#.utf8)
        #expect(HTTPProviders.httpError(provider: .gemini, status: 400, body: gemini)
            == .http(provider: .gemini, status: 400, type: "INVALID_ARGUMENT", message: "API key not valid."))
        #expect(HTTPProviders.httpError(provider: .openai, status: 502, body: Array("Bad Gateway".utf8))
            == .http(provider: .openai, status: 502, type: nil, message: "Bad Gateway"))
    }

    @Test func configKeepsProviderSettings() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("""
            {"provider": "openai", "openai": {"model": "deepseek-chat", "baseURL": "https://api.deepseek.com/v1"}}
            """.utf8))
        #expect(config.provider == .openai && config.activeModel == "openai:deepseek-chat")
        #expect(config.settings(for: .openai).baseURL == "https://api.deepseek.com/v1")
        #expect(config.settings(for: .anthropic).model == "claude-haiku-5-5")  // defaults for the others
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(old.provider == .bedrock && old.activeModel == Config.default.modelId)  // existing files keep Bedrock
        let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(again == config)
    }

    /// The whole way through the converter: SSE from a stubbed Claude API into candidates.
    @Test func convertsThroughTheClaudeAPI() async throws {
        let host = "claude.test"
        let sse = [
            #"event: message_start"#, #"data: {"type":"message_start","message":{"id":"msg_1"}}"#, "",
            #"event: content_block_delta"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"EN: Thanks for all\n"}}"#, "",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"EN: You worked hard.\nEN: Much appreciated.\n"}}"#, "",
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, "",
            #"data: {"type":"message_stop"}"#, "",
        ].joined(separator: "\n")
        StubURLProtocol.register(host: host, .init(status: 200, headers: ["Content-Type": "text/event-stream"],
                                                   chunks: [Data(sse.utf8)]))
        var config = Config.default
        config.provider = .anthropic
        config.anthropic.baseURL = "https://\(host)"
        config.rewriteStyles = []
        let fixed = config
        let converter = Converter(client: BedrockClient(session: StubURLProtocol.session()), loadConfig: { fixed },
                                  loadKey: { $0 == .anthropic ? "sk-test" : nil })
        var final: ConversionUpdate?
        for try await update in converter.convert("辛苦了") where update.isFinal { final = update }
        #expect(final?.result.versions.map(\.text) == ["Thanks for all", "You worked hard.", "Much appreciated."])
        #expect(StubURLProtocol.lastRequest(host: host)?.value(forHTTPHeaderField: "x-api-key") == "sk-test")

        // Without a key: a clear error, nothing sent.
        let noKey = Converter(client: BedrockClient(session: StubURLProtocol.session()), loadConfig: { fixed }, loadKey: { _ in nil })
        await #expect(throws: ProviderError.missingKey(.anthropic)) {
            for try await _ in noKey.convert("你好") {}
        }
    }

    @Test func hostedRequestAndEvents() throws {
        let r = try HTTPProviders.makeRequest(body, provider: .hosted, settings: ProviderSettings(model: "hosted", baseURL: "https://svc.test/"),
                                              key: "v1.session", maxTokens: 1000, timeout: 15)
        #expect(r.url?.absoluteString == "https://svc.test/chat")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer v1.session")
        let j = try json(r)
        #expect(j["model"] == nil)  // the service picks it
        #expect((j["system"] as? [[String: String]])?.first?["text"] == "You are the writing assistant.")
        #expect((j["messages"] as? [[String: Any]])?.count == 3)
        #expect((j["inferenceConfig"] as? [String: Any])?["maxTokens"] as? Int == 1000)
        #expect(try HTTPProviders.events(fromData: #"{"text":"EN: Hi"}"#, provider: .hosted) == [.textDelta("EN: Hi")])
        #expect(try HTTPProviders.events(fromData: #"{"stop":"end_turn"}"#, provider: .hosted) == [.messageStop(reason: "end_turn")])
        #expect(throws: ProviderError.stream(provider: .hosted, type: "ThrottlingException", message: "The model request failed")) {
            try HTTPProviders.events(fromData: #"{"error":{"type":"ThrottlingException","message":"The model request failed"}}"#, provider: .hosted)
        }
        #expect(HTTPProviders.httpError(provider: .hosted, status: 401, body: []) == .signedOut)
        #expect(HTTPProviders.httpError(provider: .hosted, status: 402, body: []) == .quotaExhausted)
    }

    @Test func signInUsesPKCE() throws {
        let signIn = HostedSignIn(domain: "aio.auth.us-east-1.amazoncognito.com", clientId: "client-1")
        func items(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        }
        let email = signIn.authorizationURL(.email)
        #expect(email.absoluteString.hasPrefix("https://aio.auth.us-east-1.amazoncognito.com/oauth2/authorize?"))
        let q = items(email)
        #expect(q["client_id"] == "client-1" && q["redirect_uri"] == "allinoneime://auth" && q["response_type"] == "code")
        #expect(q["scope"] == "openid email" && q["code_challenge_method"] == "S256" && q["state"] == signIn.state)
        #expect(q["code_challenge"] != signIn.verifier && (q["code_challenge"]?.count ?? 0) == 43)
        #expect(q["identity_provider"] == nil)  // the pool's page: email, with sign-up
        #expect(items(signIn.authorizationURL(.google))["identity_provider"] == "Google")  // straight to Google
        let back = try #require(URL(string: "allinoneime://auth?code=abc-123&state=\(signIn.state)"))
        #expect(signIn.code(from: back) == "abc-123")
        let forged = try #require(URL(string: "allinoneime://auth?code=abc-123&state=other"))
        #expect(signIn.code(from: forged) == nil)  // not the answer to this sign-in
    }

    @Test func checkoutCarriesTheUser() throws {
        let url = try #require(HostedService.checkoutURL(sub: "1001", email: "a+b@example.com", link: "https://buy.stripe.com/test_123"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "client_reference_id" }?.value == "1001")
        #expect(items.first { $0.name == "prefilled_email" }?.value == "a+b@example.com")
        #expect(HostedService.checkoutURL(sub: "1", email: nil, link: "") == nil)
        let payload = Data(#"{"sub":"1001","email":"a@example.com","exp":9999999999}"#.utf8).base64URL
        #expect(HostedAccount.sessionSubject("v1.\(payload).mac") == "1001")
        #expect(HostedAccount.sessionSubject("garbage") == nil)
    }

    /// The whole way through the converter, against a stubbed service.
    @Test func convertsThroughTheHostedService() async throws {
        let host = "hosted.test"
        let sse = #"data: {"text":"EN: Thanks a lot.\nEN: Appreciate it.\nEN: Thank you!\n"}"# + "\n\n" + #"data: {"stop":"end_turn"}"# + "\n\n"
        StubURLProtocol.register(host: host, .init(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: [Data(sse.utf8)]))
        var config = Config.default
        config.provider = .hosted
        config.rewriteStyles = []
        let fixed = config
        // The hosted base URL comes from HostedService; here the stub's host stands in for it.
        let request = try HTTPProviders.makeRequest(body, provider: .hosted, settings: ProviderSettings(baseURL: "https://\(host)"),
                                                    key: "v1.s", maxTokens: 10, timeout: 5)
        var texts: [String] = []
        for try await event in SSEStream.events(request, provider: .hosted, session: StubURLProtocol.session()) {
            if case let .textDelta(text) = event { texts.append(text) }
        }
        #expect(texts.joined() == "EN: Thanks a lot.\nEN: Appreciate it.\nEN: Thank you!\n")
        // Signed out: a clear error, nothing sent.
        let converter = Converter(client: BedrockClient(session: StubURLProtocol.session()), loadConfig: { fixed }, loadKey: { _ in nil })
        await #expect(throws: ProviderError.signedOut) {
            for try await _ in converter.convert("你好") {}
        }
    }
}
