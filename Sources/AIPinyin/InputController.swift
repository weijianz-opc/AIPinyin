import AIPinyinCore
import AIPinyinRime
import AppKit
import Carbon
import InputMethodKit
import os

let log = Logger(subsystem: "com.aipinyin.inputmethod.AIPinyin", category: "ime")

/// One converter (one URLSession, one cache) shared by every input session in the process.
let sharedConverter = Converter()

/// Carries a main-thread-only object out of `MainActor.assumeIsolated` (we never leave the main thread).
struct MainThreadBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Settings stored in the input method's user defaults.
enum Settings {
    static var aiEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "aiEnabled") }
    }
}

/// IMK creates one controller per client text session. All IMK callbacks arrive on the main
/// thread, so entry points hop into main-actor code with `MainActor.assumeIsolated`.
@objc(AIPinyinInputController)
final class AIPinyinInputController: IMKInputController {
    let composer = Composer(aiEnabled: Settings.aiEnabled)
    private var session: RimeSession?
    private var conversionTask: Task<Void, Never>?
    private var lastElapsed: TimeInterval?
    private var lastFromCache = false
    private var notice: String?
    /// Whether this text session has delivered a key yet (logged once, without the key).
    private var receivedKeys = false
    /// Shown once each time composing gets paused for secure input.
    private var secureNoticeShown = false
    var converter: Converter = sharedConverter
    /// Persists the AI on/off switch (the self-test replaces this so it leaves the setting alone).
    var saveAIMode: (Bool) -> Void = { Settings.aiEnabled = $0 }
    /// Whether secure event input is on anywhere; no text is sent to the model then.
    /// (The self-test replaces this to exercise both states.)
    var secureInputActive: () -> Bool = { SecureInput.isOn }
    /// Only set by the self-test: IMK refuses to create a controller for anything but its own
    /// client proxies, so the test injects its fake text field here.
    var clientOverride: IMKTextInput?

    static let notFound = NSRange(location: NSNotFound, length: NSNotFound)

