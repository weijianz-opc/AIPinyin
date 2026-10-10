import AllInOneIMECore
import AppKit
import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

/// Models offered in the settings window (any Bedrock model / inference-profile ID can be typed in).
/// Measured on 10 everyday sentences with the default presets (2026-10).
struct SuggestedModel: Identifiable, Hashable {
    let id: String
    let title: String
    let note: String

    /// The models offered for `provider` (any other ID can be typed in).
    static func suggested(for provider: Provider) -> [SuggestedModel] {
        switch provider {
        case .bedrock: return all
        case .anthropic:
            return [
                SuggestedModel(id: "claude-haiku-5-5", title: "Claude Haiku 5.5", note: tr("默认：最快、最便宜", "Default: fastest, cheapest")),
                SuggestedModel(id: "claude-sonnet-5-5", title: "Claude Sonnet 5.5", note: tr("更用心，慢一些", "More careful, slower")),
                SuggestedModel(id: "claude-opus-5-5", title: "Claude Opus 5.5", note: tr("最强，最慢最贵", "Most capable, slowest, priciest")),
            ]
        case .gemini:
            return [SuggestedModel(id: "gemini-3.8-flash", title: "Gemini 3.8 Flash", note: tr("默认", "Default"))]
        case .hosted:
            return []  // the service picks the model
        case .openai:
            // OpenAI's own; for another service (DeepSeek, Qwen, Ollama, …), "Custom…" and its base URL.
            return [
                SuggestedModel(id: "gpt-6-luna", title: "GPT-6 Luna", note: tr("默认：最快、最省", "Default: fastest, cheapest")),
                SuggestedModel(id: "gpt-5.4-mini", title: "GPT-5.4 mini", note: tr("上一代 mini", "The previous mini")),
            ]
        }
    }

    static var all: [SuggestedModel] {
        [
            SuggestedModel(id: "us.anthropic.claude-haiku-4-5-20251001-v1:0", title: "Claude Haiku 4.5",
                           note: tr("推荐：约 1.3 秒，质量好", "Recommended: about 1.3 s, good quality")),
            SuggestedModel(id: "us.anthropic.claude-sonnet-4-6", title: "Claude Sonnet 4.6",
                           note: tr("约 2.2 秒，改写最用心", "About 2.2 s, the most careful rewrites")),
            SuggestedModel(id: "us.amazon.nova-2-lite-v1:0", title: "Amazon Nova 2 Lite",
                           note: tr("约 1 秒，最便宜，润色偏弱", "About 1 s, cheapest, weaker polish")),
        ]
    }
}

