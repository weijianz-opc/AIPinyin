import Foundation

/// User-editable settings stored as JSON at `~/.config/allinoneime/config.json`.
/// Every key is optional in the file; missing keys fall back to `Config.default`.
public struct Config: Codable, Equatable, Sendable {
    /// Where requests go: Amazon Bedrock (the settings below), or an API-key provider with its own
    /// settings (`anthropic`, `gemini`, `openai`).
    public var provider: Provider
    /// Profile name in ~/.aws/credentials (static access keys).
    public var awsProfile: String
    /// Bedrock region. `nil` means: use the profile's region from ~/.aws/config, else us-east-1.
    public var region: String?
    /// Bedrock model or inference-profile ID used with the Converse API.
    public var modelId: String
    /// The Claude API, the Gemini API and an OpenAI-compatible API (the key is in `APIKeys`).
    public var anthropic: ProviderSettings
    public var gemini: ProviderSettings
    public var openai: ProviderSettings
    public var maxTokens: Int
    /// `nil` omits the field (some models on Bedrock reject `temperature`).
    public var temperature: Double?
    /// Network idle timeout for one conversion request.
    public var timeoutSeconds: Double
    /// Rewrite presets offered after the three main versions, in this order (names from
    /// `RewriteStyle.catalog`, e.g. "润色" polish, "简洁" concise, "正式" formal); empty = main versions only.
    /// Rewrites are in the language the sentence was typed in.
    public var rewriteStyles: [String]
    /// Language of the three main versions (1–3): a sentence in another language is translated,
    /// one already in this language is polished.
    public var outputLanguage: Language
    /// Mode a new text field starts in: pinyin (Chinese) or English letters.
    public var defaultInput: Language
    /// In sentence mode, English typed in English mode also collects into a draft that the action key
    /// sends to the model (false: English letters go straight to the application).
    public var englishAI: Bool
    /// Hold the right Option key to dictate into the draft (on-device speech recognition).
    public var voiceInput: Bool
    /// The user's own jargon list for the jargon (黑话) style (see `JargonLibrary`); nil = the default file.
    public var jargonFile: String?
    /// The key that sends a finished sentence to the model.
    public var actionKey: ActionKey
    /// Language of the settings window; nil follows the system.
    public var uiLanguage: Language?
    /// The user's own @ commands, after the built-in ones (see `CustomCommand`).
    public var customCommands: [CustomCommand]
    /// `@claude` runs as a Claude Code background session, with a notification when it's done
    /// (false: an interactive session in Terminal).
    public var claudeInBackground: Bool

    /// The settings of an API-key provider, with its defaults filled in.
    public func settings(for provider: Provider) -> ProviderSettings {
        switch provider {
        case .bedrock: return ProviderSettings(model: modelId, temperature: temperature)
        case .anthropic: return anthropic.resolved(for: .anthropic)
        case .gemini: return gemini.resolved(for: .gemini)
        case .openai: return openai.resolved(for: .openai)
        case .hosted: return ProviderSettings().resolved(for: .hosted)
        }
    }

    /// The model requests go to, with the provider (it is part of the cache keys).
    public var activeModel: String {
        provider == .bedrock ? modelId : "\(provider.rawValue):\(settings(for: provider).model ?? "")"
    }

