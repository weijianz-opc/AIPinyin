import Foundation

/// Requests to the API-key providers, and their streamed answers (server-sent events) as
/// `BedrockStreamEvent`s. Each API has its own shape:
/// - Claude API: `POST /v1/messages`, `x-api-key`, events `content_block_delta` / `message_delta`.
/// - Gemini API: `POST /v1beta/models/{model}:streamGenerateContent?alt=sse`, `x-goog-api-key`.
/// - OpenAI-compatible: `POST {base}/chat/completions`, `Authorization: Bearer`, ending with `[DONE]`.
public enum HTTPProviders {
    /// Room for thinking on top of the answer when an effort level is sent: the Claude and Gemini
    /// models count their thinking toward the output limit. Only generated tokens are billed.
    static let thinkingHeadroom = 4096

    /// Claude models that take the server-side refusal fallback (`fallbacks: "default"`): when a
    /// safety classifier declines, the API re-runs the request on a model that can answer.
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public static func makeRequest(_ body: ConverseRequest, provider: Provider, settings: ProviderSettings,
                                   key: String, maxTokens: Int, timeout: TimeInterval) throws -> URLRequest {
        guard let model = settings.model, !model.isEmpty else { throw ProviderError.missingModel(provider) }
        let base = (settings.baseURL ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let system = body.system.map(\.text).joined(separator: "\n\n")
        let effort = settings.effortToSend
        var headers = ["Content-Type": "application/json", "Accept": "text/event-stream"]
        let path: String
        var json: [String: Any]
        switch provider {
        case .anthropic:
            path = "/v1/messages"
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2023-06-01"
            json = [
                "model": model,
                "max_tokens": maxTokens + (effort == nil ? 0 : thinkingHeadroom),
                "stream": true,
                "system": system,
                "messages": body.messages.map { ["role": $0.role, "content": $0.content.map(\.text).joined()] },
            ]
            if let effort { json["output_config"] = ["effort": effort] }
            if fallbackModels.contains(model) {
                headers["anthropic-beta"] = fallbackBeta
                json["fallbacks"] = "default"
            }
        case .gemini:
            guard let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                throw ProviderError.missingModel(provider)
            }
            path = "/v1beta/models/\(encoded):streamGenerateContent?alt=sse"
            headers["x-goog-api-key"] = key
            var generation: [String: Any] = ["maxOutputTokens": maxTokens + (effort == nil ? 0 : thinkingHeadroom)]
            if let effort { generation["thinkingConfig"] = ["thinkingLevel": effort] }
            if let t = settings.temperature { generation["temperature"] = t }
            json = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": body.messages.map {
                    ["role": $0.role == "assistant" ? "model" : "user", "parts": $0.content.map { ["text": $0.text] }]
                },
                "generationConfig": generation,
            ]
        case .openai:
            path = "/chat/completions"
            headers["Authorization"] = "Bearer \(key)"
            json = [
                "model": model,
                "stream": true,
                "messages": [["role": "system", "content": system]]
                    + body.messages.map { ["role": $0.role, "content": $0.content.map(\.text).joined()] },
            ]
            // OpenAI's own API wants max_completion_tokens (its reasoning models reject max_tokens);
            // the compatible services (DeepSeek, Qwen, Ollama, …) take max_tokens.
            json[base.contains("api.openai.com") ? "max_completion_tokens" : "max_tokens"] = maxTokens
            if let effort { json["reasoning_effort"] = effort }
        case .bedrock:
            throw ProviderError.invalidResponse(provider, "Bedrock requests are signed by BedrockClient")
        }
        if provider != .gemini, let t = settings.temperature { json["temperature"] = t }
        guard let url = URL(string: base + path), let scheme = url.scheme, ["https", "http"].contains(scheme), url.host != nil else {
            throw ProviderError.invalidBaseURL(settings.baseURL ?? "")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// The events in one `data:` payload. Throws for an error event and a refusal.
    static func events(fromData payload: String, provider: Provider) throws -> [BedrockStreamEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw ProviderError.invalidResponse(provider, BedrockClient.capped(payload, 200))
        }
        if let error = object["error"] as? [String: Any] {
            throw ProviderError.stream(provider: provider, type: BedrockClient.capped(errorType(error) ?? "error", 100),
                                       message: BedrockClient.capped(error["message"] as? String ?? ""))
        }
        switch provider {
        case .anthropic:
            switch object["type"] as? String {
            case "content_block_delta":
                let delta = object["delta"] as? [String: Any]
                guard delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String else { return [] }
                return [.textDelta(text)]
            case "message_delta":
                guard let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String else { return [] }
                if reason == "refusal" { throw ProviderError.refused(provider) }
                return [.messageStop(reason: reason)]
            default:
                return []  // message_start, content_block_start/stop (thinking blocks too), ping, message_stop
            }
        case .gemini:
            if (object["promptFeedback"] as? [String: Any])?["blockReason"] != nil { throw ProviderError.refused(provider) }
            guard let candidate = (object["candidates"] as? [[String: Any]])?.first else { return [] }
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            var events = parts.compactMap { part -> BedrockStreamEvent? in
                guard part["thought"] as? Bool != true, let text = part["text"] as? String else { return nil }
                return .textDelta(text)
            }
            if let reason = candidate["finishReason"] as? String {
                if ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII"].contains(reason) { throw ProviderError.refused(provider) }
                events.append(.messageStop(reason: reason == "MAX_TOKENS" ? "max_tokens" : reason.lowercased()))
            }
            return events
        case .openai:
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { return [] }
            var events: [BedrockStreamEvent] = []
            // Only the answer: reasoning models may stream `reasoning_content` alongside it.
            if let text = (choice["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty {
                events.append(.textDelta(text))
            }
            if let reason = choice["finish_reason"] as? String {
                if reason == "content_filter" { throw ProviderError.refused(provider) }
                events.append(.messageStop(reason: reason == "length" ? "max_tokens" : reason))
            }
            return events
        case .bedrock:
            return []
        }
    }

    /// An error body: `{"error": {"type"|"status"|"code": …, "message": …}}` in all three APIs.
    static func httpError(provider: Provider, status: Int, body: [UInt8]) -> ProviderError {
        let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? object?["message"] as? String
            ?? String(decoding: body.prefix(500), as: UTF8.self)
        return .http(provider: provider, status: status, type: error.flatMap(errorType).map { BedrockClient.capped($0, 100) },
                     message: BedrockClient.capped(message))
    }

    private static func errorType(_ error: [String: Any]) -> String? {
        error["type"] as? String ?? error["status"] as? String ?? (error["code"]).map { "\($0)" }
    }
}

/// Reads a server-sent event stream: the `data:` lines, each turned into events by `HTTPProviders`.
enum SSEStream {
    static func events(_ request: URLRequest, provider: Provider, session: URLSession) -> AsyncThrowingStream<BedrockStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ProviderError.invalidResponse(provider, "not an HTTP response")
                    }
                    guard http.statusCode == 200 else {
                        var body = [UInt8]()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 64 * 1024 { break }
                        }
                        throw HTTPProviders.httpError(provider: provider, status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }  // event names, comments, keep-alives
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }
                        for event in try HTTPProviders.events(fromData: payload, provider: provider) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
