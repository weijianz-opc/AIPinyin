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
    static func name(_ key: ActionKey) -> String {
        guard !chinese else { return key.displayName }
        switch key {
        case .enter: return "⏎"
        case .optionTap: return "Tap ⌥"
        case .optionSpace: return "⌥Space"
        case .space: return "Space"
        }
    }

    /// The action key in the settings picker: "⏎ 回车" / "⏎ Return", otherwise as `name`.
    static func pickerName(_ key: ActionKey) -> String {
        key == .enter ? tr("⏎ 回车", "⏎ Return") : name(key)
    }

    /// "单按 ⌥" / "tap ⌥", "按空格" / "press Space", …
    static func howToPress(_ key: ActionKey, english: Bool = false) -> String {
        guard !chinese else { return key.howToPress(english: english) }
        switch key {
        case .enter: return "press Return"
        case .optionTap: return "tap ⌥"
        case .optionSpace: return "press ⌥Space"
        case .space: return english ? "press Space twice" : "press Space"
        }
    }

    static func name(_ provider: Provider) -> String {
        switch provider {
        case .openai: return tr("兼容 OpenAI 的服务", "OpenAI-compatible API")
        case .hosted: return tr("AllInOneIME 云（登录即用）", "AllInOneIME Cloud (sign in)")
        default: return provider.displayName
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

    /// What the action key does to a sentence in `input`: "翻译成英文 / 改写", "translate to English / rewrite", …
    static func action(input: Language, config: Config) -> String {
        guard !chinese else { return AllInOneIMEInputController.actionText(input: input, config: config) }
        let output = config.outputLanguage
        let action = input == output ? "polish the \(name(output))" : "translate to \(name(output))"
        return action + (RewriteStyle.resolve(config.rewriteStyles).isEmpty ? "" : " / rewrite")
    }

    /// What a command does, in the palette: "提问，答案可以直接上屏" / "Ask a question; insert the answer".
    static func summary(_ command: Command) -> String {
        if let plugin = command.plugin {
            return plugin.manifest.summary?.text(chinese: chinese) ?? tr("插件", "Plugin")
        }
        if let custom = command.custom { return custom.summary ?? customKind(custom) }
        switch command {
        case .improve: return tr("润色 / 翻译，和不加命令一样", "Polish / translate, as without a command")
        case .question: return tr("提问，答案可以直接上屏", "Ask a question; insert the answer")
        case .claude: return tr("交给 Claude Code 去做", "Hand it to Claude Code")
        case .open: return tr("找文件、文件夹或 App 并打开", "Find a file, folder or app and open it")
        case .read: return tr("读网页正文，可放在句中给 AI 当上下文", "Read a web page; inside a sentence, context for the AI")
        case .tasks: return tr("后台 Claude 任务的进度和回复", "Background Claude tasks: progress and replies")
        case .settings: return tr("打开设置", "Open the settings")
        default: return ""
        }
    }

    /// A custom command without a summary of its own, by what it does.
    static func customKind(_ custom: CustomCommand) -> String {
        switch custom.type {
        case .prompt: return tr("自定义 AI 指令", "Your own AI instruction")
        case .run: return tr("运行 ", "Run ") + (custom.argv?.first.map { ($0 as NSString).lastPathComponent } ?? "")
        case .terminal: return tr("在终端运行 ", "Run in Terminal: ") + (custom.argv?.first.map { ($0 as NSString).lastPathComponent } ?? "")
        case .link: return tr("在浏览器打开 ", "Open in the browser: ") + (LinkTemplate.host(custom.url) ?? "")
        }
    }

    /// What the action key does with a command draft, after "⏎ →".
    static func action(_ command: Command, input: Language, config: Config) -> String {
        if command.plugin != nil, command.kind == .run { return tr("运行插件", "run the plugin") }
        if command.kind == .link { return tr("在浏览器打开", "open in the browser") }
        switch command.custom?.type {
        case .prompt?: return tr("AI 生成", "generate")
        case .run?: return tr("运行", "run")
        case .terminal?: return tr("在终端运行", "run in Terminal")
        case .link?, nil: break
        }
        switch command {
        case .improve: return action(input: input, config: config)
        case .question: return tr("提问", "ask")
        case .claude: return config.claudeInBackground ? tr("交给 Claude 在后台做", "hand it to Claude in the background")
                                                       : tr("在终端打开 Claude Code", "open Claude Code in Terminal")
        case .open: return tr("搜索并打开", "search and open")
        case .read: return tr("读网页", "read the page")
        case .tasks: return tr("查看后台任务", "show the background tasks")
        case .settings: return tr("打开设置", "open the settings")
        default: return ""
        }
    }

    /// The row comment of an answer: "回答" / "answer", "Claude".
    static func answerLabel(_ command: Command?) -> String {
        if command?.kind == .run { return command?.plugin.map { "@" + $0.name } ?? tr("输出", "output") }
        return command == .claude ? "Claude" : tr("回答", "answer")
    }

    /// An error as the settings window shows it.
    static func describe(_ error: Error) -> String {
        if let error = error as? WebReader.ReadError {
            switch error {
            case let .invalidURL(text): return tr("不是网址：\(text)", "Not a web address: \(text)")
            case let .http(status): return tr("网页返回 HTTP \(status)", "The page answered HTTP \(status)")
            case let .unsupported(type): return tr("读不了这种内容（\(type)）", "Can't read this kind of content (\(type))")
            case .empty: return tr("网页上没有找到文字（要靠 JavaScript 显示的网页读不了）",
                                   "No text found on the page (pages that need JavaScript can't be read)")
            case .tooLarge: return tr("网页太大（超过 2 MB）", "The page is larger than 2 MB")
            }
        }
        if let error = error as? CommandPipelineError, case let .inner(name, underlying) = error, name == "read" {
            return "@read" + tr("：", ": ") + underlying
        }
        if let error = error as? CommandRunner.RunError {
            switch error {
            case let .notFound(program): return tr("找不到程序 \(program)", "Program not found: \(program)")
            case let .failed(status, message):
                return message.isEmpty ? tr("程序出错（退出码 \(status)）", "The program failed (exit status \(status))") : message
            case let .timedOut(seconds):
                let n = Int(seconds.rounded())
                return tr("运行超过 \(n) 秒，已停止", "Stopped after \(n) seconds")
            case .tooMuchOutput: return tr("输出太多，已停止", "Stopped: too much output")
            }
        }
        if let error = error as? ProviderError {
            switch error {
            case let .missingKey(p): return tr("\(name(p)) 还没有 API key：在设置里添上", "No API key for the \(name(p)): add one in the settings")
            case let .missingModel(p): return tr("\(name(p)) 还没有设置模型", "No model set for the \(name(p))")
            case let .invalidBaseURL(url): return tr("Base URL 无效：\(url)", "Invalid base URL: \(url)")
            case let .http(p, status, type, message): return "\(name(p)) \(type ?? "HTTP \(status)")" + tr("：", ": ") + message
            case let .stream(p, type, message): return "\(name(p)) \(type)" + tr("：", ": ") + message
            case let .refused(p): return tr("\(name(p)) 拒绝了这个请求", "The \(name(p)) declined this request")
            case let .invalidResponse(p, detail):
                return tr("\(name(p)) 的响应无法解析：\(detail)", "Couldn't read the \(name(p)) response: \(detail)")
            case .signedOut: return tr("请先在设置里登录 AllInOneIME 云", "Sign in to AllInOneIME Cloud in the settings")
            case .quotaExhausted:
                return tr("今天的免费次数用完了：可以在设置里订阅，或者填自己的 API key",
                          "No requests left today: subscribe, or add your own API key in the settings")
            }
        }
        guard !chinese else { return AllInOneIMEInputController.describe(error) }
        switch error {
        case let error as URLError:
            switch error.code {
            case .timedOut: return "The request timed out"
            case .notConnectedToInternet, .networkConnectionLost: return "No network connection"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Can't reach the AI service"
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
