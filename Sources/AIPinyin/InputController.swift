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

/// The config file as of now, re-read only when it changed (checked by modification date).
/// A file that doesn't parse reads as the defaults here; conversions report the error.
enum LiveConfig {
    private static var cached: (date: Date?, config: Config)?

    static var current: Config {
        let url = Config.defaultURL
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cached, cached.date == date { return cached.config }
        let config = (try? Config.load(from: url)) ?? .default
        cached = (date, config)
        return config
    }
}

/// The user's jargon list (for explaining the terms a 黑话 line uses), re-read when the file changes.
enum LiveJargon {
    private static var cached: (url: URL, date: Date?, entries: [JargonEntry])?

    static func entries(for config: Config) -> [JargonEntry] {
        let url = config.jargonURL
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cached, cached.url == url, cached.date == date { return cached.entries }
        let entries = date == nil ? [] : JargonLibrary.load(from: url)
        cached = (url, date, entries)
        return entries
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
    /// The settings the controller follows (the self-test supplies its own).
    var loadSettings: () -> Config = { LiveConfig.current }
    /// The default input mode last applied to this session (re-applied when the setting changes).
    private var appliedDefaultInput: Language?
    /// The recording in progress (a `DictationSession`, which needs macOS 26).
    private var voiceSession: AnyObject?
    /// Identifies the latest press of the voice key (older hold timers are ignored).
    private var voiceArmToken = 0
    /// Self-test only: recognize this audio file instead of the microphone.
    var voiceFile: (url: URL, speed: Double)?
    /// False in the self-test: the microphone (and its permission prompt) is never touched.
    static var microphoneAllowed = true

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
            ensureEngine()
            applySettings()
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
            cancelVoiceSession()
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
        appliedDefaultInput = nil  // a new session starts in the default input mode
        applySettings()
    }