    // MARK: - IMK entry points

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        let client = sender as? IMKTextInput
        switch event.type {
        case .keyDown:
            return MainActor.assumeIsolated { handleKeyDown(event, client: client) }
        case .flagsChanged:
            MainActor.assumeIsolated { handleFlagsChanged(event, client: client) }
            return false  // the application must see modifier changes too
        default:
            return false
        }
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        MainActor.assumeIsolated {
            composer.aiEnabled = Settings.aiEnabled
            ensureEngine()
        }
    }

    override func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated { perform(composer.commitAll(), client: sender as? IMKTextInput) }
    }

    override func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated { perform(composer.commitAll(), client: sender as? IMKTextInput) }
        super.deactivateServer(sender)
    }

    override func composedString(_ sender: Any!) -> Any! {
        composer.markedText
    }

    override func inputControllerWillClose() {
        MainActor.assumeIsolated {
            conversionTask?.cancel()
            conversionTask = nil
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(noticeExpired), object: nil)
            hidePanelIfOwned()
            composer.engine = nil
            session = nil
        }
        super.inputControllerWillClose()
    }

    override func menu() -> NSMenu! {
        log.notice("input menu requested")
        return MainActor.assumeIsolated { MainThreadBox(makeMenu()) }.value
    }

    // MARK: - Level one engine

    /// Creates the Rime session once librime has finished deploying (and again after a re-deploy).
    @MainActor
    func ensureEngine() {
        if let session, session.isValid { return }
        guard let fresh = RimeService.shared.makeSession() else {
            composer.engine = nil
            session = nil
            return
        }
        session = fresh
        composer.engine = fresh
    }

    // MARK: - Keys

    @MainActor
    func handleKeyDown(_ event: NSEvent, client: IMKTextInput?) -> Bool {
        if !receivedKeys {
            receivedKeys = true
            log.notice("receiving keys (engine ready: \(RimeService.shared.isReady))")
        }
        // Password fields and prompts turn on secure event input. Never compose (so nothing can be
        // sent to the model) in the app that turned it on; anything already typed goes in as typed.
        let target: IMKTextInput? = client ?? clientOverride ?? self.client()
        if SecureInput.blocksComposing(target) {
            if composer.isComposing { perform(composer.commitAsTyped(), client: client) }
            if !secureNoticeShown, let chars = event.characters, !chars.isEmpty,
               event.modifierFlags.isDisjoint(with: [.command, .control]) {
                secureNoticeShown = true
                perform([.notice("安全输入中：暂停拼音，直接输入")], client: client)
            }
            return false
        }
        secureNoticeShown = false
        ensureEngine()
        let response = composer.handleKeyDown(KeyEvent(
            keyCode: event.keyCode, characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            modifiers: Self.modifiers(event.modifierFlags)))
        perform(response.effects, client: client)
        return response.handled
    }

    @MainActor
    func handleFlagsChanged(_ event: NSEvent, client: IMKTextInput?) {
        guard !SecureInput.blocksComposing(client ?? clientOverride ?? self.client()) else { return }
        ensureEngine()
        perform(composer.handleFlagsChanged(keyCode: event.keyCode, modifiers: Self.modifiers(event.modifierFlags),
                                            timestamp: event.timestamp),
                client: client)
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.capsLock) { result.insert(.capsLock) }
        return result
    }

    // MARK: - Effects

    @MainActor
    func perform(_ effects: [Composer.Effect], client: IMKTextInput?) {
        let target: IMKTextInput? = client ?? clientOverride ?? self.client()
        for effect in effects {
            switch effect {
            case .updateMarkedText:
                updateMarkedText(target)
            case let .commit(text):
                target?.insertText(text, replacementRange: Self.notFound)
            case let .startConversion(input, id):
                if secureInputActive() {
                    // A password field or prompt may be active somewhere: never send text off the Mac.
                    log.info("conversion \(id) not sent: secure input \(SecureInput.ownerDescription(), privacy: .public)")
                    perform(composer.fail("系统安全输入已开启（密码框或锁屏），未发送给 AI", id: id), client: target)
                } else {
                    startConversion(input, id: id)
                }
            case .cancelConversion:
                conversionTask?.cancel()
                conversionTask = nil
            case .showPanel:
                showPanel(target)
            case .hidePanel:
                hidePanelIfOwned()
            case let .notice(text):
                showNotice(text, client: target)
            case let .aiModeChanged(on):
                saveAIMode(on)
            }
        }
    }

    @MainActor
    private func updateMarkedText(_ client: IMKTextInput?) {
        guard let client else { return }
        let text = composer.markedText
        guard !text.isEmpty else {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: Self.notFound)
            return
        }
        let length = (text as NSString).length
        let style = composer.isLevelTwo ? kTSMHiliteSelectedConvertedText : kTSMHiliteRawText
        let attributed = NSAttributedString(
            string: text, attributes: markAttributes(style: style, range: NSRange(location: 0, length: length)))
        let cursor = String(text.prefix(composer.markedCursor)).utf16.count
        client.setMarkedText(
            attributed, selectionRange: NSRange(location: cursor, length: 0), replacementRange: Self.notFound)
    }

    private func markAttributes(style: Int, range: NSRange) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        for (key, value) in mark(forStyle: style, at: range) ?? [:] {
            if let name = key as? String {
                attributes[NSAttributedString.Key(name)] = value
            } else if let name = key as? NSAttributedString.Key {
                attributes[name] = value
            }
        }
        if attributes.isEmpty {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    // MARK: - Level two

    @MainActor
    private func startConversion(_ input: String, id: Int) {
        conversionTask?.cancel()
        lastElapsed = nil
        lastFromCache = false
        log.notice("conversion \(id) started (\(input.count) chars)")
        let stream = converter.convert(input)
        conversionTask = Task { @MainActor [weak self] in
            do {
                for try await update in stream {
                    guard let self, !Task.isCancelled else { return }
                    if update.isFinal {
                        self.lastElapsed = update.elapsed
                        self.lastFromCache = update.fromCache
                        log.notice("conversion \(id) done in \(update.elapsed, format: .fixed(precision: 2))s cache=\(update.fromCache)")
                    }
                    self.perform(self.composer.receive(update.result, isFinal: update.isFinal, id: id), client: nil)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                log.error("conversion \(id) failed: \(Self.errorKind(error), privacy: .public) \(String(describing: error), privacy: .private)")
                self.perform(self.composer.fail(Self.describe(error), id: id), client: nil)
            }
        }
    }

    /// Error category without any server-provided text (safe for the public log).
    static func errorKind(_ error: Error) -> String {
        switch error {
        case let BedrockError.http(status, type, _): return "http \(status) \(type ?? "-")"
        case let BedrockError.stream(type, _): return "stream \(type)"
        case BedrockError.invalidResponse: return "invalid response"
        case BedrockError.invalidRegion: return "invalid region"
        case let urlError as URLError: return "url \(urlError.code.rawValue)"
        default: return String(describing: type(of: error))
        }
    }

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "请求超时"
            case .notConnectedToInternet, .networkConnectionLost: return "网络连接失败"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "无法连接 Bedrock"
            default: return urlError.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: - Candidate panel

    @MainActor
    private func anchor(_ client: IMKTextInput) -> NSRect {
        var lineRect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineRect)
        return lineRect
    }

    @MainActor
    private func showPanel(_ client: IMKTextInput?) {
        guard let client, composer.wantsPanel else {
            hidePanelIfOwned()
            return
        }
        let panel = CandidatePanel.shared
        panel.owner = self
        panel.onSelect = { [weak self] index in
            guard let self else { return }
            self.perform(self.composer.choose(index: index), client: nil)
        }
        panel.show(panelModel(), anchor: anchor(client))
    }

    @MainActor
    private func hidePanelIfOwned() {
        let panel = CandidatePanel.shared
        if panel.owner == nil || panel.owner === self {
            panel.hide()
        }
    }

    /// Short status message ("英", "AI 翻译：关" …): its own small panel when nothing else is shown,
    /// otherwise the right side of the footer.
    @MainActor
    private func showNotice(_ text: String, client: IMKTextInput?) {
        notice = text
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(noticeExpired), object: nil)
        perform(#selector(noticeExpired), with: nil, afterDelay: 1.2)
        if composer.wantsPanel {
            showPanel(client)
        } else if let client {
            let panel = CandidatePanel.shared
            panel.owner = self
            panel.onSelect = nil
            var model = CandidateView.Model()
            model.status = .hint(text)
            panel.show(model, anchor: anchor(client))
        }
    }

    @objc private func noticeExpired() {
        MainActor.assumeIsolated {
            notice = nil
            if composer.wantsPanel {
                showPanel(clientOverride ?? client())
            } else {
                hidePanelIfOwned()
            }
        }
    }

    @MainActor
    func panelModel() -> CandidateView.Model {
        var model = CandidateView.Model()
        if composer.isLevelTwo {
            let choices = composer.choices
            model.rows = choices.map { choice in
                switch choice.kind {
                case .original:
                    return CandidateView.Row(label: choice.label, text: choice.text, comment: "原文", style: .original)
                case .english:
                    return CandidateView.Row(label: choice.label, text: choice.text, style: .translation,
                                             isComplete: choice.isComplete)
                case let .rewrite(style):
                    return CandidateView.Row(label: choice.label, text: choice.text, comment: style,
                                             style: .translation, isComplete: choice.isComplete)
                }
            }
            model.highlighted = composer.highlighted
            switch composer.phase {
            case .translating:
                model.status = choices.count <= 1 ? .loading : .none
                model.footer = "生成中… · ⏎ 上屏原文 · Esc 返回"
            case .choosing:
                model.footer = "空格 上屏 · 数字选择 · ⏎ 原文 · Esc 返回"
                model.detail = lastFromCache ? "缓存" : lastElapsed.map { String(format: "%.1fs", $0) }
            case let .failed(message):
                model.status = .error(message)
                model.highlighted = nil  // Space retries; nothing is selected
                model.footer = "空格 重试 · ⏎ 上屏原文 · Esc 返回"
            case .idle, .drafting:
                break
            }
        } else if composer.engineState.isComposing {
            let state = composer.engineState
            model.rows = state.candidates.map {
                CandidateView.Row(label: $0.label, text: $0.text, comment: $0.comment, style: .candidate)
            }
            model.highlighted = state.highlighted
            model.footer = composer.aiEnabled ? "空格 选词 · 整句打完再按空格翻译" : "空格 选词 · AI 翻译已关（⇧空格开启）"
            if state.pageNumber > 0 || !state.isLastPage { model.detail = "第 \(state.pageNumber + 1) 页" }
        } else if !composer.draft.isEmpty {
            let latin = composer.engineState.isAsciiMode && !composer.draft.hasSuffix(" ")
            model.status = .hint(latin ? "连按两次空格 → 英文 / 中文改写" : "空格 → 英文 / 中文改写")
            model.footer = "⏎ 上屏中文 · ⌫ 删字 · Esc 清除"
        }
        if let notice { model.detail = notice }
        return model
    }

    // MARK: - Menu

    @MainActor
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let ai = NSMenuItem(title: "AI 翻译 / 改写（⇧空格）", action: #selector(toggleAI(_:)), keyEquivalent: "")
        ai.target = self
        ai.state = Settings.aiEnabled ? .on : .off
        menu.addItem(ai)
        let config = try? Config.load()
        let model = config.map { "模型：\($0.modelId)" } ?? "配置文件有误"
        let info = NSMenuItem(title: model, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)

        menu.addItem(.separator())
        let header = NSMenuItem(title: "中文改写风格", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let enabled = Set(RewriteStyle.resolve(config?.rewriteStyles ?? Config.default.rewriteStyles).map(\.name))
        for style in RewriteStyle.catalog {
            let item = NSMenuItem(title: "\(style.name)　\(style.summary)", action: #selector(toggleStyle(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = style.name
            item.state = enabled.contains(style.name) ? .on : .off
            item.isEnabled = config != nil  // don't overwrite a config file that failed to parse
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let rimeDir = NSMenuItem(title: "打开 Rime 用户目录", action: #selector(openRimeDirectory(_:)), keyEquivalent: "")
        rimeDir.target = self
        menu.addItem(rimeDir)
        let deploy = NSMenuItem(title: "重新部署词库", action: #selector(redeploy(_:)), keyEquivalent: "")
        deploy.target = self
        menu.addItem(deploy)
        return menu
    }

    @objc func toggleAI(_ sender: Any?) {
        MainActor.assumeIsolated {
            perform(composer.setAI(!composer.aiEnabled), client: nil)
        }
    }

    /// IMK hands menu actions an info dictionary holding the chosen item (a plain NSMenuItem when
    /// called directly).
    static func menuItem(from sender: Any?) -> NSMenuItem? {
        if let item = sender as? NSMenuItem { return item }
        guard let info = sender as? NSDictionary else { return nil }
        return info[kIMKCommandMenuItemName as Any] as? NSMenuItem
    }

    @objc func toggleStyle(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let name = Self.menuItem(from: sender)?.representedObject as? String else {
                log.error("style menu action without a style")
                return
            }
            do {
                var config = try Config.load()
                config.rewriteStyles = Self.toggled(name, in: config.rewriteStyles)
                try config.write()
                log.notice("rewrite styles now \(config.rewriteStyles.joined(separator: ","), privacy: .public)")
            } catch {
                log.error("could not update rewrite styles: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Turns a preset on or off. Turning one off keeps the current order; turning one on sorts the
    /// list into catalog order.
    static func toggled(_ name: String, in current: [String]) -> [String] {
        let enabled = RewriteStyle.resolve(current).map(\.name)
        if enabled.contains(name) { return enabled.filter { $0 != name } }
        let wanted = Set(enabled + [name])
        return RewriteStyle.catalog.map(\.name).filter(wanted.contains)
    }

    @objc func openConfig(_ sender: Any?) {
        MainActor.assumeIsolated { Self.openConfigFile() }
    }

    override func showPreferences(_ sender: Any!) {
        MainActor.assumeIsolated {
            perform(composer.commitAll(), client: nil)  // the window takes focus from the text field
            SettingsWindow.shared.show()
        }
    }

    @objc func openRimeDirectory(_ sender: Any?) {
        MainActor.assumeIsolated {
            if let dir = RimeService.shared.userDataDir { NSWorkspace.shared.open(dir) }
        }
    }

    @objc func redeploy(_ sender: Any?) {
        MainActor.assumeIsolated {
            perform(composer.commitAll(), client: nil)
            composer.engine = nil
            session = nil
            RimeService.shared.redeploy()
        }
    }

    @MainActor
    static func openConfigFile() {
        let url = Config.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try Config.default.write(to: url)
            } catch {
                log.error("could not create config: \(String(describing: error), privacy: .public)")
            }
        }
        if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
