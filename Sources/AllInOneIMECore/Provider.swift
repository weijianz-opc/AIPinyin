import Foundation

/// Where requests to the model go. Bedrock signs with AWS keys from ~/.aws; the others take an API
/// key (`APIKeys`).
public enum Provider: String, Codable, CaseIterable, Sendable {
    case bedrock
    /// The Claude API (api.anthropic.com).
    case anthropic
    /// The Gemini API (generativelanguage.googleapis.com).
    case gemini
    /// Any OpenAI-compatible chat completions API: OpenAI, DeepSeek, Qwen, OpenRouter, Ollama, …
    case openai

    public var displayName: String {
        switch self {
        case .bedrock: return "Amazon Bedrock"
        case .anthropic: return "Claude API"
        case .gemini: return "Gemini API"
        case .openai: return "OpenAI-compatible API"
        }
    }

    /// Environment variables (of the user's login shell) that hold the API key when the keychain has none.
    public var keyVariables: [String] {
        switch self {
        case .bedrock: return []
        case .anthropic: return ["ANTHROPIC_API_KEY"]
        case .gemini: return ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .openai: return ["OPENAI_API_KEY"]
        }
    }
}

/// The model settings of one API-key provider (`Config.anthropic`, `.gemini`, `.openai`).
/// Unset fields fall back to the provider's defaults (`ProviderSettings.defaults`).
public struct ProviderSettings: Codable, Equatable, Sendable {
    public var model: String?
    /// The API's base URL, e.g. "https://api.deepseek.com/v1" for an OpenAI-compatible service.
    public var baseURL: String?
    /// How much the model thinks: the Claude API's `output_config.effort`, Gemini's
    /// `thinkingConfig.thinkingLevel`, OpenAI's `reasoning_effort` ("low", "medium", "high").
    /// An empty string sends nothing (for models that don't take it).
    public var effort: String?
    /// Sent only when set: the current Claude models reject any non-default value.
    public var temperature: Double?

    public init(model: String? = nil, baseURL: String? = nil, effort: String? = nil, temperature: Double? = nil) {
        self.model = model
        self.baseURL = baseURL
        self.effort = effort
        self.temperature = temperature
    }

    public static func defaults(for provider: Provider) -> ProviderSettings {
        switch provider {
        case .bedrock:
            return ProviderSettings()
        case .anthropic:
            // The fastest, cheapest Claude at low effort: an input method waits on every sentence.
            return ProviderSettings(model: "claude-haiku-5-5", baseURL: "https://api.anthropic.com", effort: "low")
        case .gemini:
            return ProviderSettings(model: "gemini-3.8-flash", baseURL: "https://generativelanguage.googleapis.com",
                                    effort: "low")
        case .openai:
            return ProviderSettings(model: "", baseURL: "https://api.openai.com/v1", effort: "")
        }
    }

    /// These settings with the provider's defaults for whatever is unset or empty.
    public func resolved(for provider: Provider) -> ProviderSettings {
        let d = Self.defaults(for: provider)
        func pick(_ value: String?, _ fallback: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return fallback }
            return value
        }
        return ProviderSettings(model: pick(model, d.model), baseURL: pick(baseURL, d.baseURL),
                                effort: effort ?? d.effort, temperature: temperature ?? d.temperature)
    }

    /// `effort`, or nil when nothing is to be sent.
    var effortToSend: String? {
        guard let effort = effort?.trimmingCharacters(in: .whitespaces), !effort.isEmpty else { return nil }
        return effort
    }
}

public enum ProviderError: Error, LocalizedError, Equatable {
    /// No API key in the keychain or the login shell's environment.
    case missingKey(Provider)
    /// No model set (an OpenAI-compatible service has no default).
    case missingModel(Provider)
    case invalidBaseURL(String)
    case http(provider: Provider, status: Int, type: String?, message: String)
    case stream(provider: Provider, type: String, message: String)
    /// The model declined the request (the Claude API's `refusal` stop reason, Gemini's SAFETY finish).
    case refused(Provider)
    case invalidResponse(Provider, String)

    public var errorDescription: String? {
        switch self {
        case let .missingKey(p): return "No API key for the \(p.displayName): add one in the settings"
        case let .missingModel(p): return "No model set for the \(p.displayName)"
        case let .invalidBaseURL(url): return "Invalid base URL: \(url)"
        case let .http(p, status, type, message): return "\(p.displayName) \(type ?? "HTTP \(status)"): \(message)"
        case let .stream(p, type, message): return "\(p.displayName) \(type): \(message)"
        case let .refused(p): return "The \(p.displayName) declined this request"
        case let .invalidResponse(p, detail): return "Couldn't read the \(p.displayName) response: \(detail)"
        }
    }
}

/// Streams one request to the configured provider. The events are the same for every provider
/// (`BedrockStreamEvent`): text deltas, then the stop reason ("max_tokens" when cut off).
public struct ChatClient: Sendable {
    public let bedrock: BedrockClient
    public var session: URLSession { bedrock.session }

    public init(bedrock: BedrockClient = BedrockClient()) {
        self.bedrock = bedrock
    }

    public typealias CredentialLoader = @Sendable (_ profile: String) throws -> AWSSharedConfig.Resolved
    public typealias KeyLoader = @Sendable (_ provider: Provider) -> String?

    public func stream(_ body: ConverseRequest, config: Config, loadCredentials: CredentialLoader,
                       loadKey: KeyLoader) -> AsyncThrowingStream<BedrockStreamEvent, Error> {
        do {
            switch config.provider {
            case .bedrock:
                let resolved = try loadCredentials(config.awsProfile)
                return bedrock.converseStream(
                    body, modelId: config.modelId, region: config.region ?? resolved.region ?? "us-east-1",
                    credentials: resolved.credentials, timeout: config.timeoutSeconds)
            case .anthropic, .gemini, .openai:
                let provider = config.provider
                guard let key = loadKey(provider)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                    throw ProviderError.missingKey(provider)
                }
                let settings = config.settings(for: provider)
                let request = try HTTPProviders.makeRequest(body, provider: provider, settings: settings, key: key,
                                                            maxTokens: body.inferenceConfig.maxTokens ?? config.maxTokens,
                                                            timeout: config.timeoutSeconds)
                return SSEStream.events(request, provider: provider, session: session)
            }
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