    /// Takes over the current settings: AI switch, English drafts, voice key, translate key, and the
    /// default input mode (applied to new sessions, and again when the setting changes; a Shift toggle
    /// otherwise sticks).
    @MainActor
    func applySettings() {
        let config = loadSettings()
        composer.aiEnabled = Settings.aiEnabled
        composer.englishAI = config.englishAI
        composer.voiceEnabled = config.voiceInput && VoiceInput.isSupported
        composer.translateKey = config.translateKey
        // The interface language (config `uiLanguage`, else the system's) for the panel, notices and menu.
        UIText.choice = config.uiLanguage
        composer.messages = UIText.chinese ? .chinese : .english
        if appliedDefaultInput != config.defaultInput, composer.engine != nil, !composer.isComposing {
            composer.setInputMode(config.defaultInput)
            appliedDefaultInput = config.defaultInput
        }
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
                perform([.notice(tr("安全输入中：暂停拼音，直接输入", "Secure input: pinyin paused, keys go straight in"))],
                        client: client)
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
        guard !SecureInput.blocksComposing(client ?? clientOverride ?? self.client()) else {
            // A password field took over: stop any recording (its release may never arrive here).
            if composer.voice != .off { perform(composer.commitAsTyped(), client: client) }
            return
        }
        ensureEngine()
        perform(composer.handleFlagsChanged(keyCode: event.keyCode, modifiers: Self.flagsChangedModifiers(event.modifierFlags),
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

    /// Device-dependent bits of NSEvent.modifierFlags (NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK).
    static let leftOptionBit: UInt = 0x20, rightOptionBit: UInt = 0x40

    /// Modifiers of a modifier-change event, including which Option key is down.
    static func flagsChangedModifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result = modifiers(flags)
        if flags.rawValue & leftOptionBit != 0 { result.insert(.leftOption) }
        if flags.rawValue & rightOptionBit != 0 { result.insert(.rightOption) }
        return result
    }

    /// Whether an Option key is still down with no mouse button pressed, as a sanity check when the
    /// hold timer fires (the composer tracks which key from the events). The self-test replaces this.
    var isVoiceKeyHeld: () -> Bool = {
        NSEvent.modifierFlags.contains(.option) && NSEvent.pressedMouseButtons == 0
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
                    perform(composer.fail(tr("系统安全输入已开启（密码框或锁屏），未发送给 AI",
                                             "Secure input is on (a password field or the lock screen): nothing was sent to the AI"),
                                          id: id), client: target)
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
            case let .armVoice(delay):
                voiceArmToken += 1
                let token = voiceArmToken
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, token == self.voiceArmToken else { return }
                    self.perform(self.composer.voiceHoldElapsed(stillHeld: self.isVoiceKeyHeld()), client: nil)
                }
            case let .startVoice(id, language):
                startVoice(id: id, language: language)
            case let .stopVoice(id):
                stopVoice(id: id)
            case let .cancelVoice(id):
                cancelVoiceSession(id: id)
            }
        }
    }

    // MARK: - Voice

    @MainActor
    private func startVoice(id: Int, language: Language) {
        guard #available(macOS 26.0, *), VoiceInput.isSupported else {
            perform(composer.voiceFailed(UIText.describe(VoiceError.unsupportedSystem), id: id), client: nil)
            return
        }
        if voiceFile == nil {
            guard Self.microphoneAllowed else {
                perform(composer.voiceFailed(tr("（自检）没有音频文件，不使用麦克风", "(self-test) no audio file; the microphone stays off"),
                                             id: id), client: nil)
                return
            }
            switch VoiceInput.microphoneAccess {
            case .granted:
                break
            case .notDetermined:
                perform(composer.voiceFailed(tr("请在弹窗里允许使用麦克风，然后再按住右 ⌥ 说话",
                                                "Allow the microphone in the dialog, then hold right ⌥ again"), id: id),
                        client: nil)
                Task { _ = await VoiceInput.requestMicrophoneAccess() }
                return
            case .denied:
                perform(composer.voiceFailed(tr("没有麦克风权限：系统设置 → 隐私与安全性 → 麦克风 → 打开 AIPinyin",
                                                "No microphone access: System Settings → Privacy & Security → Microphone → turn on AIPinyin"),
                                             id: id),
                        client: nil)
                return
            }
        }
        if let progress = VoiceInput.downloads[language] {
            perform(composer.voiceFailed(String(format: tr("%@语音模型下载中 %.0f%%，好了会提示",
                                                           "Downloading the %@ speech model: %.0f%%. You'll be told when it's ready"),
                                                UIText.name(language), progress * 100), id: id), client: nil)
            return
        }
        cancelVoiceSession()  // never two recordings at once
        let session = DictationSession(
            id: id, language: language,
            onText: { [weak self] text in
                guard let self else { return }
                self.perform(self.composer.voiceText(text, id: id), client: nil)
            },
            onFinish: { [weak self] result in
                self?.voiceDidFinish(result, id: id, language: language)
            })
        voiceSession = session
        log.notice("voice \(id) started (\(language.rawValue, privacy: .public))")
        session.start(source: voiceFile.map { .file($0.url, speed: $0.speed) } ?? .microphone)
    }

    @MainActor
    private func stopVoice(id: Int) {
        guard #available(macOS 26.0, *), let session = voiceSession as? DictationSession, session.id == id else { return }
        session.stop()
        scheduleVoiceFallback(id: id, heard: composer.voice.text, waited: 0)
    }

    /// If recognition never finishes, keep what was heard so far. While text is still coming in
    /// (e.g. the model was loading when the key was released) it waits longer, up to 20 s.
    @MainActor
    private func scheduleVoiceFallback(id: Int, heard: String, waited: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.composer.voice.id == id else { return }
            let now = self.composer.voice.text
            if now != heard || now.isEmpty, waited < 15 {
                self.scheduleVoiceFallback(id: id, heard: now, waited: waited + 5)
                return
            }
            log.error("voice \(id): no final transcript after \(waited + 5)s")
            self.cancelVoiceSession(id: id)
            self.perform(self.composer.voiceFinished(now, id: id), client: nil)
        }
    }

    /// Stops the recording `id` (any recording when nil) and discards its result.
    @MainActor
    private func cancelVoiceSession(id: Int? = nil) {
        guard #available(macOS 26.0, *), let session = voiceSession as? DictationSession,
              id == nil || session.id == id else { return }
        session.cancel()
        voiceSession = nil
    }

    @MainActor
    private func voiceDidFinish(_ result: Result<String, Error>, id: Int, language: Language) {
        if #available(macOS 26.0, *), (voiceSession as? DictationSession)?.id == id { voiceSession = nil }
        switch result {
        case let .success(text):
            log.notice("voice \(id) finished (\(text.count) chars)")
            perform(composer.voiceFinished(text, id: id), client: nil)
        case let .failure(VoiceError.modelMissing(missing)):
            let name = UIText.name(missing)
            perform(composer.voiceFailed(tr("首次使用：正在下载\(name)语音模型，好了会提示",
                                            "First use: downloading the \(name) speech model. You'll be told when it's ready"),
                                         id: id), client: nil)
            VoiceInput.startDownload(missing) { [weak self] error in
                self?.showNotice(error.map { tr("语音模型下载失败：", "Speech model download failed: ") + UIText.describe($0) }
                                 ?? tr("\(name)语音模型已就绪：按住右 ⌥ 说话", "\(name) speech model ready: hold right ⌥ to talk"),
                                 client: nil)
            }
        case let .failure(error):
            log.error("voice \(id) failed: \(String(describing: error), privacy: .public)")
            perform(composer.voiceFailed(UIText.describe(error), id: id), client: nil)
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
                self.perform(self.composer.fail(UIText.describe(error), id: id), client: nil)
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
        let client = client ?? clientOverride ?? self.client()
        notice = text
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(noticeExpired), object: nil)
        perform(#selector(noticeExpired), with: nil, afterDelay: min(5, 1.2 + Double(text.count) * 0.06))
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

    /// What the translate key does to a sentence in `input`: "翻译成英文", "英文润色" …, plus " / 改写"
    /// when rewrite styles are on.
    static func actionText(input: Language, config: Config) -> String {
        let output = config.outputLanguage
        let action = input == output ? "\(output.displayName)润色" : "翻译成\(output.displayName)"
        return action + (RewriteStyle.resolve(config.rewriteStyles).isEmpty ? "" : " / 改写")
    }

    /// The hint under a pending draft: "单按 ⌥ → 翻译成英文 / 改写", "Tap ⌥ → translate to English / rewrite" …
    @MainActor
    func draftHint(config: Config) -> String {
        let key = composer.translateKey
        let how = key != .space ? UIText.name(key)
            : composer.spaceTranslates ? UIText.name(TranslateKey.space) : tr("连按两次空格", "Space twice")
        return "\(how) → " + UIText.action(input: Language.of(composer.draft), config: config)
    }

    @MainActor
    func panelModel() -> CandidateView.Model {
        var model = CandidateView.Model()
        let config = loadSettings()
        if composer.isLevelTwo {
            let choices = composer.choices
            model.rows = choices.map { choice in
                switch choice.kind {
                case .original:
                    return CandidateView.Row(label: choice.label, text: choice.text, comment: tr("原文", "original"),
                                             style: .original)
                case .version:
                    return CandidateView.Row(label: choice.label, text: choice.text, style: .translation,
                                             isComplete: choice.isComplete)
                case let .rewrite(style):
                    // A 黑话 line notes what the terms from the user's jargon list in it mean.
                    let note = style == RewriteStyle.jargonName
                        ? JargonLibrary.annotation(for: choice.text, entries: LiveJargon.entries(for: config)) : nil
                    let name = RewriteStyle.named(style).map(UIText.name) ?? style
                    return CandidateView.Row(label: choice.label, text: choice.text,
                                             comment: note.map { "\(name) · \($0)" } ?? name,
                                             style: .translation, isComplete: choice.isComplete)
                }
            }
            model.highlighted = composer.highlighted
            switch composer.phase {
            case .translating:
                let polishing = Language.of(composer.draft) == config.outputLanguage
                model.status = choices.count <= 1
                    ? .loading(polishing ? tr("AI 润色中…", "Polishing…") : tr("AI 翻译中…", "Translating…")) : .none
                model.footer = tr("生成中… · 0 原文 · Esc 返回", "Generating… · 0 original · Esc back")
            case .choosing:
                model.footer = tr("空格 / ⏎ 上屏 · 数字选择 · 0 原文 · Esc 返回",
                                  "Space / ⏎ insert · digits pick · 0 original · Esc back")
                model.detail = lastFromCache ? tr("缓存", "cached") : lastElapsed.map { String(format: "%.1fs", $0) }
            case let .failed(message):
                model.status = .error(message)
                model.highlighted = nil  // Space retries; nothing is selected
                model.footer = tr("空格 重试 · ⏎ 上屏原文 · Esc 返回", "Space retry · ⏎ insert original · Esc back")
            case .idle, .drafting:
                break
            }
        } else if composer.voice != .off {
            let heard = composer.voice.text
            if case .listening = composer.voice {
                model.status = .hint("🎙 " + (heard.isEmpty ? tr("正在听…", "Listening…") : heard))
                // Space while right ⌥ is still held is ⌥Space: stop and send right away.
                model.footer = composer.aiEnabled && composer.translateKey == .optionSpace
                    ? tr("松开右 ⌥ 结束 · 空格 直接出结果 · Esc 取消", "Release right ⌥ to stop · Space for results now · Esc cancel")
                    : tr("松开右 ⌥ 结束 · Esc 取消", "Release right ⌥ to stop · Esc cancel")
            } else {
                model.status = .hint("🎙 " + (heard.isEmpty ? tr("识别中…", "Recognizing…") : heard))
                model.footer = composer.translatesAfterVoice
                    ? tr("识别完就发送 · Esc 取消", "Sends once recognized · Esc cancel")
                    : tr("识别中… · Esc 取消", "Recognizing… · Esc cancel")
            }
            model.detail = composer.engineState.isAsciiMode ? composer.messages.englishMode : composer.messages.chineseMode
        } else if composer.engineState.isComposing {
            let state = composer.engineState
            model.rows = state.candidates.map {
                CandidateView.Row(label: $0.label, text: $0.text, comment: $0.comment, style: .candidate)
            }
            model.highlighted = state.highlighted
            let action = config.outputLanguage == .chinese ? tr("润色", "polish") : tr("翻译", "translate")
            let key = composer.translateKey
            model.footer = !composer.aiEnabled ? tr("空格 选词 · AI 翻译已关（⇧空格开启）", "Space picks · AI is off (⇧Space turns it on)")
                : key == .space ? tr("空格 选词 · 整句打完再按空格\(action)", "Space picks · Space again when done to \(action)")
                : tr("空格 选词 · \(UIText.name(key)) \(action)", "Space picks · \(UIText.name(key)) to \(action)")  // converts what is still being typed, too
            if state.pageNumber > 0 || !state.isLastPage {
                model.detail = tr("第 \(state.pageNumber + 1) 页", "page \(state.pageNumber + 1)")
            }
        } else if !composer.draft.isEmpty {
            model.status = .hint(draftHint(config: config))
            model.footer = composer.isLatinDraft ? tr("⏎ 直接上屏 · ⌫ 删字", "⏎ insert as typed · ⌫ delete")
                : tr("⏎ 上屏原文 · ⌫ 删字 · Esc 清除", "⏎ insert as typed · ⌫ delete · Esc clear")
        }
        if let notice { model.detail = notice }
        return model
    }

    // MARK: - Menu

    @MainActor
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let config = try? Config.load()
        UIText.choice = loadSettings().uiLanguage  // the menu can open before any text field in this process
        let settings = NSMenuItem(title: tr("设置…", "Settings…"), action: #selector(showPreferences(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let ai = NSMenuItem(title: tr("AI 翻译 / 改写（⇧空格）", "AI Translation / Rewrites (⇧Space)"),
                            action: #selector(toggleAI(_:)), keyEquivalent: "")
        ai.target = self
        ai.state = Settings.aiEnabled ? .on : .off
        menu.addItem(ai)
        let model = config.map { tr("模型：", "Model: ") + $0.modelId } ?? tr("配置文件有误", "The config file has an error")
        let info = NSMenuItem(title: model, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)

        menu.addItem(.separator())
        let outputHeader = NSMenuItem(title: tr("输出（1–3 行）", "Output (lines 1–3)"), action: nil, keyEquivalent: "")
        outputHeader.isEnabled = false
        menu.addItem(outputHeader)
        for language in [Language.english, .chinese] {
            let item = NSMenuItem(title: tr("翻译 / 润色成\(language.displayName)", "Translate / Polish into \(UIText.name(language))"),
                                  action: #selector(setOutputLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = (config?.outputLanguage ?? Config.default.outputLanguage) == language ? .on : .off
            item.isEnabled = config != nil  // don't overwrite a config file that failed to parse
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let header = NSMenuItem(title: tr("改写风格", "Rewrite Styles"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let enabled = Set(RewriteStyle.resolve(config?.rewriteStyles ?? Config.default.rewriteStyles).map(\.name))
        for style in RewriteStyle.catalog {
            let item = NSMenuItem(title: UIText.name(style) + tr("　", "  ") + UIText.summary(style),
                                  action: #selector(toggleStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.name
            item.state = enabled.contains(style.name) ? .on : .off
            item.isEnabled = config != nil  // don't overwrite a config file that failed to parse
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let rimeDir = NSMenuItem(title: tr("打开 Rime 用户目录", "Open Rime User Folder"), action: #selector(openRimeDirectory(_:)),
                                 keyEquivalent: "")
        rimeDir.target = self
        menu.addItem(rimeDir)
        let deploy = NSMenuItem(title: tr("重新部署词库", "Redeploy Dictionaries"), action: #selector(redeploy(_:)), keyEquivalent: "")
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

    @objc func setOutputLanguage(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let raw = Self.menuItem(from: sender)?.representedObject as? String,
                  let language = Language(rawValue: raw) else {
                log.error("output menu action without a language")
                return
            }
            do {
                var config = try Config.load()
                config.outputLanguage = language
                try config.write()
                log.notice("output language now \(raw, privacy: .public)")
            } catch {
                log.error("could not update the output language: \(String(describing: error), privacy: .public)")
            }
        }
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
