import AllInOneIMECore
import AllInOneIMERime
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
    /// Sentence mode (`Composer.sentenceMode`), off unless turned on.
    static var sentenceMode: Bool {
        get { UserDefaults.standard.object(forKey: "sentenceMode") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "sentenceMode") }
    }
}

/// The installed plugins, scanned again when a text field becomes active (installing or removing one
/// shows up there) and at most every 30 seconds otherwise.
enum LivePlugins {
    private static var cached: (at: Date, result: (plugins: [InstalledPlugin], skipped: [PluginStore.Skipped]))?

    static func current(rescan: Bool = false) -> [InstalledPlugin] {
        if !rescan, let cached, Date().timeIntervalSince(cached.at) < 30 { return cached.result.plugins }
        let result = PluginStore.load()
        cached = (Date(), result)
        return result.plugins
    }
}

/// How much each @ command is used (the order of the command list), shared by every text field and kept
/// across launches.
enum CommandUsageStore {
    private static let key = "commandUsage"
    static var usage: CommandUsage = {
        guard let data = UserDefaults.standard.data(forKey: key),
              let usage = try? JSONDecoder().decode(CommandUsage.self, from: data) else { return CommandUsage() }
        return usage
    }()

    static func save(_ new: CommandUsage) {
        usage = new
        if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: key) }
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

/// The user's jargon list (for explaining the terms a jargon (黑话) line uses), re-read when the file changes.
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
@objc(AllInOneIMEInputController)
final class AllInOneIMEInputController: IMKInputController {
    /// The input state machine. It asks `secureInputActive` before starting Claude Code.
    lazy var composer: Composer = {
        let composer = Composer(sentenceMode: Settings.sentenceMode)
        composer.secureInputActive = { [weak self] in self?.secureInputActive() ?? false }
        return composer
    }()
    private var session: RimeSession?
    /// Whether the app still has the text being typed (Slack may take it into a mention on its own).
    private var markedWatch = MarkedTextWatch()
    private var conversionTask: Task<Void, Never>?
    private var lastElapsed: TimeInterval?
    private var lastFromCache = false
    private var notice: String?
    /// Whether this text session has delivered a key yet (logged once, without the key).
    private var receivedKeys = false
    /// Shown once each time composing gets paused for secure input.
    private var secureNoticeShown = false
    var converter: Converter = sharedConverter
    /// Persists the sentence mode switch (the self-test replaces this so it leaves the setting alone).
    var saveSentenceMode: (Bool) -> Void = { Settings.sentenceMode = $0 }
    /// The command usage as kept, and keeping it (the self-test leaves the user's alone).
    var loadCommandUsage: () -> CommandUsage = { CommandUsageStore.usage }
    var saveCommandUsage: (CommandUsage) -> Void = { CommandUsageStore.save($0) }
    /// Whether secure event input is on anywhere; no text is sent to the model then.
    /// (The self-test replaces this to exercise both states.)
    var secureInputActive: () -> Bool = { SecureInput.isOn }
    /// Only set by the self-test: IMK refuses to create a controller for anything but its own
    /// client proxies, so the test injects its fake text field here.
    var clientOverride: IMKTextInput?
    /// The settings the controller follows (the self-test supplies its own).
    var loadSettings: () -> Config = { LiveConfig.current }
    /// Sentence mode as saved (the self-test supplies its own).
    var loadSentenceMode: () -> Bool = { Settings.sentenceMode }
    /// `@open`: finds files and apps, and opens the one picked (the self-test opens nothing).
    var searchFiles: (String) async -> [SearchResult] = { await FileSearch.run($0) }
    /// Opens an `@open` result: a web address in the default browser, anything else as a file.
    var openItem: (String) -> Void = {
        NSWorkspace.shared.open(SearchResult(name: "", path: $0).webURL ?? URL(fileURLWithPath: $0))
    }
    /// `@claude`: starts Claude Code in Terminal (the self-test starts nothing).
    var runInTerminal: (String) throws -> Void = { try TerminalLauncher.claude($0) }
    /// A custom `terminal` command: runs its arguments in Terminal (the self-test starts nothing).
    var launchInTerminal: ([String]) throws -> Void = { try TerminalLauncher.launch($0) }
    /// Whether a command's program is on this Mac (the self-test supplies its own). Called off the main thread.
    var programInstalled: @Sendable (String) -> Bool = { program in
        if program == "claude", TerminalLauncher.claudePath != nil { return true }
        if program.hasSuffix(".app") { return FileManager.default.fileExists(atPath: program) }  // a send command's app
        return CommandRunner.resolve(program, path: ShellEnvironment.current["PATH"]) != nil
    }
    /// The commands whose programs were last checked (`setCommands`), and those whose program is missing.
    private var checkedCommands: [Command] = []
    private var missingCommands: Set<String> = []
    /// The latest check (an older one that finishes later is ignored).
    private var programCheck = 0
    /// Background `@claude` tasks: starting one, the list, opening one (the self-test supplies its own).
    var startAgent: (String) async throws -> String = { try await AgentMonitor.shared.start($0) }
    var listAgents: () async throws -> [(session: AgentSession, reply: String?)] = { try await AgentMonitor.shared.list() }
    var openAgent: (String) -> Void = { id in MainActor.assumeIsolated { AgentMonitor.shared.open(id) } }
    /// A custom `run` command: runs its program in the background (the self-test supplies its own).
    var runProgram: (CustomCommand, String) -> AsyncThrowingStream<ConversionUpdate, Error> = { CommandRunner.run($0, input: $1) }
    /// A script plugin: runs in this program's own child process (`--run-plugin`).
    var runPlugin: (InstalledPlugin, String) -> AsyncThrowingStream<ConversionUpdate, Error> = { PluginRunner.run($0, input: $1) }
    /// ⌘C on a result (the self-test leaves the clipboard alone).
    var copyText: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// ⌘V in a draft: the clipboard's text, or nil to let the app paste as usual (the self-test
    /// supplies its own and never reads the real clipboard).
    var readClipboard: () -> String? = { AllInOneIMEInputController.clipboardText(NSPasteboard.general) }