/// State of the settings window. Every change is written to the config file right away;
/// the input method re-reads it for each translation, so nothing needs a restart.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: Config
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?
    @Published private(set) var profiles: [String] = []
    @Published private(set) var testStatus: TestStatus = .idle
    /// Where the API key of each provider comes from (refreshed when one is saved).
    @Published private(set) var keySources: [Provider: APIKeys.Source] = [:]
    @Published private(set) var keyError: String?

    enum TestStatus: Equatable {
        case idle
        case running
        case passed(String)
        case failed(String)
    }

    let configURL: URL
    /// False for previews/screenshots: nothing is ever written.
    private let persists: Bool
    private var testTask: Task<Void, Never>?
    /// Screenshots only: the name shown for the selected AWS profile. README images are public and a
    /// profile is often named after its owner; the keys, region and Test Connection (测试连接) still use the real one.
    var profileShownAs: String?

    init(configURL: URL = Config.defaultURL, persists: Bool = true) {
        self.configURL = configURL
        self.persists = persists
        do {
            config = try Config.load(from: configURL)
        } catch {
            // Keep the broken file untouched: the window shows the error instead of overwriting it.
            config = .default
            loadError = UIText.describe(error)
        }
        profiles = AWSSharedConfig.profileNames()
        if !profiles.contains(config.awsProfile) { profiles.insert(config.awsProfile, at: 0) }
    }

    var canSave: Bool { loadError == nil }

    func save() {
        guard canSave, persists else { return }
        do {
            try config.write(to: configURL)
            saveError = nil
        } catch {
            saveError = tr("保存失败：", "Couldn't save: ") + error.localizedDescription
        }
    }

    /// Switches the window's language at once (nil: follow the system) and saves the choice.
    func setUILanguage(_ language: Language?) {
        UIText.choice = language  // before the change is published, so the window redraws in it
        config.uiLanguage = language
        save()
        SettingsWindow.shared.updateTitle()
    }

    /// Shows or hides the floating panel (the self-test passes its own).
    var applyFloatingPanel: @MainActor (Bool) -> Void = { FloatingPanel.shared.apply($0) }

    /// The floating panel's switch: saved, and the panel shown or hidden at once (not by a preview).
    func setFloatingPanel(_ on: Bool) {
        config.floatingPanel = on
        save()
        if persists { applyFloatingPanel(on) }
    }

    // MARK: Styles

    func isStyleOn(_ style: RewriteStyle) -> Bool {
        RewriteStyle.resolve(config.rewriteStyles).contains(style)
    }

    func setStyle(_ style: RewriteStyle, on: Bool) {
        guard on != isStyleOn(style) else { return }
        config.rewriteStyles = AllInOneIMEInputController.toggled(style.name, in: config.rewriteStyles)
        save()
    }

    // MARK: Provider

    func refreshKeys() {
        let providers = Provider.allCases.filter { $0 != .bedrock }
        Task.detached {
            // The first look asks the user's shell for its variables (ANTHROPIC_API_KEY, …): not on the main thread.
            let sources = Dictionary(uniqueKeysWithValues: providers.map { ($0, APIKeys.source($0)) })
            await MainActor.run { [weak self] in self?.keySources = sources }
        }
    }

    /// Stores (or with an empty key removes) the provider's API key in the keychain.
    func saveKey(_ key: String, for provider: Provider) {
        guard persists else { return }
        do {
            try APIKeys.save(key, for: provider)
            keyError = nil
        } catch {
            keyError = tr("无法保存到钥匙串：", "Couldn't save to the keychain: ") + UIText.describe(error)
        }
        refreshKeys()
    }

    func keyStatus(_ provider: Provider) -> String {
        switch keySources[provider] {
        case .keychain?: return tr("已保存在钥匙串里", "Saved in the keychain")
        case let .environment(name)?: return tr("使用 shell 里的 \(name)", "Using \(name) from your shell")
        case .none?: return tr("还没有 API key", "No API key yet")
        case nil: return ""
        }
    }

    /// The settings of an API-key provider as stored (unset fields use the defaults).
    func providerSettings(_ provider: Provider) -> ProviderSettings {
        switch provider {
        case .anthropic: return config.anthropic
        case .gemini: return config.gemini
        case .openai: return config.openai
        case .bedrock, .hosted: return ProviderSettings()
        }
    }

    func setProviderSettings(_ settings: ProviderSettings, for provider: Provider) {
        switch provider {
        case .anthropic: config.anthropic = settings
        case .gemini: config.gemini = settings
        case .openai: config.openai = settings
        case .bedrock, .hosted: return
        }
        save()
    }

    // MARK: AllInOneIME Cloud (the hosted provider)

    @Published private(set) var account: HostedAccount?
    @Published private(set) var accountBusy = false
    @Published private(set) var accountError: String?
    private var authSession: ASWebAuthenticationSession?
    private let presenter = AuthPresenter()

    func refreshAccount() {
        guard HostedService.isConfigured else { return }
        Task { [weak self] in
            do {
                let account = try await HostedAccount.current()
                self?.account = account
                self?.accountError = nil
            } catch {
                self?.accountError = UIText.describe(error)
            }
        }
    }

    /// Signing in (or up) on the user pool's page in the system's authentication sheet, then the service's session.
    func signIn(_ method: HostedSignIn.Method) {
        let signIn = HostedSignIn()
        accountBusy = true
        accountError = nil
        let session = ASWebAuthenticationSession(url: signIn.authorizationURL(method),
                                                 callbackURLScheme: HostedService.callbackScheme) { [weak self] url, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.accountBusy = false }
                if let error {
                    // Closing the sheet is not an error worth showing.
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        self.accountError = error.localizedDescription
                    }
                    return
                }
                guard let url, let code = signIn.code(from: url) else {
                    self.accountError = tr("没有拿到登录结果", "The sign-in didn't come back")
                    return
                }
                do {
                    let idToken = try await signIn.idToken(for: code)
                    self.account = try await HostedAccount.signIn(idToken: idToken)
                    self.config.provider = .hosted
                    self.save()
                } catch {
                    self.accountError = UIText.describe(error)
                }
            }
        }
        session.presentationContextProvider = presenter
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() {
            accountBusy = false
            accountError = tr("无法打开登录页面", "Couldn't open the sign-in page")
        }
    }

    func signOut() {
        try? HostedAccount.signOut()
        account = nil
    }

    func subscribe() {
        guard let account, let sub = account.sub, let url = HostedService.checkoutURL(sub: sub, email: account.email) else { return }
        NSWorkspace.shared.open(url)
    }

    func manageSubscription() {
        guard let url = URL(string: HostedService.portalLink), !HostedService.portalLink.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Plugins

    @Published private(set) var plugins: [InstalledPlugin] = []
    @Published private(set) var skippedPlugins: [PluginStore.Skipped] = []
    @Published private(set) var pluginError: String?

    func refreshPlugins() {
        (plugins, skippedPlugins) = PluginStore.load()
    }

    func uninstall(_ plugin: InstalledPlugin) {
        guard persists else { return }
        do {
            try PluginStore.uninstall(plugin)
            pluginError = nil
        } catch {
            pluginError = tr("无法删除插件：", "Couldn't remove the plugin: ") + error.localizedDescription
        }
        refreshPlugins()
    }

    /// Opens the plugins folder (made first), where a plugin folder can be put by hand.
    func openPluginsFolder() {
        try? FileManager.default.createDirectory(at: PluginStore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(PluginStore.directory)
    }

    // MARK: Account

    /// Region shown when the field is empty: the profile's own region.
    var profileRegion: String {
        (try? AWSSharedConfig.load(profile: config.awsProfile).region) ?? "us-east-1"
    }

    static var credentialsFound: String { tr("已找到这个 profile 的密钥", "Found the keys for this profile") }

    var credentialStatus: String {
        do {
            _ = try AWSSharedConfig.load(profile: config.awsProfile)
            return Self.credentialsFound
        } catch {
            return UIText.describe(error)
        }
    }

    // MARK: Voice

    @Published private(set) var installedModels: [Language: Bool] = [:]
    @Published private(set) var modelProgress: [Language: Double] = [:]
    @Published private(set) var microphone = VoiceInput.microphoneAccess
    @Published private(set) var voiceError: String?

    func refreshVoice() {
        microphone = VoiceInput.microphoneAccess
        // A download started by the input method (first dictation) shows its progress here too.
        for language in VoiceInput.downloads.keys where modelProgress[language] == nil { downloadModel(language) }
        Task { [weak self] in
            for language in [Language.chinese, .english] {
                let installed = await VoiceInput.isModelInstalled(language)
                self?.installedModels[language] = installed
            }
        }
    }

    func downloadModel(_ language: Language) {
        voiceError = nil
        modelProgress[language] = 0
        VoiceInput.startDownload(language, progress: { [weak self] in self?.modelProgress[language] = $0 }) { [weak self] error in
            self?.modelProgress[language] = nil
            if let error { self?.voiceError = tr("下载失败：", "Download failed: ") + UIText.describe(error) }
            self?.refreshVoice()
        }
    }

    /// Asks for microphone access (system prompt), or opens the privacy settings once it was denied.
    func microphoneAction() {
        switch microphone {
        case .notDetermined:
            Task { [weak self] in
                _ = await VoiceInput.requestMicrophoneAccess()
                self?.microphone = VoiceInput.microphoneAccess
            }
        case .denied:
            NSWorkspace.shared.open(VoiceInput.microphoneSettingsURL)
        case .granted:
            break
        }
    }

    // MARK: Jargon list (the user's own; nothing is built in)

    @Published private(set) var jargonCount = 0
    @Published private(set) var jargonExists = false

    var jargonPath: String { (config.jargonURL.path as NSString).abbreviatingWithTildeInPath }

    func refreshJargon() {
        let url = config.jargonURL
        jargonExists = FileManager.default.fileExists(atPath: url.path)
        jargonCount = jargonExists ? JargonLibrary.load(from: url).count : 0
    }

    /// Uses a text file the user already has (e.g. the team's list) where it is.
    func chooseJargonFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .tabSeparatedText] + [UTType(filenameExtension: "md")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = config.jargonURL.deletingLastPathComponent()
        panel.message = tr("选择你的黑话库：文本文件，每行一个词，可以加解释",
                           "Choose your jargon list: a text file, one term per line, optionally with its meaning")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.jargonFile = (url.path as NSString).abbreviatingWithTildeInPath
        save()
        refreshJargon()
    }

    /// Opens the list in the text editor, first creating it (comments only) if it doesn't exist.
    func openJargonFile() {
        let url = config.jargonURL
        if !FileManager.default.fileExists(atPath: url.path) {
            guard persists else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(JargonLibrary.template.utf8).write(to: url, options: .withoutOverwriting)
            } catch {
                saveError = tr("无法创建黑话库：", "Couldn't create the jargon list: ") + error.localizedDescription
                return
            }
        }
        NSWorkspace.shared.open(url)
        refreshJargon()
    }

    // MARK: Test

    func runTest() {
        testTask?.cancel()
        testStatus = .running
        let snapshot = config
        testTask = Task { [weak self] in
            let converter = Converter(loadConfig: { snapshot })
            let sample = "我今天有点不舒服"
            do {
                var final = ConversionResult.empty
                var elapsed: TimeInterval = 0
                for try await update in converter.convert(sample) where update.isFinal {
                    final = update.result
                    elapsed = update.elapsed
                }
                guard let first = final.versions.first?.text else {
                    throw BedrockError.invalidResponse(tr("没有返回结果", "no result"))
                }
                // Like the candidate panel: a rewrite that only changes punctuation or repeats a row isn't shown.
                let shown = Set(([sample] + final.versions.map(\.text)).map(\.wordingKey))
                let rewrite = final.rewrites.first { !shown.contains($0.line.text.wordingKey) }
                    .map { "\n" + (RewriteStyle.named($0.style).map(UIText.name) ?? $0.style) + tr("：", ": ") + $0.line.text } ?? ""
                self?.testStatus = .passed(String(format: tr("%.1f 秒：%@%@", "%.1f s: %@%@"), elapsed, first, rewrite))
            } catch {
                self?.testStatus = .failed(UIText.describe(error))
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var customModel = false
    @State private var customProviderModel = false
    @State private var pluginToRemove: InstalledPlugin?
    /// The custom command being added or edited (the editor sheet), and the one about to be deleted.
    @State private var commandEdit: CommandEdit?
    @State private var commandToDelete: Int?
    /// The API key being typed (a saved key is never shown again: it stays in the keychain).
    @State private var newKey = ""

    var body: some View {
        Form {
            if let loadError = model.loadError {
                Section {
                    Label(tr("配置文件有误，未做修改：", "The config file has an error and was left as is: ") + loadError,
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button(tr("打开配置文件", "Open Config File")) { NSWorkspace.shared.open(model.configURL) }
                }
            }

            Section {
                // 中文 and English are written in their own language, so they can be found either way.
                Picker(tr("界面语言", "Language"), selection: Binding(get: { model.config.uiLanguage },
                                                                    set: { model.setUILanguage($0) })) {
                    Text(tr("跟随系统", "System")).tag(Language?.none)
                    Text("中文").tag(Language?.some(.chinese))
                    Text("English").tag(Language?.some(.english))
                }
                .pickerStyle(.segmented)
            }

            Section {
                Text(commandsSummary).font(.caption).foregroundStyle(.secondary)
                Picker(tr("执行键", "Action key"), selection: $model.config.actionKey) {
                    ForEach([ActionKey.enter, .optionTap, .optionSpace, .space], id: \.self) { key in
                        Text(UIText.pickerName(key)).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.canSave)
                Text(Self.actionKeyNote(model.config.actionKey))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(tr("@claude 在后台运行，做完通知我", "@claude runs in the background and notifies me"),
                       isOn: $model.config.claudeInBackground)
                Text(tr("开着：交给 Claude Code 后台去做，做完弹通知，点通知或用 @tasks 查看；关掉：在终端打开 Claude Code 接着聊。",
                        "On: Claude Code works in the background and you get a notification when it's done (click it, or @tasks); off: Claude Code opens in Terminal to talk."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(tr("悬浮面板：笔记、提醒、Claude 任务", "Floating panel: notes, reminders, Claude tasks"),
                       isOn: Binding(get: { model.config.floatingPanel }, set: { model.setFloatingPanel($0) }))
                    .disabled(!model.canSave)
                    .onReceive(NotificationCenter.default.publisher(for: .allInOneIMEFloatingPanelChanged)) { note in
                        // Turned on or off from the input menu or the panel's close button (already saved).
                        if note.object as AnyObject? === FloatingPanel.shared, let on = note.userInfo?["enabled"] as? Bool {
                            model.config.floatingPanel = on
                        }
                    }
                Text(tr("常驻屏幕的小窗口，不抢输入焦点，点一行就打开；输入法菜单里也能开关。",
                        "Stays on screen without taking focus; click a row to open it. Also in the input menu."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(tr("输入和输出", "Input and Output")) {
                Picker(tr("默认输入", "Default input"), selection: $model.config.defaultInput) {
                    Text(tr("中文（拼音）", "Chinese (pinyin)")).tag(Language.chinese)
                    Text(UIText.name(Language.english)).tag(Language.english)
                }
                .pickerStyle(.segmented)
                Picker(tr("输出（1–3 行）", "Output (lines 1–3)"), selection: $model.config.outputLanguage) {
                    Text(UIText.name(Language.english)).tag(Language.english)
                    Text(UIText.name(Language.chinese)).tag(Language.chinese)
                }
                .pickerStyle(.segmented)
                Text(inputSummary).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.canSave)

            Section(tr("改写风格", "Rewrite Styles")) {
                ForEach(RewriteStyle.catalog, id: \.name) { style in
                    Toggle(isOn: Binding(get: { model.isStyleOn(style) },
                                         set: { model.setStyle(style, on: $0) })) {
                        HStack {
                            Text(UIText.name(style))
                            Text(UIText.summary(style)).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!model.canSave)
                Text(model.config.rewriteStyles.isEmpty
                     ? tr("都不勾选时只出 1–3 行。", "With none checked, you get lines 1–3 only.")
                     : tr("改写用原文的语言：打中文出中文改写，打英文出英文改写。",
                          "Rewrites are in the language you typed: Chinese for Chinese, English for English."))
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent(tr("黑话库", "Jargon list")) {
                    HStack(spacing: 8) {
                        Text(model.jargonExists ? tr("\(model.jargonCount) 个词", "\(model.jargonCount) terms") : tr("未设置", "Not set"))
                            .foregroundStyle(.secondary)
                        Button(tr("选择文件…", "Choose File…")) { model.chooseJargonFile() }
                        Button(model.jargonExists ? tr("打开", "Open") : tr("新建", "New")) { model.openJargonFile() }
                    }
                }
                .disabled(!model.canSave)
                Text(tr("用你自己的词表：文本文件，每行一个词，可以加解释（如 bandwidth：精力、时间）。勾上「黑话」后模型优先用这些词，候选里会注明意思。",
                        "Your own term list: a text file, one term per line, optionally with its meaning (e.g. bandwidth: time and energy). With Jargon checked, the model prefers these terms and the candidates explain them.")
                     + (model.jargonExists ? tr("\n文件：", "\nFile: ") + model.jargonPath : ""))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Section(tr("自定义 @ 命令", "Custom @ Commands")) {
                ForEach(Array(model.config.customCommands.enumerated()), id: \.offset) { index, command in
                    HStack {
                        Text("@" + command.name).font(.body.monospaced())
                        Text(UIText.customKind(command)).foregroundStyle(.secondary)
                        if let summary = command.summary {
                            Text(summary).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(tr("编辑", "Edit")) { commandEdit = CommandEdit(index: index, command: command) }
                        Button(tr("删除", "Delete")) { commandToDelete = index }
                    }
                }
                Button(tr("添加命令…", "Add Command…")) {
                    commandEdit = CommandEdit(index: nil, command: CustomCommand(name: "", type: .prompt))
                }
                Text(tr("保存后，在任意输入框开头打 @ 加名字就能用，和 @improve 一样。",
                        "Once saved, type @ and its name at the start of any text field, like @improve."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.canSave)

            Section(tr("插件", "Plugins")) {
                ForEach(model.plugins, id: \.name) { plugin in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("@" + plugin.name).font(.body.monospaced())
                            Text(plugin.manifest.summary?.text(chinese: UIText.chinese) ?? "").foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button(tr("删除", "Remove")) { pluginToRemove = plugin }
                        }
                        Text(pluginDetail(plugin)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(model.skippedPlugins, id: \.folder) { skipped in
                    Label(tr("没有加载 \(skipped.folder)：", "Not loaded, \(skipped.folder): ") + skipped.reason,
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.plugins.isEmpty, model.skippedPlugins.isEmpty {
                    Text(tr("还没有插件。插件是别人写好的 @ 命令，比如 @stock 查股价；装好后和其他命令一样用。",
                            "No plugins yet. Plugins are ready-made @ commands, like @stock for stock quotes; once installed they work like any command."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(tr("打开插件文件夹", "Open Plugins Folder")) { model.openPluginsFolder() }
                    Button(tr("刷新", "Refresh")) { model.refreshPlugins() }
                }
                if let error = model.pluginError { Text(error).foregroundStyle(.red) }
            }
            .disabled(!model.canSave)

            Section(tr("语音输入", "Voice Input")) {
                Toggle(tr("按住右 ⌥ 说话，松开结束", "Hold right ⌥ to talk, release to stop"), isOn: $model.config.voiceInput)
                    .disabled(!model.canSave)
                if VoiceInput.isSupported {
                    ForEach([Language.chinese, .english], id: \.self) { language in
                        LabeledContent(tr("\(language.displayName)语音模型", "\(UIText.name(language)) speech model")) {
                            modelStatus(language)
                        }
                    }
                    LabeledContent(tr("麦克风", "Microphone")) {
                        switch model.microphone {
                        case .granted: Text(tr("已允许", "Allowed")).foregroundStyle(.secondary)
                        case .notDetermined: Button(tr("允许使用麦克风", "Allow Microphone")) { model.microphoneAction() }
                        case .denied: Button(tr("已拒绝，去系统设置打开", "Denied: Open System Settings")) { model.microphoneAction() }
                        }
                    }
                    if let error = model.voiceError { Text(error).foregroundStyle(.red) }
                    Text(tr("中文模式说中文，英文模式说英文。语音在这台 Mac 上识别，不上传；识别出的文字直接上屏，在 @ 命令里就接在命令后面。",
                            "Speak Chinese in Chinese mode and English in English mode. Speech is recognized on this Mac and never uploaded; the text is typed in, or after the @ command you are writing."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(tr("需要 macOS 26 或更新版本。", "Needs macOS 26 or later.")).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(tr("AI 服务", "AI Provider")) {
                Picker(tr("服务", "Provider"), selection: $model.config.provider) {
                    ForEach(Provider.offered, id: \.self) { provider in
                        Text(UIText.name(provider)).tag(provider)
                    }
                }
                if model.config.provider == .bedrock {
                    bedrockSettings
                } else if model.config.provider == .hosted {
                    hostedSettings
                } else {
                    apiKeySettings(model.config.provider)
                }
                HStack {
                    Button(tr("测试连接", "Test Connection")) { model.runTest() }
                        .disabled(model.testStatus == .running)
                    switch model.testStatus {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case let .passed(text): Text("✓ \(text)").foregroundStyle(.green).textSelection(.enabled)
                    case let .failed(text): Text("✗ \(text)").foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .disabled(!model.canSave)

            Section(tr("高级", "Advanced")) {
                Stepper(value: $model.config.maxTokens, in: 200...4000, step: 100) {
                    Text(tr("最多输出 \(model.config.maxTokens) tokens", "Up to \(model.config.maxTokens) output tokens"))
                }
                Toggle(tr("Bedrock：发送 temperature（有的模型不支持，报错时关掉）",
                          "Bedrock: send temperature (some models don't support it; turn it off if requests fail)"),
                       isOn: temperatureOn)
                if let t = model.config.temperature {
                    Slider(value: Binding(get: { t }, set: { model.config.temperature = ($0 * 10).rounded() / 10 }),
                           in: 0...1) { Text("temperature \(String(format: "%.1f", t))") }
                }
                Stepper(value: $model.config.timeoutSeconds, in: 5...60, step: 5) {
                    Text(tr("超时 \(Int(model.config.timeoutSeconds)) 秒", "Timeout \(Int(model.config.timeoutSeconds)) s"))
                }
            }
            .disabled(!model.canSave)

            Section {
                HStack {
                    Button(tr("打开配置文件", "Open Config File")) { NSWorkspace.shared.open(model.configURL) }
                    Button(tr("打开 Rime 用户目录", "Open Rime User Folder")) {
                        NSWorkspace.shared.open(RimeDirectories.user)
                    }
                }
                let path = (model.configURL.path as NSString).abbreviatingWithTildeInPath
                Text(tr("所有设置都存在 \(path)，改完立即生效。", "All settings are stored in \(path) and apply right away."))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let saveError = model.saveError {
                    Text(saveError).foregroundStyle(.red)
                }
            } footer: {
                // At the very end, out of the way; selectable for bug reports, the same in both languages.
                if let version = Self.version {
                    Text("AllInOneIME \(version)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 760)
        // Text fields save on Return; everything else (pickers, steppers, toggles) saves on change.
        .sheet(item: $commandEdit) { edit in
            CommandEditor(edit: edit, others: model.config.customCommands.enumerated()
                            .filter { $0.offset != edit.index }.map(\.element),
                          plugins: model.plugins.map(\.name)) { command in
                if let index = edit.index {
                    model.config.customCommands[index] = command
                } else {
                    model.config.customCommands.append(command)
                }
                model.save()
            }
        }
        .confirmationDialog(tr("删除这个命令？", "Delete this command?"),
                            isPresented: Binding(get: { commandToDelete != nil }, set: { if !$0 { commandToDelete = nil } })) {
            Button(tr("删除", "Delete"), role: .destructive) {
                if let index = commandToDelete, model.config.customCommands.indices.contains(index) {
                    model.config.customCommands.remove(at: index)
                    model.save()
                }
                commandToDelete = nil
            }
        } message: {
            if let index = commandToDelete, model.config.customCommands.indices.contains(index) {
                Text("@" + model.config.customCommands[index].name)
            }
        }
        .confirmationDialog(tr("删除这个插件？", "Remove this plugin?"),
                            isPresented: Binding(get: { pluginToRemove != nil }, set: { if !$0 { pluginToRemove = nil } })) {
            Button(tr("删除", "Remove"), role: .destructive) {
                if let plugin = pluginToRemove { model.uninstall(plugin) }
                pluginToRemove = nil
            }
        } message: {
            if let plugin = pluginToRemove { Text("@" + plugin.name) }
        }
        .onChange(of: model.config.awsProfile) { model.save() }
        .onChange(of: model.config.provider) {
            customProviderModel = false
            newKey = ""
            model.save()
        }
        .onChange(of: model.config.maxTokens) { model.save() }
        .onChange(of: model.config.temperature) { model.save() }
        .onChange(of: model.config.timeoutSeconds) { model.save() }
        .onChange(of: model.config.defaultInput) { model.save() }
        .onChange(of: model.config.outputLanguage) { model.save() }
        .onChange(of: model.config.voiceInput) { model.save() }
        .onChange(of: model.config.actionKey) { model.save() }
        .onChange(of: model.config.claudeInBackground) { model.save() }
        .onAppear {
            model.refreshPlugins()
            model.refreshKeys()
            model.refreshAccount()
            model.refreshVoice()
            model.refreshJargon()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshJargon()  // the list may have been edited in the text editor
        }
        .onDisappear { model.save() }
    }

    /// The input method's version (Info.plist), shown at the bottom of the window.
    static var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The commands, at the top: what this input method does beyond pinyin.
    private var commandsSummary: String {
        let key = UIText.howToPress(model.config.actionKey)
        return tr("平时就是普通拼音输入法。开头打 @ 用命令：@improve 润色 / 翻译，@question 提问，@claude 开 Claude Code，"
                      + "@open 找文件，@note 存到备忘录，@reminder 加提醒事项。写完\(key)执行。",
                  "A regular pinyin input method. Type @ first for commands: @improve polishes / translates, @question asks, "
                      + "@claude opens Claude Code, @open finds files, @note saves to Notes, @reminder adds a reminder. "
                      + "When done, \(key).")
    }

    /// What @improve does for Chinese and for English input.
    private var inputSummary: String {
        let chinese = UIText.action(input: .chinese, config: model.config)
        let english = UIText.action(input: .english, config: model.config)
        return tr("@improve：打中文 → \(chinese)；打英文 → \(english)。单按 Shift 切换中英文。",
                  "@improve: Chinese → \(chinese); English → \(english). Tap Shift to switch between Chinese and English.")
    }

    /// How the chosen action key works, and what Space does with it.
    static func actionKeyNote(_ key: ActionKey) -> String {
        switch key {
        case .enter:
            return tr("@ 命令写完按 ⏎ 执行，拼音没选完也能直接按。没有 @ 时 ⏎ 就是普通回车。",
                      "Return runs an @ command, also on pinyin not yet picked. Without @, Return is a normal Return.")
        case .optionTap:
            return tr("按一下 ⌥ 马上松开，左右都行；按住右 ⌥ 仍然是说话。@ 命令按 ⏎ 也执行。",
                      "Press either ⌥ and let go right away; holding right ⌥ still dictates. @ commands also run on Return.")
        case .optionSpace:
            return tr("拼音没选完也可以直接按 ⌥空格。⌥空格被 Alfred、Raycast 等占用时，改用「单按 ⌥」。@ 命令按 ⏎ 也执行。",
                      "⌥Space also works before the pinyin is picked. If Alfred, Raycast or another app uses ⌥Space, "
                          + "choose Tap ⌥. @ commands also run on Return.")
        case .space:
            return tr("空格先选词，没有要选的了再按一次空格执行；英文模式下连按两次空格。@ 命令按 ⏎ 也执行。",
                      "Space picks words; once nothing is left to pick, Space again runs it. In English mode, press Space twice. "
                          + "@ commands also run on Return.")
        }
    }

    @ViewBuilder
    private func modelStatus(_ language: Language) -> some View {
        if let progress = model.modelProgress[language] {
            HStack {
                ProgressView(value: progress).frame(width: 120)
                Text(String(format: "%.0f%%", progress * 100)).foregroundStyle(.secondary).monospacedDigit()
            }
        } else {
            switch model.installedModels[language] {
            case true?: Text(tr("已安装", "Installed")).foregroundStyle(.secondary)
            case false?: Button(tr("下载（只需一次）", "Download (once)")) { model.downloadModel(language) }
            case nil: ProgressView().controlSize(.small)
            }
        }
    }

    /// Amazon Bedrock: the model, the AWS profile with its keys, and the region.
    @ViewBuilder
    private var bedrockSettings: some View {
        Picker(tr("模型", "Model"), selection: modelSelection) {
            ForEach(SuggestedModel.all) { m in
                Text(m.title + tr("　", "  ") + m.note).tag(m.id)
            }
            Text(tr("自定义…", "Custom…")).tag("custom")
        }
        if customModel || !SuggestedModel.all.contains(where: { $0.id == model.config.modelId }) {
            TextField(tr("模型 ID", "Model ID"), text: $model.config.modelId,
                      prompt: Text(tr("例如 ", "e.g. ") + "us.anthropic.claude-haiku-4-5-20251001-v1:0"))
                .onSubmit { model.save() }
        }
        Picker("AWS Profile", selection: $model.config.awsProfile) {
            ForEach(model.profiles, id: \.self) { name in
                Text(name == model.config.awsProfile ? model.profileShownAs ?? name : name).tag(name)
            }
        }
        TextField(tr("区域", "Region"), text: regionBinding,
                  prompt: Text(tr("留空用 profile 的区域（\(model.profileRegion)）",
                                  "Empty: the profile's region (\(model.profileRegion))")))
            .onSubmit { model.save() }
        Text(model.credentialStatus).font(.caption).foregroundStyle(.secondary)
    }

    /// AllInOneIME Cloud: the Google account, today's free requests, the subscription.
    @ViewBuilder
    private var hostedSettings: some View {
        if let account = model.account {
            LabeledContent(tr("账号", "Account")) {
                HStack {
                    Text(account.email ?? "").textSelection(.enabled)
                    Button(tr("退出", "Sign Out")) { model.signOut() }
                }
            }
            LabeledContent(tr("今天免费", "Free today")) {
                Text("\(account.freeRemaining) / \(account.freeLimit)").monospacedDigit()
            }
            LabeledContent(tr("订阅剩余", "Subscription")) {
                Text(account.isSubscribed || account.credits > 0 ? "\(account.credits)" : tr("未订阅", "None")).monospacedDigit()
            }
            HStack {
                // Until Stripe is set up (no payment link), there is nothing to subscribe to.
                if account.isSubscribed, !HostedService.portalLink.isEmpty {
                    Button(tr("管理订阅", "Manage Subscription")) { model.manageSubscription() }
                } else if !account.isSubscribed, !HostedService.paymentLink.isEmpty {
                    Button(tr("订阅：$3/月 3000 次", "Subscribe: $3/month for 3000")) { model.subscribe() }
                }
                Button(tr("刷新", "Refresh")) { model.refreshAccount() }
            }
            Text(tr("先用每天的免费次数，用完再用订阅的次数。付款在浏览器里完成，完成后点「刷新」。",
                    "The day's free requests are used first, then the subscription's. Payment happens in the browser; click Refresh afterwards."))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            HStack {
                if HostedService.googleEnabled {
                    Button(tr("用 Google 登录", "Sign in with Google")) { model.signIn(.google) }.disabled(model.accountBusy)
                }
                Button(tr("用邮箱登录 / 注册", "Sign in / Sign up with Email")) { model.signIn(.email) }.disabled(model.accountBusy)
                if model.accountBusy { ProgressView().controlSize(.small) }
            }
            Text(tr("登录后每天免费 20 次，不用自己的 AWS 或 API key。",
                    "Signed in, you get 20 free requests a day, without an AWS account or API key of your own."))
                .font(.caption).foregroundStyle(.secondary)
        }
        if let error = model.accountError { Text(error).foregroundStyle(.red) }
    }

    /// An API-key provider: the model, the key (kept in the keychain), the base URL and the effort.
    @ViewBuilder
    private func apiKeySettings(_ provider: Provider) -> some View {
        let settings = model.config.settings(for: provider)
        let suggested = SuggestedModel.suggested(for: provider)
        if !suggested.isEmpty {
            Picker(tr("模型", "Model"), selection: providerModelSelection(provider)) {
                ForEach(suggested) { m in
                    Text(m.title + tr("　", "  ") + m.note).tag(m.id)
                }
                Text(tr("自定义…", "Custom…")).tag("custom")
            }
        }
        if suggested.isEmpty || customProviderModel || !suggested.contains(where: { $0.id == settings.model }) {
            TextField(tr("模型 ID", "Model ID"), text: providerBinding(provider, \.model),
                      prompt: Text(tr("例如 ", "e.g. ") + Self.modelExample(provider)))
                .onSubmit { model.save() }
        }
        HStack {
            SecureField("API key", text: $newKey, prompt: Text(tr("粘贴新的 API key", "Paste a new API key")))
                .onSubmit { saveKey(provider) }
            Button(tr("保存", "Save")) { saveKey(provider) }.disabled(newKey.isEmpty)
            if model.keySources[provider] == .keychain {
                Button(tr("删除", "Remove")) { model.saveKey("", for: provider) }
            }
        }
        Text(model.keyStatus(provider)).font(.caption).foregroundStyle(.secondary)
        if let error = model.keyError { Text(error).foregroundStyle(.red) }
        TextField(tr("Base URL", "Base URL"), text: providerBinding(provider, \.baseURL),
                  prompt: Text(ProviderSettings.defaults(for: provider).baseURL ?? ""))
            .onSubmit { model.save() }
        if provider == .openai {
            Menu(tr("常用服务…", "Common Services…")) {
                ForEach(CompatibleService.all) { service in
                    Button(service.name) { useService(service) }
                }
            }
            .fixedSize()
            Text(tr("选一个服务会填好它的 Base URL，再在「自定义…」里填它的模型。也可以填任何其他兼容 OpenAI 的地址。",
                    "Picking a service fills in its base URL; then enter its model under Custom…. Any other OpenAI-compatible address works too."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Picker(tr("思考", "Thinking"), selection: providerBinding(provider, \.effort, empty: "")) {
            Text(tr("少（low，最快）", "Little (low, fastest)")).tag("low")
            Text("medium").tag("medium")
            Text("high").tag("high")
            Text(tr("不设置（模型不支持时选）", "Not set (for models without it)")).tag("")
        }
    }

    /// A common OpenAI-compatible service: its base URL, and its model to type in (the model of
    /// another service wouldn't exist there).
    private func useService(_ service: CompatibleService) {
        var settings = model.providerSettings(.openai)
        settings.baseURL = service.baseURL
        settings.model = service.model
        model.setProviderSettings(settings, for: .openai)
        customProviderModel = true
    }

    private func saveKey(_ provider: Provider) {
        model.saveKey(newKey, for: provider)
        newKey = ""
    }

    static func modelExample(_ provider: Provider) -> String {
        switch provider {
        case .anthropic: return "claude-sonnet-5-5"
        case .gemini: return "gemini-3.8-flash"
        case .openai: return "deepseek-chat"
        case .hosted: return ""
        case .bedrock: return "us.anthropic.claude-haiku-4-5-20251001-v1:0"
        }
    }

    /// A text field for one string setting of a provider; an empty one falls back to the default.
    private func providerBinding(_ provider: Provider, _ key: WritableKeyPath<ProviderSettings, String?>,
                                 empty: String? = nil) -> Binding<String> {
        Binding(
            get: { model.providerSettings(provider)[keyPath: key] ?? model.config.settings(for: provider)[keyPath: key] ?? "" },
            set: { value in
                var settings = model.providerSettings(provider)
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                settings[keyPath: key] = trimmed.isEmpty ? empty : trimmed
                model.setProviderSettings(settings, for: provider)
            })
    }

    private func providerModelSelection(_ provider: Provider) -> Binding<String> {
        let suggested = SuggestedModel.suggested(for: provider)
        return Binding(
            get: {
                let current = model.config.settings(for: provider).model ?? ""
                return customProviderModel || !suggested.contains(where: { $0.id == current }) ? "custom" : current
            },
            set: { choice in
                customProviderModel = choice == "custom"
                guard choice != "custom" else { return }
                var settings = model.providerSettings(provider)
                settings.model = choice
                model.setProviderSettings(settings, for: provider)
            })
    }

    /// "1.0.0 · sends what you type after @stock to query1.finance.yahoo.com · local".
    private func pluginDetail(_ plugin: InstalledPlugin) -> String {
        var parts = [plugin.manifest.version]
        switch plugin.manifest.type {
        case .script:
            let hosts = plugin.manifest.hosts.joined(separator: ", ")
            parts.append(hosts.isEmpty ? tr("不联网", "no network")
                         : tr("@\(plugin.name) 后面的内容会发到 \(hosts)", "sends the text after @\(plugin.name) to \(hosts)"))
        case .prompt:
            parts.append(tr("AI 指令，发给你选的 AI 服务", "an AI instruction, sent to your AI provider"))
        }
        if plugin.isLocal { parts.append(tr("本地插件（未经审核）", "local (not reviewed)")) }
        return parts.joined(separator: " · ")
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                customModel || !SuggestedModel.all.contains(where: { $0.id == model.config.modelId })
                    ? "custom" : model.config.modelId
            },
            set: { choice in
                if choice == "custom" {
                    customModel = true
                } else {
                    customModel = false
                    model.config.modelId = choice
                    model.save()
                }
            })
    }

    private var regionBinding: Binding<String> {
        Binding(get: { model.config.region ?? "" },
                set: { model.config.region = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }

    private var temperatureOn: Binding<Bool> {
        Binding(get: { model.config.temperature != nil },
                set: { model.config.temperature = $0 ? (model.config.temperature ?? 0.3) : nil })
    }
}

/// The single settings window of the input method process.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    static var title: String { tr("AllInOneIME 设置", "AllInOneIME Settings") }

    /// After the window's language changed.
    func updateTitle() { window?.title = Self.title }

    func show() {
        if window?.isVisible != true {
            // (Re)build so the window reflects the config file as it is now.
            window?.close()
            let model = SettingsModel()
            UIText.choice = model.config.uiLanguage
            let host = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: host)
            window.title = Self.title
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            // The whole form is about 1620 pt tall (English, with a connection test result); on smaller
            // screens it scrolls.
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
            window.setContentSize(NSSize(width: 560, height: min(1630, visible - 60)))
            window.center()
            self.window = window
        }
        // The input method is an agent app: activate it so the window can take keyboard focus. If macOS
        // doesn't grant activation (another app is active), still put the window in front; a click
        // into it then activates it.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

/// Where the Google sign-in sheet is shown: the settings window.
final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}

/// OpenAI-compatible services offered under "Common Services…": their base URLs (a model to start
/// with only where its ID is long-standing; otherwise the model is typed in).
struct CompatibleService: Identifiable {
    let name: String
    let baseURL: String
    let model: String?
    var id: String { baseURL }

    static var all: [CompatibleService] {
        [
            CompatibleService(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-6-luna"),
            CompatibleService(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
            CompatibleService(name: tr("通义千问（阿里云百炼）", "Qwen (Alibaba Cloud Model Studio)"),
                              baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: nil),
            CompatibleService(name: tr("通义千问（海外）", "Qwen (international)"),
                              baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", model: nil),
            CompatibleService(name: tr("Kimi（月之暗面）", "Kimi (Moonshot)"), baseURL: "https://api.moonshot.cn/v1", model: nil),
            CompatibleService(name: tr("智谱 GLM", "Zhipu GLM"), baseURL: "https://open.bigmodel.cn/api/paas/v4", model: nil),
            CompatibleService(name: tr("硅基流动", "SiliconFlow"), baseURL: "https://api.siliconflow.cn/v1", model: nil),
            CompatibleService(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: nil),
            CompatibleService(name: tr("本机 Ollama", "Ollama on this Mac"), baseURL: "http://localhost:11434/v1", model: nil),
        ]
    }
}
