import AIPinyinCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Models offered in the settings window (any Bedrock model / inference-profile ID can be typed in).
/// Measured on 10 everyday sentences with the default presets (2026-10).
struct SuggestedModel: Identifiable, Hashable {
    let id: String
    let title: String
    let note: String

    static let all: [SuggestedModel] = [
        SuggestedModel(id: "us.anthropic.claude-haiku-4-5-20251001-v1:0", title: "Claude Haiku 4.5",
                       note: "推荐：约 1.3 秒，质量好"),
        SuggestedModel(id: "us.anthropic.claude-sonnet-4-6", title: "Claude Sonnet 4.6",
                       note: "约 2.2 秒，改写最用心"),
        SuggestedModel(id: "us.amazon.nova-2-lite-v1:0", title: "Amazon Nova 2 Lite",
                       note: "约 1 秒，最便宜，润色偏弱"),
    ]
}

/// State of the settings window. Every change is written to the config file right away;
/// the input method re-reads it for each translation, so nothing needs a restart.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: Config
    @Published var aiEnabled: Bool
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?
    @Published private(set) var profiles: [String] = []
    @Published private(set) var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle
        case running
        case passed(String)
        case failed(String)
    }

    let configURL: URL
    private let saveAI: (Bool) -> Void
    /// False for previews/screenshots: nothing is ever written.
    private let persists: Bool
    private var testTask: Task<Void, Never>?

    init(configURL: URL = Config.defaultURL,
         aiEnabled: Bool = Settings.aiEnabled,
         saveAI: @escaping (Bool) -> Void = { Settings.aiEnabled = $0 },
         persists: Bool = true) {
        self.configURL = configURL
        self.saveAI = saveAI
        self.persists = persists
        self.aiEnabled = aiEnabled
        do {
            config = try Config.load(from: configURL)
        } catch {
            // Keep the broken file untouched: the window shows the error instead of overwriting it.
            config = .default
            loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
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
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }

    func setAI(_ on: Bool) {
        aiEnabled = on
        saveAI(on)
    }

    // MARK: Styles

    func isStyleOn(_ style: RewriteStyle) -> Bool {
        RewriteStyle.resolve(config.rewriteStyles).contains(style)
    }

    func setStyle(_ style: RewriteStyle, on: Bool) {
        guard on != isStyleOn(style) else { return }
        config.rewriteStyles = AIPinyinInputController.toggled(style.name, in: config.rewriteStyles)
        save()
    }

    // MARK: Account

    /// Region shown when the field is empty: the profile's own region.
    var profileRegion: String {
        (try? AWSSharedConfig.load(profile: config.awsProfile).region) ?? "us-east-1"
    }

    var credentialStatus: String {
        do {
            _ = try AWSSharedConfig.load(profile: config.awsProfile)
            return "已找到这个 profile 的密钥"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
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
            if let error { self?.voiceError = "下载失败：\(AIPinyinInputController.describe(error))" }
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
        panel.message = "选择你的黑话库：文本文件，每行一个词，可以加解释"
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
                saveError = "无法创建黑话库：\(error.localizedDescription)"
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
                guard let first = final.versions.first?.text else { throw BedrockError.invalidResponse("没有返回结果") }
                // Like the candidate panel: a rewrite that only changes punctuation or repeats a row isn't shown.
                let shown = Set(([sample] + final.versions.map(\.text)).map(\.wordingKey))
                let rewrite = final.rewrites.first { !shown.contains($0.line.text.wordingKey) }
                    .map { "\n\($0.style)：\($0.line.text)" } ?? ""
                self?.testStatus = .passed(String(format: "%.1f 秒：%@%@", elapsed, first, rewrite))
            } catch {
                self?.testStatus = .failed(AIPinyinInputController.describe(error))
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var customModel = false

    var body: some View {
        Form {
            if let loadError = model.loadError {
                Section {
                    Label("配置文件有误，未做修改：\(loadError)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("打开配置文件") { NSWorkspace.shared.open(model.configURL) }
                }
            }

            Section {
                Toggle("开启 AI 翻译和改写（⇧空格）", isOn: Binding(get: { model.aiEnabled }, set: { model.setAI($0) }))
                Text("整句打完按空格：1–3 是\(model.config.outputLanguage.displayName)，后面是下方勾选的改写。关闭后就是普通拼音输入法。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("输入和输出") {
                Picker("默认输入", selection: $model.config.defaultInput) {
                    Text("中文（拼音）").tag(Language.chinese)
                    Text("英文").tag(Language.english)
                }
                .pickerStyle(.segmented)
                Picker("输出（1–3 行）", selection: $model.config.outputLanguage) {
                    Text("英文").tag(Language.english)
                    Text("中文").tag(Language.chinese)
                }
                .pickerStyle(.segmented)
                Toggle("英文模式也用 AI（打完连按两次空格）", isOn: $model.config.englishAI)
                Text(inputSummary).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.canSave)

            Section("改写风格") {
                ForEach(RewriteStyle.catalog, id: \.name) { style in
                    Toggle(isOn: Binding(get: { model.isStyleOn(style) },
                                         set: { model.setStyle(style, on: $0) })) {
                        HStack {
                            Text(style.name)
                            Text(style.summary).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!model.canSave)
                Text(model.config.rewriteStyles.isEmpty
                     ? "都不勾选时只出 1–3 行。"
                     : "改写用原文的语言：打中文出中文改写，打英文出英文改写。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("黑话库") {
                    HStack(spacing: 8) {
                        Text(model.jargonExists ? "\(model.jargonCount) 个词" : "未设置").foregroundStyle(.secondary)
                        Button("选择文件…") { model.chooseJargonFile() }
                        Button(model.jargonExists ? "打开" : "新建") { model.openJargonFile() }
                    }
                }
                .disabled(!model.canSave)
                Text("用你自己的词表：文本文件，每行一个词，可以加解释（如 bandwidth：精力、时间）。勾上「黑话」后模型优先用这些词，候选里会注明意思。"
                     + (model.jargonExists ? "\n文件：\(model.jargonPath)" : ""))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Section("语音输入") {
                Toggle("按住右 ⌥ 说话，松开结束", isOn: $model.config.voiceInput)
                    .disabled(!model.canSave)
                if VoiceInput.isSupported {
                    ForEach([Language.chinese, .english], id: \.self) { language in
                        LabeledContent("\(language.displayName)语音模型") { modelStatus(language) }
                    }
                    LabeledContent("麦克风") {
                        switch model.microphone {
                        case .granted: Text("已允许").foregroundStyle(.secondary)
                        case .notDetermined: Button("允许使用麦克风") { model.microphoneAction() }
                        case .denied: Button("已拒绝，去系统设置打开") { model.microphoneAction() }
                        }
                    }
                    if let error = model.voiceError { Text(error).foregroundStyle(.red) }
                    Text("中文模式说中文，英文模式说英文。语音在这台 Mac 上识别，不上传；识别出的文字和打字一样进草稿。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("需要 macOS 26 或更新版本。").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("模型（Amazon Bedrock）") {
                Picker("模型", selection: modelSelection) {
                    ForEach(SuggestedModel.all) { m in
                        Text("\(m.title)　\(m.note)").tag(m.id)
                    }
                    Text("自定义…").tag("custom")
                }
                if customModel || !SuggestedModel.all.contains(where: { $0.id == model.config.modelId }) {
                    TextField("模型 ID", text: $model.config.modelId, prompt: Text("例如 us.anthropic.claude-haiku-4-5-20251001-v1:0"))
                        .onSubmit { model.save() }
                }
                Picker("AWS Profile", selection: $model.config.awsProfile) {
                    ForEach(model.profiles, id: \.self) { Text($0).tag($0) }
                }
                TextField("区域", text: regionBinding, prompt: Text("留空用 profile 的区域（\(model.profileRegion)）"))
                    .onSubmit { model.save() }
                Text(model.credentialStatus).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("测试连接") { model.runTest() }
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

            Section("高级") {
                Stepper(value: $model.config.maxTokens, in: 200...4000, step: 100) {
                    Text("最多输出 \(model.config.maxTokens) tokens")
                }
                Toggle("发送 temperature（有的模型不支持，报错时关掉）", isOn: temperatureOn)
                if let t = model.config.temperature {
                    Slider(value: Binding(get: { t }, set: { model.config.temperature = ($0 * 10).rounded() / 10 }),
                           in: 0...1) { Text("temperature \(String(format: "%.1f", t))") }
                }
                Stepper(value: $model.config.timeoutSeconds, in: 5...60, step: 5) {
                    Text("超时 \(Int(model.config.timeoutSeconds)) 秒")
                }
            }
            .disabled(!model.canSave)

            Section {
                HStack {
                    Button("打开配置文件") { NSWorkspace.shared.open(model.configURL) }
                    Button("打开 Rime 用户目录") {
                        NSWorkspace.shared.open(RimeDirectories.user)
                    }
                }
                Text("所有设置都存在 \((model.configURL.path as NSString).abbreviatingWithTildeInPath)，改完立即生效。")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let saveError = model.saveError {
                    Text(saveError).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 760)
        // Text fields save on Return; everything else (pickers, steppers, toggles) saves on change.
        .onChange(of: model.config.awsProfile) { model.save() }
        .onChange(of: model.config.maxTokens) { model.save() }
        .onChange(of: model.config.temperature) { model.save() }
        .onChange(of: model.config.timeoutSeconds) { model.save() }
        .onChange(of: model.config.defaultInput) { model.save() }
        .onChange(of: model.config.outputLanguage) { model.save() }
        .onChange(of: model.config.englishAI) { model.save() }
        .onChange(of: model.config.voiceInput) { model.save() }
        .onAppear {
            model.refreshVoice()
            model.refreshJargon()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshJargon()  // the list may have been edited in the text editor
        }
        .onDisappear { model.save() }
    }

    /// What Space does for Chinese and for English input with the current settings.
    private var inputSummary: String {
        let chinese = AIPinyinInputController.actionText(input: .chinese, config: model.config)
        let english = AIPinyinInputController.actionText(input: .english, config: model.config)
        let englishPart = model.config.englishAI
            ? "打英文连按两次空格：\(english)"
            : "英文模式下字母直接上屏"
        return "打中文按空格：\(chinese)；\(englishPart)。单按 Shift 切换中英文。"
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
            case true?: Text("已安装").foregroundStyle(.secondary)
            case false?: Button("下载（只需一次）") { model.downloadModel(language) }
            case nil: ProgressView().controlSize(.small)
            }
        }
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

    func show() {
        if window?.isVisible != true {
            // (Re)build so the window reflects the config file as it is now.
            window?.close()
            let model = SettingsModel()
            let host = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: host)
            window.title = "AI 拼音 设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            // The whole form is about 1350 pt tall; on smaller screens it scrolls.
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
            window.setContentSize(NSSize(width: 560, height: min(1360, visible - 60)))
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