    /// Text on `pasteboard` to take into a draft. Nil for none, for what password managers mark as
    /// concealed or transient (nspasteboard.org, and the older markers), and when pasting from other
    /// apps is denied to this one.
    static func clipboardText(_ pasteboard: NSPasteboard) -> String? {
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .alwaysDeny { return nil }
        let types = pasteboard.types ?? []
        let hidden = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword",
                      "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping", "Pasteboard generator type",
                      "net.antelle.keeweb"].map { NSPasteboard.PasteboardType(rawValue: $0) }
        guard types.contains(.string), hidden.allSatisfy({ !types.contains($0) }) else { return nil }
        return pasteboard.string(forType: .string)
    }
    /// `@imessage`: the address book (nil: no access), and sending (the self-test supplies stand-ins:
    /// never the real Contacts or Messages).
    var loadContacts: () async -> [Contact]? = {
        if case let .contacts(contacts) = await ContactBook.load() { return contacts }
        return nil
    }
    var messageSender: MessageSender = AppleScriptMessageSender()
    /// The handles last messaged, and keeping them (the self-test leaves the user's alone).
    var loadRecentHandles: () -> [String] = { RecentRecipients.handles }
    var saveRecentHandles: ([String]) -> Void = { RecentRecipients.handles = $0 }
    /// The recipient text last searched, and the search in flight for it.
    private var recipientSearchQuery: String?
    private var recipientSearchTask: Task<Void, Never>?
    /// The `@open` text last searched as it was typed, and the search in flight for it.
    private var liveSearchQuery: String?
    private var liveSearchTask: Task<Void, Never>?
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
            markedWatch.reset()  // another text field, maybe another app
            ensureEngine()
            applySettings()
            // Terminals paste on ⌘V whatever the input method does: there ⌘V stays theirs.
            let app = (sender as? IMKTextInput)?.bundleIdentifier()
            composer.pastesIntoDraft = !(app.map(SecureInput.terminals.contains) ?? false)
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

    /// Takes over the current settings: sentence mode, English drafts, voice key, action key, and the
    /// default input mode (applied to new sessions, and again when the setting changes; a Shift toggle
    /// otherwise sticks).
    @MainActor
    func applySettings() {
        let config = loadSettings()
        composer.sentenceMode = loadSentenceMode()
        composer.englishAI = config.englishAI
        composer.voiceEnabled = config.voiceInput && VoiceInput.isSupported
        composer.actionKey = config.actionKey
        composer.claudeInBackground = config.claudeInBackground
        setCommands(Command.catalog(config.customCommands, plugins: LivePlugins.current(rescan: true)), recheck: true)
        // The interface language (config `uiLanguage`, else the system's) for the panel, notices and menu.
        UIText.choice = config.uiLanguage
        composer.messages = UIText.chinese ? .chinese : .english
        composer.inputLanguages = config.inputLanguages
        // With one input language, a field is always in it (it may have been switched before it was the only one).
        let onlyOne = config.inputLanguages.count == 1
        if appliedDefaultInput != config.defaultInput || onlyOne, composer.engine != nil, !composer.isComposing {
            composer.setInputMode(config.defaultInput)
            appliedDefaultInput = config.defaultInput
        }
    }

    /// Takes over the commands "@" offers, without those whose program isn't on this Mac (`@claude`
    /// without Claude Code, a custom command's missing `argv[0]`): "@claude …" is then just text, like
    /// "@name". Which are missing is checked in the background when the commands changed, or with
    /// `recheck` (a text field became active: something may have been installed meanwhile).
    @MainActor
    func setCommands(_ commands: [Command], recheck: Bool = false) {
        composer.commands = commands.filter { !missingCommands.contains($0.name) }
        guard recheck || commands != checkedCommands else { return }
        checkedCommands = commands
        programCheck += 1
        let check = programCheck
        let needed = commands.compactMap { command in command.program.map { (command.name, $0) } }
        let installed = programInstalled
        DispatchQueue.global().async { [weak self] in
            // The first check asks the user's shell for its PATH, which takes a moment.
            let missing = Set(needed.filter { !installed($0.1) }.map(\.0))
            DispatchQueue.main.async {
                guard let self, self.programCheck == check else { return }
                if !missing.isEmpty { log.notice("commands hidden, their program isn't installed: \(missing.count)") }
                self.missingCommands = missing
                // Not while a command is being written: the draft keeps the commands it started with.
                if !self.composer.isComposing { self.composer.commands = commands.filter { !missing.contains($0.name) } }
            }
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
        // The app took the text being typed without saying so (Slack, on an "@…"): start over rather than
        // show the draft again, doubled. This key is dropped, so ⏎ doesn't send half a sentence.
        if composer.isComposing, let target,
           markedWatch.appTookText(expected: composer.markedText, reportedLength: Self.markedLength(target)) {
            log.notice("the app took the marked text: starting over")
            perform(composer.appTookMarkedText(), client: client)
            return true
        }
        ensureEngine()
        // Commands added to the config apply from the next sentence on (the file is re-read only when it changed).
        if !composer.isComposing {
            setCommands(Command.catalog(loadSettings().customCommands, plugins: LivePlugins.current()))
            composer.commandUsage = loadCommandUsage()  // another text field may have run commands
            composer.claudeInBackground = loadSettings().claudeInBackground
        }
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
                if refusedForSecureInput(id: id, client: target) { break }
                startConversion(input, id: id)
            case let .startCommand(command, input, id):
                if refusedForSecureInput(id: id, client: target) { break }
                startConversion(input, id: id, command: command)
            case let .startPlan(outer, plan, id):
                // Inner commands run programs or reach the network: refused during secure input like any.
                if refusedForSecureInput(id: id, client: target, running: true) { break }
                startConversion("", id: id, command: outer, plan: plan)
            case let .startRun(command, input, id):
                if refusedForSecureInput(id: id, client: target, running: true) { break }
                startConversion(input, id: id, command: command)
            case let .search(query, id):
                conversionTask?.cancel()
                conversionTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let results = await self.searchFiles(query)
                    guard !Task.isCancelled else { return }
                    log.notice("search \(id): \(results.count) results")
                    self.perform(self.composer.receiveSearch(results, id: id), client: nil)
                }
            case let .open(path):
                if let agent = SearchResult(name: "", path: path).agentID {
                    openAgent(agent)  // a background task: in Terminal
                    break
                }
                log.notice("opening an @open result")
                openItem(path)
            case let .openLink(url):
                // The site is public (a plugin's or the user's own template); the text in it is not.
                log.notice("link command: opening \(url.host ?? "-", privacy: .public) in the browser")
                openItem(url.absoluteString)
            case let .startBackgroundAgent(prompt):
                Task { @MainActor [weak self] in
                    do {
                        _ = try await self?.startAgent(prompt)
                    } catch {
                        log.error("@claude in the background failed: \(String(describing: error), privacy: .public)")
                        self?.showNotice(UIText.describe(error), client: nil)
                    }
                }
            case .openSettings:
                SettingsWindow.shared.show()
            case let .listAgents(id):
                conversionTask?.cancel()
                conversionTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let results: [SearchResult]
                    do {
                        results = try await self.listAgents().map { session, reply in
                            let mark = session.progress == .done ? "✓" : session.progress == .needsYou ? "⚠︎" : "…"
                            return SearchResult(name: "\(mark) \(session.name ?? session.shortID)",
                                                path: SearchResult.agentPrefix + session.shortID, detail: reply)
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.perform(self.composer.fail(UIText.describe(error), id: id), client: nil)
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self.perform(self.composer.receiveSearch(results, id: id), client: nil)
                }
            case let .runInTerminal(prompt):
                do {
                    try runInTerminal(prompt)
                    log.notice("@claude: Terminal session started (\(prompt.count) chars)")
                } catch {
                    log.error("@claude: could not start Terminal: \(String(describing: error), privacy: .public)")
                    showNotice(UIText.describe(error), client: target)
                }
            case .commandUsed:
                saveCommandUsage(composer.commandUsage)
            case let .launchInTerminal(argv):
                do {
                    try launchInTerminal(argv)
                    log.notice("custom command: Terminal started (\(argv.count) arguments)")
                } catch {
                    log.error("custom command: could not start Terminal: \(String(describing: error), privacy: .public)")
                    showNotice(UIText.describe(error), client: target)
                }
            case let .copy(text):
                copyText(text)
            case let .sendMessage(recipient, text, command):
                sendMessage(text, to: recipient, command: command, client: target)
            case let .readClipboard(id):
                // After the key has been answered: if macOS asks whether this may read the clipboard,
                // the app isn't left waiting for the key (and doesn't paste on its own meanwhile).
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let text = self.readClipboard()
                    // Only how much: never the text itself.
                    log.notice("clipboard for a command: \(text.map { "\($0.count) chars" } ?? "no usable text", privacy: .public)")
                    self.perform(self.composer.pasted(text, id: id), client: nil)
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
            case let .sentenceModeChanged(on):
                saveSentenceMode(on)
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
        scheduleLiveSearch()
        scheduleRecipientSearch()
    }

    /// A send command's recipient as it is typed: a short pause, then the contacts that match (Contacts
    /// access is asked for here, the first time).
    @MainActor
    private func scheduleRecipientSearch() {
        let query = composer.recipientQuery
        guard query != recipientSearchQuery else { return }
        recipientSearchQuery = query
        recipientSearchTask?.cancel()
        guard let query else { return }
        let recent = loadRecentHandles()
        recipientSearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self, !Task.isCancelled else { return }
            let contacts = await self.loadContacts()
            guard !Task.isCancelled else { return }
            let found = await Task.detached { RecipientSearch.results(query, contacts: contacts ?? [], recent: recent) }.value
            guard !Task.isCancelled else { return }
            let note = contacts == nil
                ? tr("没有通讯录权限：系统设置 → 隐私与安全性 → 通讯录 → 打开 AllInOneIME；也可以直接输入手机号或邮箱",
                     "No access to Contacts: System Settings → Privacy & Security → Contacts → turn on AllInOneIME; or type a phone number or email")
                : found.isEmpty ? (query.isEmpty ? tr("输入名字、拼音、手机号或邮箱", "Type a name, phone number or email")
                                                 : tr("没有找到联系人；也可以输入完整的手机号或邮箱", "No contact found; or type a full phone number or email"))
                : nil
            self.perform(self.composer.receiveRecipients(found, note: note, for: query), client: nil)
        }
    }

    /// Sends a confirmed message off the main thread; a notice says how it went. The log keeps no
    /// names, handles or text.
    @MainActor
    private func sendMessage(_ text: String, to recipient: Recipient, command: Command, client: IMKTextInput?) {
        guard !secureInputActive() else {
            showNotice(tr("系统安全输入已开启（密码框或锁屏），没有发送", "Secure input is on (a password field or the lock screen): nothing was sent"),
                       client: client)
            return
        }
        log.notice("@\(command.name, privacy: .public): sending (\(text.count) chars)")
        let sender = messageSender
        Task { @MainActor [weak self] in
            do {
                try await sender.send(text, to: recipient)
                log.notice("@\(command.name, privacy: .public): sent")
                guard let self else { return }
                self.saveRecentHandles(RecipientSearch.remember(recipient.handle, in: self.loadRecentHandles()))
                self.showNotice(tr("已发送给 ", "Sent to ") + recipient.displayName, client: nil)
            } catch {
                let code: String
                switch error {
                case MessageSendError.notPermitted: code = "-1743"
                case let MessageSendError.failed(number): code = String(number)
                default: code = String(describing: type(of: error))
                }
                log.error("@\(command.name, privacy: .public): sending failed (\(code, privacy: .public))")
                self?.showNotice(UIText.describe(error), client: nil)
            }
        }
    }

    /// `@open` as you type: a short pause after the text changes, then a search for it.
    @MainActor
    private func scheduleLiveSearch() {
        let query = composer.liveQuery
        guard query != liveSearchQuery else { return }
        liveSearchQuery = query
        liveSearchTask?.cancel()
        guard let query else { return }
        liveSearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            let results = await self.searchFiles(query)
            guard !Task.isCancelled else { return }
            self.perform(self.composer.receiveLive(results, for: query), client: nil)
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
                perform(composer.voiceFailed(tr("没有麦克风权限：系统设置 → 隐私与安全性 → 麦克风 → 打开 AllInOneIME",
                                                "No microphone access: System Settings → Privacy & Security → Microphone → turn on AllInOneIME"),
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
        markedWatch.didSet(expected: text, reportedLength: Self.markedLength(client))
    }

    /// The length of the app's marked text, or nil when it reports none.
    static func markedLength(_ client: IMKTextInput) -> Int? {
        let range = client.markedRange()
        return range.location == NSNotFound ? nil : range.length
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

    /// While secure input is on anywhere (a password field or prompt may be active), nothing is sent
    /// off the Mac: the request fails at once. True if refused.
    @MainActor
    private func refusedForSecureInput(id: Int, client: IMKTextInput?, running: Bool = false) -> Bool {
        guard secureInputActive() else { return false }
        log.info("conversion \(id) not sent: secure input \(SecureInput.ownerDescription(), privacy: .public)")
        let message = running
            ? tr("系统安全输入已开启（密码框或锁屏），没有运行命令",
                 "Secure input is on (a password field or the lock screen): the command was not run")
            : tr("系统安全输入已开启（密码框或锁屏），未发送给 AI",
                 "Secure input is on (a password field or the lock screen): nothing was sent to the AI")
        perform(composer.fail(message, id: id), client: client)
        return true
    }

    /// Streams level two for `input`: the improve conversion, a `.generate` command's answer, or what a
    /// `.run` command's program printed.
    @MainActor
    private func startConversion(_ input: String, id: Int, command: Command? = nil, plan: CommandPlan? = nil) {
        conversionTask?.cancel()
        lastElapsed = nil
        lastFromCache = false
        // Plugin names are public (from the library); custom command names are the user's own.
        func logged(_ command: Command) -> String { command.custom == nil || command.plugin != nil ? command.name : "custom" }
        let inner = plan.map { ", inside: " + $0.inner.map { "@" + logged($0.command) }.joined(separator: " ") } ?? ""
        log.notice("conversion \(id) started (\(input.count) chars\(command.map { ", @\(logged($0))" } ?? "")\(inner), privacy: .public))")
        let (runPlugin, runProgram, converter) = (self.runPlugin, self.runProgram, self.converter)
        // Not tied to the main actor: the pipeline calls it from its own task.
        let streamFor: @Sendable (Command?, String) -> AsyncThrowingStream<ConversionUpdate, Error> = { command, input in
            if command == .read { return WebReader.stream(input) }
            // A link opens once the commands inside its text have run: their outputs go in it as they are.
            if let command, command.kind == .link { return LinkTemplate.passThrough(input) }
            if command?.kind == .message { return CommandPipeline.unchanged(input) }  // sent as written, after confirming
            if let command, command.kind == .run, let plugin = command.plugin { return runPlugin(plugin, input) }
            if let command, command.kind == .run, let custom = command.custom { return runProgram(custom, input) }
            return command.map { converter.generate($0, input: input) } ?? converter.convert(input)
        }
        let stream: AsyncThrowingStream<ConversionUpdate, Error>
        if let plan, !plan.isEmpty {
            // The commands inside the text first (together), then this one on the text with their outputs.
            stream = CommandPipeline.run(plan, inner: { streamFor($0, $1) }, outer: { streamFor(command, $0) })
        } else {
            stream = streamFor(command, input)
        }
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
        case let ProviderError.http(provider, status, type, _): return "\(provider.rawValue) http \(status) \(type ?? "-")"
        case let ProviderError.stream(provider, type, _): return "\(provider.rawValue) stream \(type)"
        case let ProviderError.missingKey(provider): return "\(provider.rawValue) no key"
        case let ProviderError.refused(provider): return "\(provider.rawValue) refused"
        case ProviderError.signedOut: return "hosted signed out"
        case ProviderError.quotaExhausted: return "hosted quota exhausted"
        case let urlError as URLError: return "url \(urlError.code.rawValue)"
        default: return String(describing: type(of: error))
        }
    }

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "请求超时"
            case .notConnectedToInternet, .networkConnectionLost: return "网络连接失败"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "无法连接 AI 服务"
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
        panel.onScroll = { [weak self] steps in
            guard let self else { return }
            self.perform(self.composer.scrollPalette(by: steps), client: nil)
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

    /// Short status message ("英" English mode, "整句模式：关" sentence mode off, …): its own small
    /// panel when nothing else is shown, otherwise the right side of the footer.
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

    /// What the action key does to a sentence in `input`: "翻译成英文", "英文润色" …, plus " / 改写"
    /// when rewrite styles are on.
    static func actionText(input: Language, config: Config) -> String {
        let output = config.outputLanguage
        let name = output.name(chinese: true)
        let action = input.matches(output) ? "\(name)润色" : "翻译成\(name)"
        return action + (RewriteStyle.resolve(config.rewriteStyles).isEmpty ? "" : " / 改写")
    }

    /// The hint under a pending draft: "单按 ⌥ → 翻译成英文 / 改写", "Tap ⌥ → translate to English / rewrite" …
    @MainActor
    func draftHint(config: Config) -> String {
        let key = composer.actionKey
        let how = key != .space ? UIText.name(key)
            : composer.spaceActs ? UIText.name(ActionKey.space) : tr("连按两次空格", "Space twice")
        let input = Language.of(composer.sentText)
        // A command with nothing after it: the action key takes the clipboard's text.
        if composer.draftCommand != nil, composer.sentText.isEmpty {
            return "\(how) → " + tr("用剪贴板里的文字", "use the clipboard text")
        }
        return "\(how) → " + (composer.draftCommand.map { UIText.action($0, input: input, config: config) }
            ?? UIText.action(input: input, config: config))
    }

    /// A long answer as the panel shows it (the whole text is inserted).
    static func preview(_ text: String, limit: Int = 280) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    @MainActor
    func panelModel() -> CandidateView.Model {
        var model = CandidateView.Model()
        let config = loadSettings()
        if composer.isLevelTwo {
            let choices = composer.choices
            model.rows = choices.map { choice in
                // Long rows (a pasted paragraph and its versions) are shortened here; the full text goes in.
                switch choice.kind {
                case .original:
                    return CandidateView.Row(label: choice.label, text: Self.preview(choice.text), comment: tr("原文", "original"),
                                             style: .original)
                case .version:
                    return CandidateView.Row(label: choice.label, text: Self.preview(choice.text), style: .translation,
                                             isComplete: choice.isComplete)
                case let .rewrite(style):
                    // A jargon (黑话) line notes what the terms from the user's jargon list in it mean.
                    let note = style == RewriteStyle.jargonName
                        ? JargonLibrary.annotation(for: choice.text, entries: LiveJargon.entries(for: config)) : nil
                    let name = RewriteStyle.named(style).map(UIText.name) ?? style
                    return CandidateView.Row(label: choice.label, text: Self.preview(choice.text),
                                             comment: note.map { "\(name) · \($0)" } ?? name,
                                             style: .translation, isComplete: choice.isComplete)
                case .answer:
                    // A program's output may have several lines; they are inserted as printed.
                    let text = choice.text.replacingOccurrences(of: "\n", with: " ↵ ")
                    return CandidateView.Row(label: choice.label, text: Self.preview(text),
                                             comment: UIText.answerLabel(composer.activeCommand),
                                             style: .translation, isComplete: choice.isComplete)
                case let .file(path) where path.hasPrefix(SearchResult.agentPrefix):
                    // A background task: its last reply, shortened.
                    let reply = composer.searchResults.first { $0.path == path }?.detail ?? ""
                    let preview = reply.replacingOccurrences(of: "\n", with: " ")
                    // Its state as an icon instead of the mark before its name.
                    let marks: [(String, AgentSession.Progress)] = [("✓ ", .done), ("⚠︎ ", .needsYou), ("… ", .working)]
                    let state = marks.first { choice.text.hasPrefix($0.0) }
                    return CandidateView.Row(label: choice.label, text: state.map { String(choice.text.dropFirst($0.0.count)) } ?? choice.text,
                                             comment: preview.count > 60 ? String(preview.prefix(60)) + "…" : preview, style: .candidate,
                                             icon: state.map { CommandIcons.icon(for: $0.1) })
                case let .file(path) where SearchResult(name: "", path: path).webURL != nil:
                    return CandidateView.Row(label: choice.label, text: choice.text,
                                             comment: tr("在浏览器中打开", "open in the browser"), style: .candidate)
                case .send:
                    // 「发给 张三（+1 555…）：…」: who it goes to and the text, to confirm.
                    let to = composer.messageRecipient.map { $0.name.isEmpty ? $0.handle : "\($0.name)（\($0.handle)）" } ?? ""
                    return CandidateView.Row(label: choice.label,
                                             text: tr("发给 \(to)：", "Send to \(to): ") + Self.preview(choice.text.replacingOccurrences(of: "\n", with: " ↵ ")),
                                             style: .translation, isComplete: choice.isComplete,
                                             icon: composer.activeCommand.map(CommandIcons.icon(for:)))
                case let .file(path):
                    let folder = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
                    return CandidateView.Row(label: choice.label, text: choice.text,
                                             comment: path.hasSuffix(".app") ? tr("应用", "app") : folder, style: .candidate)
                }
            }
            model.highlighted = composer.highlighted
            let command = composer.activeCommand
            switch composer.phase {
            case .translating:
                let polishing = Language.of(composer.sentText).matches(config.outputLanguage)
                let loading = command?.kind == .generate ? tr("AI 回答中…", "Answering…")
                    : command?.kind == .run ? tr("运行中…", "Running…")
                    : command?.kind == .link ? tr("运行句中的命令，然后在浏览器打开…", "Running the commands inside, then opening the browser…")
                    : command == .open ? tr("搜索中…", "Searching…")
                    : command == .tasks ? tr("读取后台任务…", "Reading the background tasks…")
                    : command?.kind == .message ? tr("运行句中的命令…", "Running the commands in the message…")
                    : polishing ? tr("AI 润色中…", "Polishing…") : tr("AI 翻译中…", "Translating…")
                model.status = choices.count <= 1 ? .loading(loading) : .none
                model.footer = command == .open ? tr("搜索中… · Esc 返回", "Searching… · Esc back")
                    : command?.kind == .link ? tr("完成后在浏览器打开 · Esc 返回", "Opens in the browser when done · Esc back")
                    : tr("生成中… · 0 原文 · Esc 返回", "Generating… · 0 original · Esc back")
            case .choosing where command?.kind == .message:
                model.footer = tr("⏎ 发送 · Esc 返回修改", "⏎ send · Esc back to editing")
            case .choosing where command == .tasks:
                model.footer = tr("⏎ 在终端打开 · 数字选择 · ⌘C 复制回复 · Esc 返回",
                                  "⏎ open in Terminal · digits pick · ⌘C copy the reply · Esc back")
            case .choosing:
                model.footer = command == .open
                    ? tr("空格 / ⏎ 打开 · 数字选择 · ⌘C 复制路径 · Esc 返回", "Space / ⏎ open · digits pick · ⌘C copy path · Esc back")
                    : tr("空格 / ⏎ 上屏 · 数字选择 · 0 原文 · ⌘C 复制 · Esc 返回",
                         "Space / ⏎ insert · digits pick · 0 original · ⌘C copy · Esc back")
                if command != .open {
                    model.detail = lastFromCache ? tr("缓存", "cached") : lastElapsed.map { String(format: "%.1fs", $0) }
                }
            case let .failed(message):
                model.status = .error(message)
                model.highlighted = nil  // Space retries; nothing is selected
                model.footer = composer.actionKey == .enter
                    ? tr("空格 / ⏎ 重试 · 0 原文 · Esc 返回", "Space / ⏎ retry · 0 original · Esc back")
                    : tr("空格 重试 · ⏎ 上屏原文 · Esc 返回", "Space retry · ⏎ insert original · Esc back")
            case .idle, .drafting:
                break
            }
        } else if composer.voice != .off {
            let heard = composer.voice.text
            if case .listening = composer.voice {
                model.status = .hint("🎙 " + (heard.isEmpty ? tr("正在听…", "Listening…") : heard))
                // The action key while right ⌥ is still held (⌥Return, or Space = ⌥Space): stop and run it.
                let key = composer.actionKey
                let runs = composer.sentenceMode || composer.draftCommand != nil
                model.footer = runs && (key == .optionSpace || key == .enter)
                    ? (key == .enter ? tr("松开右 ⌥ 结束 · ⏎ 直接执行 · Esc 取消", "Release right ⌥ to stop · ⏎ run now · Esc cancel")
                                     : tr("松开右 ⌥ 结束 · 空格 直接执行 · Esc 取消", "Release right ⌥ to stop · Space run now · Esc cancel"))
                    : tr("松开右 ⌥ 结束 · Esc 取消", "Release right ⌥ to stop · Esc cancel")
            } else {
                model.status = .hint("🎙 " + (heard.isEmpty ? tr("识别中…", "Recognizing…") : heard))
                model.footer = composer.actsAfterVoice
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
            let key = composer.actionKey
            if let command = composer.draftCommand {
                // Pinyin in an @ command: the action key converts it and runs the command.
                let input: Language = composer.sentText.containsHan || !composer.engineState.isAsciiMode ? .chinese : .english
                let action = UIText.action(command, input: input, config: config)
                model.footer = tr("空格 选词 · \(UIText.name(key)) \(action)", "Space picks · \(UIText.name(key)) to \(action)")
            } else if composer.sentenceMode {
                let action = config.outputLanguage == .chinese ? tr("润色", "polish") : tr("翻译", "translate")
                model.footer = key == .space ? tr("空格 选词 · 整句打完再按空格\(action)", "Space picks · Space again when done to \(action)")
                    : tr("空格 选词 · \(UIText.name(key)) \(action)", "Space picks · \(UIText.name(key)) to \(action)")
            } else {
                model.footer = tr("空格 选词 · 开头打 @ 用命令", "Space picks · type @ first for commands")
            }
            if state.pageNumber > 0 || !state.isLastPage {
                model.detail = tr("第 \(state.pageNumber + 1) 页", "page \(state.pageNumber + 1)")
            }
        } else if composer.paletteQuery != nil {
            // "@…": the commands that start with what was typed.
            // Five at a time; the rest scroll into view (the position on the right).
            let first = composer.paletteFirstVisible, total = composer.paletteMatches.count
            model.rows = composer.paletteVisible.enumerated().map {
                CandidateView.Row(label: String($0.offset + 1), text: "@" + $0.element.name,
                                  comment: UIText.summary($0.element), style: .candidate,
                                  icon: CommandIcons.icon(for: $0.element))
            }
            model.highlighted = composer.paletteHighlighted - first
            if total > Composer.paletteRows { model.detail = "\(first + 1)–\(first + model.rows.count) / \(total)" }
            model.footer = tr("⏎ / Tab / 空格 选择 · Esc 取消", "⏎ / Tab / Space choose · Esc cancel")
        } else if !composer.currentLiveResults.isEmpty {
            // "@open …" as you type: what matches now.
            model.rows = composer.currentLiveResults.map { result in
                let folder = ((result.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
                let comment = result.path.hasSuffix(".app") ? tr("应用", "app") : result.isFolder ? folder + "/" : folder
                return CandidateView.Row(label: result.isFolder ? "›" : "", text: result.name, comment: comment, style: .candidate)
            }
            model.highlighted = composer.liveHighlight
            model.footer = tr("⏎ 打开 · Tab 补全路径 · ↑↓ 选择 · ⌘C 复制路径 · Esc 取消",
                              "⏎ open · Tab complete path · ↑↓ choose · ⌘C copy path · Esc cancel")
        } else if composer.recipientQuery != nil {
            // "@imessage zs": the contacts that match, to pick the recipient.
            let found = composer.currentRecipients
            model.rows = found.enumerated().map { index, recipient in
                CandidateView.Row(label: String(index + 1), text: recipient.displayName,
                                  comment: recipient.name.isEmpty ? tr("直接发送到这个号码 / 邮箱", "send to this number / email") : recipient.handle,
                                  style: .candidate)
            }
            model.highlighted = found.isEmpty ? nil : composer.recipientHighlight
            if let note = composer.recipientNote { model.status = .hint(note) }
            model.footer = tr("⏎ / Tab 选择收件人 · ↑↓ · Esc 取消", "⏎ / Tab pick the recipient · ↑↓ · Esc cancel")
        } else if !composer.draft.isEmpty {
            model.status = .hint(draftHint(config: config))
            let asTyped = composer.actionKey == .enter ? "⇧⏎" : "⏎"
            model.footer = composer.draftCommand != nil ? tr("⌃V 粘贴 · ⌫ 删字 · Esc 清除", "⌃V paste · ⌫ delete · Esc clear")
                : composer.isLatinDraft ? tr("\(asTyped) 直接上屏 · ⌫ 删字", "\(asTyped) insert as typed · ⌫ delete")
                : tr("\(asTyped) 上屏原文 · ⌫ 删字 · Esc 清除", "\(asTyped) insert as typed · ⌫ delete · Esc clear")
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
        let ai = NSMenuItem(title: tr("整句模式（⇧空格）", "Sentence Mode (⇧Space)"),
                            action: #selector(toggleSentenceMode(_:)), keyEquivalent: "")
        ai.target = self
        ai.state = Settings.sentenceMode ? .on : .off
        menu.addItem(ai)
        let model = config.map { tr("模型：", "Model: ") + ($0.settings(for: $0.provider).model ?? "") } ?? tr("配置文件有误", "The config file has an error")
        let info = NSMenuItem(title: model, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)

        menu.addItem(.separator())
        // Output and input languages in submenus like the styles: each lists only the languages the user
        // added (a new user has one), with "Add Languages…" opening the settings.
        let current = config ?? .default
        let outputItem = NSMenuItem(title: tr("输出：", "Output: ") + UIText.name(current.outputLanguage), action: nil, keyEquivalent: "")
        let outputs = NSMenu()
        for language in current.outputLanguages {
            let item = NSMenuItem(title: tr("翻译 / 润色成\(UIText.name(language))", "Translate / Polish into \(UIText.name(language))"),
                                  action: #selector(setOutputLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.code
            item.state = current.outputLanguage == language ? .on : .off
            item.isEnabled = config != nil  // don't overwrite a config file that failed to parse
            outputs.addItem(item)
        }
        outputs.addItem(.separator())
        let addOutput = NSMenuItem(title: tr("添加语言…", "Add Languages…"), action: #selector(showPreferences(_:)), keyEquivalent: "")
        addOutput.target = self
        outputs.addItem(addOutput)
        outputItem.submenu = outputs
        menu.addItem(outputItem)

        let inputItem = NSMenuItem(title: tr("输入：", "Input: ") + current.inputLanguages.map(Self.inputName).joined(separator: " + "),
                                   action: nil, keyEquivalent: "")
        let inputs = NSMenu()
        // The added input languages, the default one checked (a new text field starts in it).
        for language in current.inputLanguages {
            let item = NSMenuItem(title: Self.inputName(language), action: #selector(setDefaultInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = current.defaultInput == language ? .on : .off
            item.isEnabled = config != nil
            inputs.addItem(item)
        }
        inputs.addItem(.separator())
        if current.inputLanguages.count > 1 {
            let shiftNote = NSMenuItem(title: tr("✓ 是默认；Shift 切换", "✓ is the default; Shift switches"), action: nil, keyEquivalent: "")
            shiftNote.isEnabled = false
            inputs.addItem(shiftNote)
        }
        let addInput = NSMenuItem(title: tr("添加语言…", "Add Languages…"), action: #selector(showPreferences(_:)), keyEquivalent: "")
        addInput.target = self
        inputs.addItem(addInput)
        inputItem.submenu = inputs
        menu.addItem(inputItem)

        // The styles in a submenu: six rows with summaries made the menu too long. Its title says which
        // are on, so the menu still shows the state without opening it.
        let enabledStyles = RewriteStyle.resolve(config?.rewriteStyles ?? Config.default.rewriteStyles)
        let enabled = Set(enabledStyles.map(\.name))
        let on = enabledStyles.map(UIText.name).joined(separator: tr("、", ", "))
        let stylesItem = NSMenuItem(title: tr("改写风格", "Rewrite Styles") + tr("：", ": ") + (on.isEmpty ? tr("无", "none") : on),
                                    action: nil, keyEquivalent: "")
        let styles = NSMenu()
        for style in RewriteStyle.catalog {
            let item = NSMenuItem(title: UIText.name(style) + tr("　", "  ") + UIText.summary(style),
                                  action: #selector(toggleStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.name
            item.state = enabled.contains(style.name) ? .on : .off
            item.isEnabled = config != nil  // don't overwrite a config file that failed to parse
            styles.addItem(item)
        }
        stylesItem.submenu = styles
        menu.addItem(stylesItem)
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

    @objc func toggleSentenceMode(_ sender: Any?) {
        MainActor.assumeIsolated {
            perform(composer.setSentenceMode(!composer.sentenceMode), client: nil)
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
            guard let raw = Self.menuItem(from: sender)?.representedObject as? String else {
                log.error("output menu action without a language")
                return
            }
            do {
                var config = try Config.load()
                config.outputLanguage = OutputLanguage(raw)
                config.normalizeLanguages()
                try config.write()
                log.notice("output language now \(raw, privacy: .public)")
            } catch {
                log.error("could not update the output language: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// An input language as the menu and the settings name it: "中文（拼音）", "英文".
    static func inputName(_ language: Language) -> String {
        language == .chinese ? tr("中文（拼音）", "Chinese (pinyin)") : UIText.name(language)
    }

    /// Makes an added input language the default: a new text field starts in it.
    @objc func setDefaultInput(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let raw = Self.menuItem(from: sender)?.representedObject as? String, let language = Language(rawValue: raw) else {
                log.error("input menu action without a language")
                return
            }
            do {
                var config = try Config.load()
                config.defaultInput = language
                config.normalizeLanguages()
                try config.write()
                log.notice("default input now \(config.defaultInput.rawValue, privacy: .public)")
                applySettings()
            } catch {
                log.error("could not update the default input: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `languages` with `language` removed, or added at the end; the last one stays.
    static func toggled(_ language: Language, in languages: [Language]) -> [Language] {
        if languages.contains(language) { return languages == [language] ? languages : languages.filter { $0 != language } }
        return languages + [language]
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
