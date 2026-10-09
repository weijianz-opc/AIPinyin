import Foundation

public struct AWSCredentials: Equatable, Sendable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

public enum AWSConfigError: Error, LocalizedError, Equatable {
    case profileNotFound(String)
    case unsupportedProfile(profile: String, kind: String)
    case missingKeys(profile: String)

    public var errorDescription: String? {
        switch self {
        case let .profileNotFound(p):
            return "找不到 AWS profile '\(p)'（~/.aws/credentials、~/.aws/config）"
        case let .unsupportedProfile(p, kind):
            return "AWS profile '\(p)' 使用 \(kind)，暂只支持静态 access key"
        case let .missingKeys(p):
            return "AWS profile '\(p)' 缺少 aws_access_key_id / aws_secret_access_key"
        }
    }
}

/// Reads static credentials and region from the AWS shared config files.
/// Supports `aws_access_key_id`, `aws_secret_access_key`, `aws_session_token` and `region`.
/// SSO, assume-role and credential_process profiles are reported as unsupported.
public enum AWSSharedConfig {
    public struct Resolved: Equatable, Sendable {
        public var credentials: AWSCredentials
        public var region: String?
    }

    public static func load(
        profile: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Resolved {
        let files = sharedFiles(environment)
        return try resolve(profile: profile, credentialsFile: files.credentials, configFile: files.config)
    }

    /// Profile names found in the shared files (names only; nothing secret is returned).
    public static func profileNames(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let files = sharedFiles(environment)
        let names = Set((files.credentials.map { parseINI($0, isConfigFile: false) } ?? [:]).keys)
            .union((files.config.map { parseINI($0, isConfigFile: true) } ?? [:]).keys)
        return names.sorted { a, b in a == "default" ? true : b == "default" ? false : a < b }
    }

    private static func sharedFiles(_ environment: [String: String]) -> (credentials: String?, config: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let credentialsPath = environment["AWS_SHARED_CREDENTIALS_FILE"]
            ?? home.appendingPathComponent(".aws/credentials").path
        let configPath = environment["AWS_CONFIG_FILE"]
            ?? home.appendingPathComponent(".aws/config").path
        return (try? String(contentsOfFile: credentialsPath, encoding: .utf8),
                try? String(contentsOfFile: configPath, encoding: .utf8))
    }

    public static func resolve(profile: String, credentialsFile: String?, configFile: String?) throws -> Resolved {
        let creds = credentialsFile.map { parseINI($0, isConfigFile: false) } ?? [:]
        let config = configFile.map { parseINI($0, isConfigFile: true) } ?? [:]
        let fromCreds = creds[profile]
        let fromConfig = config[profile]
        guard fromCreds != nil || fromConfig != nil else {
            throw AWSConfigError.profileNotFound(profile)
        }
        let region = nonEmpty(fromConfig?["region"]) ?? nonEmpty(fromCreds?["region"])

        // The credentials file wins over keys placed in the config file (AWS CLI behaviour).
        for section in [fromCreds, fromConfig].compactMap({ $0 }) {
            if let id = nonEmpty(section["aws_access_key_id"]),
               let secret = nonEmpty(section["aws_secret_access_key"]) {
                return Resolved(
                    credentials: AWSCredentials(
                        accessKeyId: id, secretAccessKey: secret,
                        sessionToken: nonEmpty(section["aws_session_token"])),
                    region: region)
            }
        }
        let merged = (fromConfig ?? [:]).merging(fromCreds ?? [:]) { a, _ in a }
        if merged["sso_session"] != nil || merged["sso_start_url"] != nil {
            throw AWSConfigError.unsupportedProfile(profile: profile, kind: "SSO")
        }
        if merged["role_arn"] != nil {
            throw AWSConfigError.unsupportedProfile(profile: profile, kind: "assume-role")
        }
        if merged["credential_process"] != nil {
            throw AWSConfigError.unsupportedProfile(profile: profile, kind: "credential_process")
        }
        throw AWSConfigError.missingKeys(profile: profile)
    }

    /// Minimal INI parser matching the AWS CLI file format.
    /// In the config file, `[profile name]` maps to `name`; `[default]` stays `default`.
    /// Indented lines (nested settings such as `s3 =` blocks) are ignored.
    static func parseINI(_ text: String, isConfigFile: Bool) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current: String?
        for rawLine in text.components(separatedBy: .newlines) {
            if let first = rawLine.first, first == " " || first == "\t" { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                var name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if isConfigFile, name.hasPrefix("profile ") {
                    name = String(name.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces)
                }
                current = name
                if sections[name] == nil { sections[name] = [:] }
                continue
            }
            guard let section = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            sections[section]?[key] = value
        }
        return sections
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