    /// `jargonFile` with "~" expanded, or `JargonLibrary.defaultURL`.
    public var jargonURL: URL {
        guard let path = jargonFile?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
            return JargonLibrary.defaultURL
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    public init(
        awsProfile: String, region: String?, modelId: String,
        maxTokens: Int, temperature: Double?, timeoutSeconds: Double,
        rewriteStyles: [String] = RewriteStyle.defaultNames,
        outputLanguage: Language = .english, defaultInput: Language = .chinese,
        englishAI: Bool = true, voiceInput: Bool = true, jargonFile: String? = nil,
        actionKey: ActionKey = .enter, uiLanguage: Language? = nil, customCommands: [CustomCommand] = [],
        provider: Provider = .bedrock, anthropic: ProviderSettings = ProviderSettings(),
        gemini: ProviderSettings = ProviderSettings(), openai: ProviderSettings = ProviderSettings()
    ) {
        self.provider = provider
        self.anthropic = anthropic
        self.gemini = gemini
        self.openai = openai
        self.awsProfile = awsProfile
        self.region = region
        self.modelId = modelId
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.timeoutSeconds = timeoutSeconds
        self.rewriteStyles = rewriteStyles
        self.outputLanguage = outputLanguage
        self.defaultInput = defaultInput
        self.englishAI = englishAI
        self.voiceInput = voiceInput
        self.jargonFile = jargonFile
        self.actionKey = actionKey
        self.uiLanguage = uiLanguage
        self.customCommands = customCommands
        self.claudeInBackground = true
    }

    public static let `default` = Config(
        awsProfile: "default",
        region: nil,
        modelId: "us.anthropic.claude-haiku-4-5-20251001-v1:0",
        // Three main versions plus the rewrites; only generated tokens are billed.
        maxTokens: 1000,
        temperature: 0.3,
        timeoutSeconds: 15,
        rewriteStyles: RewriteStyle.defaultNames
    )

    private enum CodingKeys: String, CodingKey {
        case awsProfile, region, modelId, maxTokens, temperature, timeoutSeconds, rewriteStyles
        case outputLanguage, defaultInput, englishAI, voiceInput, jargonFile, actionKey, uiLanguage, customCommands, claudeInBackground
        case provider, anthropic, gemini, openai
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        awsProfile = try c.decodeIfPresent(String.self, forKey: .awsProfile) ?? d.awsProfile
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? d.region
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId) ?? d.modelId
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? d.maxTokens
        // An explicit `null` disables temperature; an absent key keeps the default.
        temperature = c.contains(.temperature)
            ? try c.decodeIfPresent(Double.self, forKey: .temperature)
            : d.temperature
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        rewriteStyles = try c.decodeIfPresent([String].self, forKey: .rewriteStyles) ?? d.rewriteStyles
        outputLanguage = try c.decodeIfPresent(Language.self, forKey: .outputLanguage) ?? d.outputLanguage
        defaultInput = try c.decodeIfPresent(Language.self, forKey: .defaultInput) ?? d.defaultInput
        englishAI = try c.decodeIfPresent(Bool.self, forKey: .englishAI) ?? d.englishAI
        voiceInput = try c.decodeIfPresent(Bool.self, forKey: .voiceInput) ?? d.voiceInput
        jargonFile = try c.decodeIfPresent(String.self, forKey: .jargonFile)
        actionKey = try c.decodeIfPresent(ActionKey.self, forKey: .actionKey) ?? d.actionKey
        uiLanguage = try c.decodeIfPresent(Language.self, forKey: .uiLanguage)
        customCommands = try c.decodeIfPresent([CustomCommand].self, forKey: .customCommands) ?? d.customCommands
        claudeInBackground = try c.decodeIfPresent(Bool.self, forKey: .claudeInBackground) ?? d.claudeInBackground
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? d.provider
        anthropic = try c.decodeIfPresent(ProviderSettings.self, forKey: .anthropic) ?? d.anthropic
        gemini = try c.decodeIfPresent(ProviderSettings.self, forKey: .gemini) ?? d.gemini
        openai = try c.decodeIfPresent(ProviderSettings.self, forKey: .openai) ?? d.openai
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(awsProfile, forKey: .awsProfile)
        try c.encode(region, forKey: .region)  // written as null so the key is discoverable
        try c.encode(modelId, forKey: .modelId)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try c.encode(rewriteStyles, forKey: .rewriteStyles)
        try c.encode(outputLanguage, forKey: .outputLanguage)
        try c.encode(defaultInput, forKey: .defaultInput)
        try c.encode(englishAI, forKey: .englishAI)
        try c.encode(voiceInput, forKey: .voiceInput)
        try c.encode(jargonFile, forKey: .jargonFile)  // null: the default file
        try c.encode(actionKey, forKey: .actionKey)
        try c.encode(uiLanguage, forKey: .uiLanguage)  // null: follow the system
        try c.encode(customCommands, forKey: .customCommands)
        try c.encode(claudeInBackground, forKey: .claudeInBackground)
        try c.encode(provider, forKey: .provider)
        try c.encode(anthropic, forKey: .anthropic)
        try c.encode(gemini, forKey: .gemini)
        try c.encode(openai, forKey: .openai)
    }

    /// A new user's settings (no config file yet): the hosted service once it is set up, which needs
    /// nothing but a Google sign-in. A file without `provider` (from before providers) stays on Bedrock.
    public static var fresh: Config {
        var config = Config.default
        if HostedService.isConfigured { config.provider = .hosted }
        return config
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/allinoneime/config.json")
    }

    /// Loads the config file. A missing file yields `Config.default`; a malformed file throws.
    public static func load(from url: URL = defaultURL) throws -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return .fresh
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigError.malformed(path: url.path, detail: String(describing: error))
        }
    }

    public func write(to url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum ConfigError: Error, LocalizedError, Equatable {
    case malformed(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .malformed(path, detail):
            return "配置文件格式错误（\(path)）：\(detail)"
        }
    }
}
