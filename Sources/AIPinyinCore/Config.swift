import Foundation

/// User-editable settings stored as JSON at `~/.config/aipinyin/config.json`.
/// Every key is optional in the file; missing keys fall back to `Config.default`.
public struct Config: Codable, Equatable, Sendable {
    /// Profile name in ~/.aws/credentials (static access keys).
    public var awsProfile: String
    /// Bedrock region. `nil` means: use the profile's region from ~/.aws/config, else us-east-1.
    public var region: String?
    /// Bedrock model or inference-profile ID used with the Converse API.
    public var modelId: String
    public var maxTokens: Int
    /// `nil` omits the field (some models on Bedrock reject `temperature`).
    public var temperature: Double?
    /// Network idle timeout for one conversion request.
    public var timeoutSeconds: Double
    /// Chinese rewrite presets offered after the English versions, in this order
    /// (names from `RewriteStyle.catalog`, e.g. "润色", "简洁", "正式"); empty = translation only.
    public var rewriteStyles: [String]

    public init(
        awsProfile: String, region: String?, modelId: String,
        maxTokens: Int, temperature: Double?, timeoutSeconds: Double,
        rewriteStyles: [String] = RewriteStyle.defaultNames
    ) {
        self.awsProfile = awsProfile
        self.region = region
        self.modelId = modelId
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.timeoutSeconds = timeoutSeconds
        self.rewriteStyles = rewriteStyles
    }

    public static let `default` = Config(
        awsProfile: "default",
        region: nil,
        modelId: "us.anthropic.claude-haiku-4-5-20251001-v1:0",
        // Three English versions plus the Chinese rewrites; only generated tokens are billed.
        maxTokens: 1000,
        temperature: 0.3,
        timeoutSeconds: 15,
        rewriteStyles: RewriteStyle.defaultNames
    )

    private enum CodingKeys: String, CodingKey {
        case awsProfile, region, modelId, maxTokens, temperature, timeoutSeconds, rewriteStyles
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
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/aipinyin/config.json")
    }

    /// Loads the config file. A missing file yields `Config.default`; a malformed file throws.
    public static func load(from url: URL = defaultURL) throws -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return .default
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
