import AIPinyinCore
import AppKit
import SwiftUI

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
                guard let english = final.english.first?.text else { throw BedrockError.invalidResponse("没有返回英文") }
                // Like the candidate panel: a rewrite that only changes punctuation isn't shown.
                let rewrite = final.rewrites.first { $0.line.text.wordingKey != sample.wordingKey }
                    .map { "\n\($0.style)：\($0.line.text)" } ?? ""
                self?.testStatus = .passed(String(format: "%.1f 秒：%@%@", elapsed, english, rewrite))
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
                Text("整句打完按空格：1–3 是英文，后面是下方勾选的中文改写。关闭后就是普通拼音输入法。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("中文改写风格") {
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
                if model.config.rewriteStyles.isEmpty {
                    Text("都不勾选时只出英文。").font(.caption).foregroundStyle(.secondary)
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
        .onDisappear { model.save() }
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
            // The whole form is about 930 pt tall; on smaller screens it scrolls.
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
            window.setContentSize(NSSize(width: 560, height: min(940, visible - 60)))
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
