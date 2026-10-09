import AllInOneIMECore
import Foundation

/// Interface language (settings window, candidate panel, notices, input menu): the one picked in the
/// settings (config `uiLanguage`), else the system's: Chinese when the system prefers Chinese to
/// English (System Settings → General → Language & Region), English otherwise.
enum UIText {
    /// Picked in the settings (applied from the config when a text field or the window opens);
    /// nil follows the system. Main thread only.
    static var choice: Language?
    /// Read once per process (macOS relaunches apps after a language change).
    static let systemPrefersChinese = prefersChinese(Locale.preferredLanguages)

    static var chinese: Bool { choice.map { $0 == .chinese } ?? systemPrefersChinese }

    /// Whether Chinese comes before English in the preferred languages; English if neither is listed.
    static func prefersChinese(_ languages: [String]) -> Bool {
        for language in languages {
            if language.hasPrefix("zh") { return true }
            if language.hasPrefix("en") { return false }
        }
        return false
    }

    /// "单按 ⌥" / "Tap ⌥", …
    static func name(_ key: TranslateKey) -> String {
        guard !chinese else { return key.displayName }
        switch key {
        case .optionTap: return "Tap ⌥"
        case .optionSpace: return "⌥Space"
        case .space: return "Space"
        }
    }

    /// "单按 ⌥" / "tap ⌥", "按空格" / "press Space", …
    static func howToPress(_ key: TranslateKey, english: Bool = false) -> String {
        guard !chinese else { return key.howToPress(english: english) }
        switch key {
        case .optionTap: return "tap ⌥"
        case .optionSpace: return "press ⌥Space"
        case .space: return english ? "press Space twice" : "press Space"
        }
    }

    static func name(_ language: Language) -> String {
        chinese ? language.displayName : language == .chinese ? "Chinese" : "English"
    }

    /// A rewrite preset's name in the window ("简洁" / "Concise"); the config keeps the Chinese name.
    static func name(_ style: RewriteStyle) -> String { chinese ? style.name : english(style).name }

    static func summary(_ style: RewriteStyle) -> String { chinese ? style.summary : english(style).summary }

    private static func english(_ style: RewriteStyle) -> (name: String, summary: String) {
        switch style.tag {
        case "POLISH": return ("Polish", "Same tone, more natural")
        case "CONCISE": return ("Concise", "Shorter, no filler")
        case "FORMAL": return ("Formal", "For managers and clients")
        case "CASUAL": return ("Casual", "Like chatting with a friend")
        case "TACTFUL": return ("Tactful", "Politer and softer")
        case "JARGON": return ("Jargon", "Big-tech speak, Amazon-style in English")
        default: return (style.name, style.summary)
        }
    }

    /// What the translate key does to a sentence in `input`: "翻译成英文 / 改写", "translate to English / rewrite", …
    static func action(input: Language, config: Config) -> String {
        guard !chinese else { return AllInOneIMEInputController.actionText(input: input, config: config) }
        let output = config.outputLanguage
        let action = input == output ? "polish the \(name(output))" : "translate to \(name(output))"
        return action + (RewriteStyle.resolve(config.rewriteStyles).isEmpty ? "" : " / rewrite")
    }

    /// An error as the settings window shows it.
    static func describe(_ error: Error) -> String {
        guard !chinese else { return AllInOneIMEInputController.describe(error) }
        switch error {
        case let error as URLError:
            switch error.code {
            case .timedOut: return "The request timed out"
            case .notConnectedToInternet, .networkConnectionLost: return "No network connection"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Can't reach Bedrock"
            default: return error.localizedDescription
            }
        case let AWSConfigError.profileNotFound(profile):
            return "AWS profile '\(profile)' not found (~/.aws/credentials, ~/.aws/config)"
        case let AWSConfigError.unsupportedProfile(profile, kind):
            return "AWS profile '\(profile)' uses \(kind); only static access keys are supported"
        case let AWSConfigError.missingKeys(profile):
            return "AWS profile '\(profile)' has no aws_access_key_id / aws_secret_access_key"
        case let BedrockError.invalidRegion(region): return "Invalid region: \(region)"
        case let BedrockError.http(status, type, message): return "Bedrock \(type ?? "HTTP \(status)"): \(message)"
        case let BedrockError.stream(type, message): return "Bedrock \(type): \(message)"
        case let BedrockError.invalidResponse(detail): return "Couldn't read the Bedrock response: \(detail)"
        case let ConfigError.malformed(path, detail): return "The config file is malformed (\(path)): \(detail)"
        case let error as VoiceError:
            switch error {
            case .unsupportedSystem: return "Voice input needs macOS 26 or later"
            case .unsupportedLanguage: return "This Mac can't recognize speech in this language"
            case let .modelMissing(language): return "The \(name(language)) speech model isn't installed"
            case .noMicrophone: return "No microphone available"
            case .noAudioFormat: return "Speech recognition can't use this audio format"
            }
        default:
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

/// Settings-window text in the system language (see `UIText`).
func tr(_ chinese: String, _ english: String) -> String { UIText.chinese ? chinese : english }
