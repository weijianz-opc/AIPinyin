import Foundation

/// Two-level input state machine.
///
/// Level one is a local pinyin engine (Rime): typing, selecting and committing words works like any
/// pinyin input method, and without an @ command that is all it does. A sentence that starts with an
/// @ command (`Command`, e.g. "@question …") collects into a *draft* (shown inline, not yet in the
/// document) instead of being inserted; in `sentenceMode` (the original flow) every sentence does. In
/// English mode, typed letters can start a draft too (`englishAI`), and holding the right Option key
/// dictates into the draft. The action key (`ActionKey`: Return by default, an Option tap, ⌥Space, or Space on a finished draft) starts
/// level two: pinyin still being typed is converted first, then the sentence goes to the model, which
/// streams three versions in the output language and rewrites in the configured styles, or to the
/// @ command at its start (`Command`).
///
///     idle ─letters / voice─▶ drafting ─action key─▶ translating ─final─▶ choosing
///      ▲               │   ▲ ◀──────────── Esc / ⌫ / typing more ────────────────────────┘ │
///      └── ⏎ commits draft ┘ ◀──────────────── Space / digits / ⏎ commit ──────────────────┘
///
/// Without sentence mode or an @ command, level one is a plain Rime input method (commits go straight in).
/// The input controller performs the returned `Effect`s in order. Main thread only.
public final class Composer {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The engine is composing, a draft is pending and/or speech is being recorded.
        case drafting
        case translating(id: Int)
        case choosing
        case failed(String)
    }

    /// Dictation (hold the right Option key).
    public enum Voice: Equatable, Sendable {
        case off
        /// Recording; `text` is what has been recognized so far.
        case listening(id: Int, text: String)
        /// The key was released; waiting for the final transcript.
        case finishing(id: Int, text: String)

        public var id: Int? {
            switch self {
            case .off: return nil
            case let .listening(id, _), let .finishing(id, _): return id
            }
        }

        public var text: String {
            switch self {
            case .off: return ""
            case let .listening(_, text), let .finishing(_, text): return text
            }
        }
    }

    public enum Effect: Equatable, Sendable {
        /// Re-render the inline marked text from `markedText` / `markedCursor`.
        case updateMarkedText
        /// Insert text into the document, replacing the marked text.
        case commit(String)
        case startConversion(input: String, id: Int)
        /// Run a `.generate` command (`@question`, `@claude`) on `input`; results arrive via `receive`.
        case startCommand(Command, input: String, id: Int)
        /// Find files and apps named like `query` (`@open`); results arrive via `receiveSearch`.
        case search(query: String, id: Int)
        /// Open a file or app (an `@open` result was picked).
        case open(path: String)
        /// Start a Claude Code session in a terminal window with `prompt` as its first message (`@claude`).
        case runInTerminal(prompt: String)
        /// Run `argv` in a new terminal window (a custom `terminal` command).
        case launchInTerminal(argv: [String])
        /// Run a custom `run` command's program on `input`; what it prints arrives via `receive`.
        case startRun(Command, input: String, id: Int)
        /// Put `text` on the clipboard (⌘C on a result).
        case copy(String)
        /// Read the clipboard's text for the draft (⌘V) and hand it to `pasted(_:id:)`, after the key
        /// has been answered: the system may ask the user first.
        case readClipboard(id: Int)
        case cancelConversion
        /// Show or refresh the candidate panel.
        case showPanel
        case hidePanel
        /// Briefly show a status message near the caret.
        case notice(String)
        /// Sentence mode was toggled; persist it.
        case sentenceModeChanged(Bool)
        /// The right Option key went down on its own: call `voiceHoldElapsed` after `delay` seconds.
        case armVoice(delay: Double)
        /// Start recording and recognizing speech in `language`.
        case startVoice(id: Int, language: Language)
        /// Stop recording and deliver the final transcript (`voiceFinished`).
        case stopVoice(id: Int)
        /// Stop recording and discard the result.
        case cancelVoice(id: Int)
    }

    public struct Response: Equatable, Sendable {
        public var effects: [Effect]
        /// False: the application should also receive the key.
        public var handled: Bool

        public init(effects: [Effect], handled: Bool) {
            self.effects = effects
            self.handled = handled
        }

        public static let passThrough = Response(effects: [], handled: false)
        public static func consumed(_ effects: [Effect] = []) -> Response { Response(effects: effects, handled: true) }
    }

    /// A level-two candidate.
    public struct Choice: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// The sentence as typed.
            case original
            /// One of the three main versions in the output language.
            case version
            /// A rewrite in the sentence's own language; the value is the style's Chinese name ("简洁", …).
            case rewrite(String)
            /// What a `.generate` command (`@question`) wrote, or a `.run` command's program printed.
            case answer
            /// A file or app found by `@open`; picking it opens it instead of inserting anything.
            case file(path: String)

            public var isRewrite: Bool {
                if case .rewrite = self { return true }
                return false
            }
        }
        public var label: String
        public var kind: Kind
        public var text: String
        public var isComplete: Bool
    }

    public private(set) var phase: Phase = .idle
    /// What the composer itself says (notices near the caret, a failure without a result), in the
    /// interface language. Chinese unless the controller sets another.
    public var messages = Messages.chinese

    public struct Messages: Equatable, Sendable {
        public var notReady: String
        public var holdToTalk: String
        public var didNotHear: String
        public var chineseMode: String
        public var englishMode: String
        public var sentenceModeOn: String
        public var sentenceModeOff: String
        public var noResult: String
        public var typeAfterCommand: String
        public var nothingFound: String
        public var copied: String
        public var openedTerminal: String
        /// @claude while secure input is on: Claude Code isn't started.
        public var secureInputTerminal: String
        /// A custom terminal command was started in its own window.
        public var ranInTerminal: String
        /// A custom terminal command while secure input is on: nothing is started.
        public var secureInputCommand: String
        /// A command whose program isn't installed; "{program}" is its name.
        public var notInstalled: String
        /// `@claude` without Claude Code installed.
        public var claudeNotInstalled: String
        /// ⌘V in a draft with more on the clipboard than `Composer.maxPasteLength`.
        public var pasteTooLong: String
        /// ⌘V in a draft with no text on the clipboard (or reading it isn't allowed).
        public var nothingToPaste: String

        public static let chinese = Messages(
            notReady: "词库准备中，稍候可用", holdToTalk: "按住右 ⌥ 说话", didNotHear: "没听清，再说一次",
            chineseMode: "中", englishMode: "英", sentenceModeOn: "整句模式：开", sentenceModeOff: "整句模式：关", noResult: "没有得到结果",
            typeAfterCommand: "在命令后面写上内容", nothingFound: "没有找到", copied: "已复制",
            openedTerminal: "已在终端打开 Claude Code",
            secureInputTerminal: "系统安全输入已开启（密码框或锁屏），没有打开 Claude Code",
            ranInTerminal: "已在终端运行",
            secureInputCommand: "系统安全输入已开启（密码框或锁屏），没有运行命令",
            notInstalled: "这台 Mac 上没有找到 {program}，先安装它",
            claudeNotInstalled: "没有安装 Claude Code（找不到 claude 命令），先安装再用 @claude",
            pasteTooLong: "剪贴板里的文字太长：最多 \(Composer.maxPasteLength) 字",
            nothingToPaste: "剪贴板里没有能用的文字")
        public static let english = Messages(
            notReady: "Loading the dictionaries, one moment", holdToTalk: "Hold right ⌥ to talk",
            didNotHear: "Didn't catch that, try again", chineseMode: "Chinese", englishMode: "English",
            sentenceModeOn: "Sentence mode: on", sentenceModeOff: "Sentence mode: off", noResult: "No result",
            typeAfterCommand: "Type something after the command", nothingFound: "Nothing found", copied: "Copied",
            openedTerminal: "Opened Claude Code in Terminal",
            secureInputTerminal: "Secure input is on (a password field or the lock screen): Claude Code was not opened",
            ranInTerminal: "Running in Terminal",
            secureInputCommand: "Secure input is on (a password field or the lock screen): the command was not run",
            notInstalled: "{program} isn't installed on this Mac",
            claudeNotInstalled: "Claude Code isn't installed (no claude command): install it to use @claude",
            pasteTooLong: "The clipboard text is too long: \(Composer.maxPasteLength) characters at most",
            nothingToPaste: "No text on the clipboard to use")
    }
    /// The command of the request in level two (nil: improve, as without one).
    public private(set) var activeCommand: Command?
    /// The commands "@" offers: the built-in ones and the user's (`Command.catalog`).
    public var commands: [Command] = Command.builtins
    /// Commands whose program isn't installed (set by the input controller), by name: the program.
    /// They stay in the list, but the action key only says what is missing.
    public var missingPrograms: [String: String] = [:]
    /// Files and apps found for `@open`.
    public private(set) var searchResults: [SearchResult] = []
    /// Results for the `@open` text as it is typed (`liveQuery`), and the highlighted one.
    public private(set) var liveResults: [SearchResult] = []
    private var liveResultsQuery: String?
    public private(set) var liveHighlight = 0
    /// A command that types Latin letters (`@open`, code) switched the engine to them; Chinese comes back after.
    private var restoreChineseAfterOpen = false
    /// Highlighted row of the command palette.
    private var paletteHighlight = 0
    /// The ⌘V whose clipboard text the draft is waiting for (`pasted`), and the last one's id.
    private var pendingPaste: Int?
    private var pasteCounter = 0
    /// The clipboard was asked for by the action key on a command with nothing after it.
    private var pasteForEmptyCommand = false
    /// Whether ⌘V in a draft takes the clipboard into it. False in apps that paste on ⌘V themselves
    /// whatever the input method does (terminals): the text would be pasted twice. There ⌃V, and the
    /// action key on a command with nothing after it, take the clipboard instead.
    public var pastesIntoDraft = true
    /// Whether secure input is on anywhere (set by the input controller). Nothing is sent to a model
    /// then: a terminal command doesn't start Claude Code, and its text stays in the draft. (The other
    /// commands are refused by the controller, which sends their requests.)
    public var secureInputActive: () -> Bool = { false }
    /// Confirmed text waiting for level two (an @ command, or any sentence in sentence mode).
    public private(set) var draft = ""
    /// Last known state of the level-one engine.
    public private(set) var engineState = EngineSnapshot.empty
    public private(set) var result = ConversionResult.empty
    public private(set) var voice = Voice.off
    /// Sentence mode (the original flow): text collects into a draft without an @ command too, and
    /// the action key improves it. Off: a regular input method, with drafts only for @ commands.
    public var sentenceMode: Bool
    /// In sentence mode, English-mode typing starts a draft (otherwise letters go to the application).
    public var englishAI: Bool
    /// Holding the right Option key records speech.
    public var voiceEnabled: Bool
    /// The key that sends the sentence to the model.
    public var actionKey: ActionKey
    /// The action key was pressed during dictation: the sentence goes once the transcript is final.
    public private(set) var actsAfterVoice = false
    /// Level one. Nil while the dictionaries are being prepared; keys then go to the application.
    public var engine: PinyinEngine? {
        didSet { engineState = engine?.snapshot() ?? .empty }
    }

    private var highlightOverride: Int?
    private var requestCounter = 0
    private var voiceCounter = 0
    /// The right Option key is down on its own and dictation hasn't started yet.
    private var voiceArmed = false
    /// Whether the voice key's events tell left and right Option apart (device bits).
    private var voiceKeySided = false
    /// When Shift went down with no other key since (nil once any key is pressed).
    private var shiftPressedAt: TimeInterval?
    /// Which Option key went down on its own, and when (nil once anything else happens).
    private var optionPressed: (keyCode: UInt16, at: TimeInterval)?
    private var warnedNotReady = false
    /// The draft was started by English-mode typing or English dictation.
    private var draftStartedLatin = false
    /// The last thing added to the draft was a transcript (Space then translates right away).
    private var draftEndsWithVoice = false

    public init(engine: PinyinEngine? = nil, sentenceMode: Bool = false, englishAI: Bool = true, voiceEnabled: Bool = true,
                actionKey: ActionKey = .enter) {
        self.engine = engine
        self.sentenceMode = sentenceMode
        self.englishAI = englishAI
        self.voiceEnabled = voiceEnabled
        self.actionKey = actionKey
        engineState = engine?.snapshot() ?? .empty
    }

    // MARK: - State for rendering

    public var isComposing: Bool { phase != .idle }

    public var isLevelTwo: Bool {
        switch phase {
        case .translating, .choosing, .failed: return true
        case .idle, .drafting: return false
        }
    }

    /// An English draft: started in English mode and still free of Chinese text. Keys that end
    /// typing (Return, Tab, arrows, Esc, shortcuts) insert it as typed and then reach the application;
    /// ⌘V instead takes the clipboard's text into the draft (`pasted`).
    public var isLatinDraft: Bool { draftStartedLatin && !draft.isEmpty && !draft.containsHan }

    /// Whether Space on the draft starts level two now. Only with the `space` action key (in English
    /// mode the first Space after a word is a space; right after dictation one Space is enough);
    /// otherwise Space in a draft is a space.
    public var spaceActs: Bool {
        actionKey == .space && (!engineState.isAsciiMode || draft.hasSuffix(" ") || draftEndsWithVoice)
    }

    /// Inline text: the draft followed by the engine's composition and any speech being recognized.
    public var markedText: String {
        if isLevelTwo { return draft }
        return draft + (engineState.isComposing ? engineState.preedit : "") + appendix(voice.text)
    }

    /// Caret position in `markedText`, in Characters.
    public var markedCursor: Int {
        if voice != .off { return markedText.count }
        guard !isLevelTwo, engineState.isComposing else { return draft.count }
        return draft.count + min(max(engineState.cursor, 0), engineState.preedit.count)
    }

    /// Level-two rows: "0" the sentence as typed, "1"–"3" the versions in the output language, then
    /// the rewrites in the configured styles, numbered on from 4. A rewrite is shown once it has fully
    /// arrived, and only if it changes the wording (not just punctuation) and repeats no other row.
    /// For `@question` / `@claude`: "0" the text sent and "1" the answer; for `@open`: the files found.
    public var choices: [Choice] {
        guard isLevelTwo else { return [] }
        switch activeCommand?.kind {
        case .search?:
            return searchResults.prefix(9).enumerated().map {
                Choice(label: String($0.offset + 1), kind: .file(path: $0.element.path), text: $0.element.name,
                       isComplete: true)
            }
        case .generate?, .run?:
            var out = [Choice(label: "0", kind: .original, text: sentText, isComplete: true)]
            if let line = result.versions.first {
                out.append(Choice(label: "1", kind: .answer, text: line.text, isComplete: line.isComplete))
            }
            return out
        case .convert?, .terminal?, nil:
            break
        }
        let original = sentText
        var out = [Choice(label: "0", kind: .original, text: original, isComplete: true)]
        var shownWordings: Set<String> = [original.wordingKey]
        var label = 1
        for line in result.versions {
            // A version that only re-punctuates the original or another version adds nothing.
            if line.isComplete, !shownWordings.insert(line.text.wordingKey).inserted { continue }
            out.append(Choice(label: String(label), kind: .version, text: line.text, isComplete: line.isComplete))
            label += 1
        }
        var next = 4
        for rewrite in result.rewrites where rewrite.line.isComplete && next <= 9 {
            let key = rewrite.line.text.wordingKey
            guard !key.isEmpty, shownWordings.insert(key).inserted else { continue }
            out.append(Choice(label: String(next), kind: .rewrite(rewrite.style), text: rewrite.line.text, isComplete: true))
            next += 1
        }
        return out
    }

    /// Index into `choices`. Defaults to the first main version, even before it has streamed in,
    /// so an early Space or Return never commits something else by accident.
    public var highlighted: Int {
        let all = choices
        if let highlightOverride { return all.isEmpty ? 0 : min(highlightOverride, all.count - 1) }
        if activeCommand?.kind == .search { return 0 }
        if case .translating = phase { return 1 }
        if let i = all.firstIndex(where: { $0.kind == .version || $0.kind == .answer }) { return i }
        if let i = all.firstIndex(where: { $0.kind.isRewrite }) { return i }
        return 0
    }

    /// What level two works on: the draft, or for a command draft ("@question 量子计算") the text after
    /// the command.
    public var sentText: String {
        Command.parse(draft, in: commands).map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) } ?? draft
    }

    /// The command at the start of the draft, once its name is complete ("@question …").
    public var draftCommand: Command? { Command.parse(draft, in: commands)?.command }

    /// While a command name is typed after "@" at the start of the draft: the letters so far.
    public var paletteQuery: String? {
        guard !isLevelTwo, voice == .off, !engineState.isComposing, draft.hasPrefix("@"),
              draft.dropFirst().allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }
        return String(draft.dropFirst())
    }

    /// Commands offered for `paletteQuery`, and the highlighted one.
    public var paletteMatches: [Command] { paletteQuery.map { Command.matching($0, in: commands) } ?? [] }
    public var paletteHighlighted: Int { min(paletteHighlight, max(paletteMatches.count - 1, 0)) }

    /// The `@open` text while it is typed, for results as you type (`receiveLive`).
    public var liveQuery: String? {
        guard !isLevelTwo, voice == .off, !engineState.isComposing, draftCommand == .open else { return nil }
        let query = sentText
        return query.isEmpty ? nil : query
    }

    /// The results as you type that belong to the current `liveQuery`.
    public var currentLiveResults: [SearchResult] {
        liveQuery != nil && liveResultsQuery == liveQuery ? liveResults : []
    }

    /// Files and apps for `query` (`liveQuery`): ↑↓ pick, Tab completes the path, the action key opens.
    public func receiveLive(_ results: [SearchResult], for query: String) -> [Effect] {
        guard query == liveQuery else { return [] }
        liveResults = results
        liveResultsQuery = query
        liveHighlight = 0
        return [.showPanel]
    }

    /// What ⌘C copies: the highlighted result (a file's path), if one is shown.
    public var copyableText: String? {
        if isLevelTwo {
            let all = choices
            guard all.indices.contains(highlighted), all[highlighted].isComplete, !all[highlighted].text.isEmpty else { return nil }
            if case let .file(path) = all[highlighted].kind { return path }
            return all[highlighted].text
        }
        let live = currentLiveResults
        return live.indices.contains(liveHighlight) ? live[liveHighlight].path : nil
    }

    /// Whether the candidate panel has something to show.
    public var wantsPanel: Bool {
        if isLevelTwo || voice != .off { return true }
        if engineState.isComposing { return !engineState.candidates.isEmpty }
        return !draft.isEmpty
    }

    // MARK: - Keys

    public func handleKeyDown(_ event: KeyEvent) -> Response {
        shiftPressedAt = nil
        optionPressed = nil  // ⌥ with a key is a shortcut, not a tap
        voiceArmed = false  // a key with right ⌥ down is an ⌥ shortcut, not dictation
        if isActionKey(event), let effects = actionKeyPressed() {
            draftEndsWithVoice = false
            return .consumed(effects)
        }
        let afterVoice = draftEndsWithVoice
        draftEndsWithVoice = false
        var prefix: [Effect] = []
        switch voice {
        case let .listening(id, _):
            // Any key while recording (an Option chord, or typing) cancels the recording.
            prefix = cancelVoice(id)
            if event.keyCode == VirtualKey.escape { return .consumed(prefix) }
        case let .finishing(id, text):
            // The final transcript hasn't arrived yet: keep what was recognized so far.
            if event.keyCode == VirtualKey.escape { return .consumed(cancelVoice(id)) }
            actsAfterVoice = false  // another key after the action key: not sending after all
            prefix = [.cancelVoice(id: id)] + voiceFinished(text, id: id)
        case .off:
            break
        }
        let response = dispatchKey(event, afterVoice: afterVoice || !prefix.isEmpty && draftEndsWithVoice)
        return Response(effects: prefix + response.effects, handled: response.handled)
    }

    private func dispatchKey(_ event: KeyEvent, afterVoice: Bool) -> Response {
        draftEndsWithVoice = false
        let modifiers = event.modifiers.subtracting(.capsLock)
        if modifiers == .command, event.charactersIgnoringModifiers.lowercased() == "c", let text = copyableText {
            return .consumed([.copy(text), .notice(messages.copied)])  // the result stays up
        }
        if modifiers == .command, event.charactersIgnoringModifiers.lowercased() == "v", let response = pasteIntoDraft() {
            return response
        }
        // ⌃V does the same in every app: none pastes on it by itself (terminals and Notes do on ⌘V,
        // whatever the input method does), so the text is pasted once, into the draft.
        if modifiers == .control, event.charactersIgnoringModifiers.lowercased() == "v",
           let response = pasteIntoDraft(evenWhereTheAppPastes: true) {
            return response
        }
        if modifiers.contains(.command) {
            // A shortcut with an English draft pending acts on the text as typed (⌘A, ⌘⏎ …).
            return isLatinDraft && !isLevelTwo ? Response(effects: commitAll(), handled: false) : .passThrough
        }
        if event.keyCode == VirtualKey.space, modifiers == [.shift] {
            // Typing English, Shift is often still down for the Space after a capital ("I am").
            if isLatinDraft && !isLevelTwo {
                return handleLevelOne(KeyEvent(keyCode: VirtualKey.space, characters: " "), afterVoice: afterVoice)
            }
            // English typed straight into the app (no draft): ⇧Space is the app's space.
            if engineState.isAsciiMode, draft.isEmpty, !isLevelTwo { return .passThrough }
            return toggleSentenceMode()
        }
        return isLevelTwo ? handleLevelTwo(event) : handleLevelOne(event, afterVoice: afterVoice)
    }

    /// Shift pressed and released on its own (within half a second, so holding Shift for a
    /// Shift-click selection doesn't count) switches the engine between Chinese and Latin input.
    /// Words already picked are kept and remaining letters are committed as typed (librime's
    /// `commit_code`). The right Option key held on its own records speech until it is released.
    /// With the `optionTap` action key, either Option key pressed and released on its own sends
    /// the sentence (a hold of the right one still dictates).
    /// The application always receives modifier changes as well. `timestamp` is in seconds.
    public func handleFlagsChanged(keyCode: UInt16, modifiers: KeyModifiers, timestamp: TimeInterval) -> [Effect] {
        if isOptionTap(keyCode: keyCode, modifiers: modifiers, timestamp: timestamp), actionKey == .optionTap,
           let effects = actionKeyPressed() {
            voiceArmed = false  // a tap of right ⌥, not a hold
            shiftPressedAt = nil
            return effects
        }
        if let effects = handleVoiceKey(keyCode: keyCode, modifiers: modifiers) { return effects }
        let isShift = keyCode == VirtualKey.leftShift || keyCode == VirtualKey.rightShift
        let others = modifiers.subtracting([.shift, .capsLock, .leftOption, .rightOption])
        if isShift, modifiers.contains(.shift), others.isEmpty {
            shiftPressedAt = timestamp
            return []
        }
        let toggle = isShift && !modifiers.contains(.shift)
            && shiftPressedAt.map { timestamp - $0 <= Self.shiftTapWindow } == true
        shiftPressedAt = nil
        return toggle && voice == .off ? toggleLatin() : []
    }

    static let shiftTapWindow: TimeInterval = 0.5
    /// Longest press of an Option key that still counts as a tap (`optionTap`). A hold of the right
    /// Option key turns into dictation sooner, after `voiceArmDelay`.
    static let optionTapWindow: TimeInterval = 0.5
    /// How long the right Option key must be held on its own before dictation starts (so ⌥
    /// shortcuts, ⌥-arrows and taps never touch the microphone).
    public static let voiceArmDelay: TimeInterval = 0.2

    /// Tracks the Option keys. True for the release of one that went down on its own and came back
    /// up within `optionTapWindow`, with no key or other modifier (including the other Option) between.
    private func isOptionTap(keyCode: UInt16, modifiers: KeyModifiers, timestamp: TimeInterval) -> Bool {
        let side: KeyModifiers
        switch keyCode {
        case VirtualKey.leftOption: side = .leftOption
        case VirtualKey.rightOption: side = .rightOption
        default:
            optionPressed = nil  // another modifier changed
            return false
        }
        let sided = !modifiers.isDisjoint(with: [.leftOption, .rightOption])
        let down = sided ? modifiers.contains(side) : modifiers.contains(.option)
        if down {
            let alone = modifiers.subtracting([.option, side, .capsLock]).isEmpty && optionPressed == nil
            optionPressed = alone ? (keyCode, timestamp) : nil
            return false
        }
        defer { optionPressed = nil }
        guard let pressed = optionPressed, pressed.keyCode == keyCode else { return false }
        return timestamp - pressed.at <= Self.optionTapWindow
    }

    /// The voice key: arms on press, dictation runs while it is held, stops on release. Nil for
    /// modifier changes that are for the Shift logic.
    private func handleVoiceKey(keyCode: UInt16, modifiers: KeyModifiers) -> [Effect]? {
        let sided = !modifiers.isDisjoint(with: [.leftOption, .rightOption])
        if case let .listening(id, text) = voice {
            // Released, also when the release itself went unseen (another modifier changed meanwhile).
            let released = voiceKeySided ? !modifiers.contains(.rightOption) : !modifiers.contains(.option)
            if released { return releaseVoice(id: id, text: text) }
            return keyCode == VirtualKey.rightOption ? [] : nil
        }
        guard keyCode == VirtualKey.rightOption else {
            voiceArmed = false  // another modifier joined in: not a hold on its own
            return nil
        }
        shiftPressedAt = nil
        let down = sided ? modifiers.contains(.rightOption) : modifiers.contains(.option)
        if down {
            let others = modifiers.subtracting([.option, .rightOption, .capsLock])
            guard others.isEmpty, voice == .off, voiceEnabled, engine != nil else {
                voiceArmed = false
                return []
            }
            voiceArmed = true
            voiceKeySided = sided
            return [.armVoice(delay: Self.voiceArmDelay)]
        }
        guard voiceArmed else { return [] }
        voiceArmed = false
        return [.notice(messages.holdToTalk)]  // released before dictation started: a tap
    }

    /// `voiceArmDelay` after `.armVoice`: starts dictation if the key is still held on its own
    /// (`stillHeld` false, e.g. its release went unseen or a mouse button is down, disarms).
    public func voiceHoldElapsed(stillHeld: Bool = true) -> [Effect] {
        guard voiceArmed, voice == .off else { return [] }
        voiceArmed = false
        return stillHeld ? startVoice() : []
    }

    /// A candidate clicked in the panel.
    public func choose(index: Int) -> [Effect] {
        if isLevelTwo { return commitChoice(at: index) }
        guard let engine, engineState.isComposing, engine.selectCandidate(onPage: index) else { return [] }
        return afterEngineChange(engine, effects: [], picked: true)
    }

    /// Switches level one to Chinese (pinyin) or English input, e.g. to the configured default.
    /// Ignored while something is being composed.
    public func setInputMode(_ language: Language) {
        guard let engine, !isComposing else { return }
        let latin = language == .english
        guard engine.snapshot().isAsciiMode != latin else { return }
        engine.setAsciiMode(latin)
        engineState = engine.snapshot()
    }

    // MARK: - Conversion feedback

    public func receive(_ newResult: ConversionResult, isFinal: Bool, id: Int) -> [Effect] {
        guard phase == .translating(id: id) else { return [] }
        result = newResult
        if isFinal {
            // Versions that only repeat the original are hidden, but the answer still counts.
            let answered = !result.versions.isEmpty || choices.contains { $0.kind != .original && !$0.text.isEmpty }
            phase = answered ? .choosing : .failed(messages.noResult)
        }
        return [.showPanel]
    }

    /// Files and apps found for `@open` (`.search`): shown to pick from, or "nothing found".
    public func receiveSearch(_ results: [SearchResult], id: Int) -> [Effect] {
        guard phase == .translating(id: id) else { return [] }
        searchResults = results
        phase = results.isEmpty ? .failed(messages.nothingFound) : .choosing
        return [.showPanel]
    }

    public func fail(_ message: String, id: Int) -> [Effect] {
        guard phase == .translating(id: id) else { return [] }
        phase = .failed(message)
        return [.showPanel]
    }

    // MARK: - Voice feedback

    /// Speech recognized so far (shown inline while recording).
    public func voiceText(_ text: String, id: Int) -> [Effect] {
        switch voice {
        case .listening(id, _): voice = .listening(id: id, text: text)
        case .finishing(id, _): voice = .finishing(id: id, text: text)
        default: return []
        }
        return [.updateMarkedText, .showPanel]
    }

    /// The final transcript: it continues the draft (one is pending, or sentence mode is on) or is
    /// inserted. If the action key was pressed during dictation, the sentence then goes to the model.
    public func voiceFinished(_ text: String, id: Int) -> [Effect] {
        guard voice.id == id else { return [] }
        voice = .off
        let translate = actsAfterVoice
        actsAfterVoice = false
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            setLevelOnePhase()
            return [.updateMarkedText, wantsPanel ? .showPanel : .hidePanel, .notice(messages.didNotHear)]
        }
        guard !draft.isEmpty || sentenceMode else {
            setLevelOnePhase()
            return [.commit(spoken), wantsPanel ? .showPanel : .hidePanel]
        }
        if draft.isEmpty { draftStartedLatin = engineState.isAsciiMode && !spoken.containsHan }
        draft += appendix(spoken)
        draftEndsWithVoice = true
        setLevelOnePhase()
        if translate { return startAction().effects }
        return [.updateMarkedText, .showPanel]
    }

    /// Recording or recognition failed (no microphone permission, model missing, …).
    public func voiceFailed(_ message: String, id: Int) -> [Effect] {
        guard voice.id == id else { return [] }
        voice = .off
        actsAfterVoice = false
        setLevelOnePhase()
        return [.updateMarkedText, wantsPanel ? .showPanel : .hidePanel, .notice(message)]
    }

    // MARK: - Ending the composition from outside

    /// The application ends the composition (focus change, click elsewhere, input source switch):
    /// everything pending is committed as converted text, including speech recognized so far.
    public func commitAll() -> [Effect] {
        var effects: [Effect] = []
        var spoken = ""
        if let id = voice.id {
            spoken = voice.text
            effects = cancelVoice(id, refresh: false)
        }
        var text = draft
        if !isLevelTwo, let engine, engine.snapshot().isComposing {
            text += engine.commitComposition() ?? ""
        }
        text += spoken.isEmpty ? "" : separator(before: spoken, after: text) + spoken
        return effects + finish(committing: text)
    }

    /// Commits everything exactly as typed (draft plus raw letters), without converting.
    /// Speech being recognized is dropped (this runs when a password field takes over).
    public func commitAsTyped() -> [Effect] {
        var effects: [Effect] = []
        if let id = voice.id { effects = cancelVoice(id, refresh: false) }
        var text = draft
        if !isLevelTwo, let engine, engine.snapshot().isComposing {
            text += engine.rawInput
        }
        return effects + finish(committing: text)
    }

    /// Re-reads the engine (e.g. after it became available).
    public func refreshEngineState() {
        engineState = engine?.snapshot() ?? .empty
    }

    // MARK: - Level one

    private func handleLevelOne(_ event: KeyEvent, afterVoice: Bool = false) -> Response {
        guard let engine else {
            guard event.printableText != nil, !warnedNotReady else { return .passThrough }
            warnedNotReady = true
            return Response(effects: [.notice(messages.notReady)], handled: false)
        }
        let composing = engine.snapshot().isComposing
        let modifiers = event.modifiers.subtracting(.capsLock)
        if !composing, let response = handlePaletteKey(event) { return response }
        // Return runs a command draft ("@question …"), like the action key; text keeps Return = as typed.
        if event.keyCode == VirtualKey.returnKey || event.keyCode == VirtualKey.keypadEnter, modifiers.isEmpty,
           draftCommand != nil, let effects = actionKeyPressed() {
            return .consumed(effects)
        }
        if !composing {
            if !draft.isEmpty, let response = handleDraftKey(event, afterVoice: afterVoice) { return response }
            if draft.isEmpty {
                // "@" first: the command palette ("@question …").
                if event.printableText == "@" {
                    draft = "@"
                    draftStartedLatin = true
                    paletteHighlight = 0
                    setLevelOnePhase()
                    return .consumed([.updateMarkedText, .showPanel])
                }
                // Shortcuts and Caps Lock typing go straight to the application when nothing is pending.
                if !modifiers.isDisjoint(with: [.control, .option]) { return .passThrough }
                if event.modifiers.contains(.capsLock) { return .passThrough }
            }
        }

        let pending = composing || !draft.isEmpty
        // rime-ice rejects every key carrying the Caps Lock mask (`good_old_caps_lock`), which would
        // freeze a composition in progress: keep editing it as if Caps Lock were off.
        var rimeEvent = event
        if composing { rimeEvent.modifiers.remove(.capsLock) }
        // ⇧Return is "as typed" (the action key may be Return): librime gets a plain Return.
        if event.keyCode == VirtualKey.returnKey || event.keyCode == VirtualKey.keypadEnter { rimeEvent.modifiers.remove(.shift) }
        guard let key = RimeKey.map(rimeEvent) else {
            // Characters librime has no key for (é, ß, other scripts) belong to the sentence too.
            if !composing, let text = event.printableText, takesIntoDraft(text) {
                appendTyped(text, afterVoice: afterVoice)
                return .consumed([.updateMarkedText, .showPanel])
            }
            return pending ? .consumed() : .passThrough
        }
        let isReturn = event.keyCode == VirtualKey.returnKey || event.keyCode == VirtualKey.keypadEnter
        let handled = engine.processKey(key.keycode, mask: key.mask)
        var effects: [Effect] = []
        if let committed = engine.takeCommit(), !committed.isEmpty {
            // Words picked from a composition (Space, digits, punctuation) belong to the sentence;
            // Return commits the letters as typed.
            effects += accept(committed, picked: composing && !isReturn)
        }
        engineState = engine.snapshot()
        var consumed = handled
        if !handled, !engineState.isComposing, let text = event.printableText, takesIntoDraft(text) {
            // Digits, Latin-mode letters etc. after Chinese text stay part of the sentence; in English
            // mode they can start one.
            appendTyped(text, afterVoice: afterVoice)
            consumed = true
        }
        setLevelOnePhase()
        if !consumed && (engineState.isComposing || !draft.isEmpty) {
            consumed = true  // keep the application from typing into the marked text
        }
        let committedDirectly = effects.contains { if case .commit = $0 { return true } else { return false } }
        if !consumed && !committedDirectly { return .passThrough }
        effects += [.updateMarkedText, wantsPanel ? .showPanel : .hidePanel]
        return Response(effects: effects, handled: consumed)
    }

    // MARK: - Paste

    /// The most text ⌘V puts into a draft, in Characters (a long paragraph; the answer grows with it).
    public static let maxPasteLength = 2000

    /// ⌘V or ⌃V with a draft pending ("@improve ", a command name being typed, a sentence-mode draft):
    /// the clipboard's text will join the draft instead of the document (`pasted`), so the action key
    /// then runs on it. Pinyin still being typed is converted first, and "@imp" picks its command. Nil
    /// without a draft, and after "@" alone (a mention): the key then does what it does in the app.
    /// ⌘V is left to apps that paste on it themselves (`pastesIntoDraft`); ⌃V works everywhere.
    private func pasteIntoDraft(evenWhereTheAppPastes: Bool = false) -> Response? {
        guard pastesIntoDraft || evenWhereTheAppPastes, !isLevelTwo, voice == .off, !draft.isEmpty else { return nil }
        if let query = paletteQuery, query.isEmpty || paletteMatches.isEmpty { return nil }
        var effects: [Effect] = []
        if paletteQuery != nil { _ = complete(paletteMatches) }  // the draft is now "@name "
        if let engine, engine.snapshot().isComposing { effects += convertComposition(engine) }
        setLevelOnePhase()
        return .consumed(effects + [.updateMarkedText, .showPanel, requestClipboard(forEmptyCommand: false)])
    }

    /// Asks for the clipboard's text (`pasted`); only the latest request counts.
    private func requestClipboard(forEmptyCommand: Bool) -> Effect {
        pasteCounter += 1
        pendingPaste = pasteCounter
        pasteForEmptyCommand = forEmptyCommand
        return .readClipboard(id: pasteCounter)
    }

    /// The clipboard's text for ⌘V `id` (nil: no text, or it may not be read): it continues the draft,
    /// as pasting continues a text. Dropped when the draft has been sent or cleared meanwhile.
    public func pasted(_ clipboard: String?, id: Int) -> [Effect] {
        guard pendingPaste == id else { return [] }
        pendingPaste = nil
        guard !isLevelTwo, voice == .off, !draft.isEmpty else { return [] }
        // Far too much is refused before it is looked at (this runs on the main thread).
        if let clipboard, clipboard.utf16.count > Self.maxPasteLength * 8 { return [.notice(messages.pasteTooLong)] }
        let text = clipboard.map(Self.oneLine) ?? ""
        guard !text.isEmpty else { return [.notice(pasteForEmptyCommand ? messages.typeAfterCommand : messages.nothingToPaste)] }
        guard text.count <= Self.maxPasteLength else { return [.notice(messages.pasteTooLong)] }
        draft += text
        setLevelOnePhase()
        return [.updateMarkedText, .showPanel]
    }

    /// Clipboard text as one line for the draft (the improve answer has one line per version): line
    /// breaks become spaces, or nothing between Chinese; control characters become spaces; the ends
    /// are trimmed.
    static func oneLine(_ text: String) -> String {
        var out = ""
        for line in text.components(separatedBy: .newlines) {
            let part = CandidateParser.stripControls(line).trimmingCharacters(in: .whitespaces)
            guard let first = part.first else { continue }
            if let last = out.last, !(isCJK(last) && isCJK(first)) { out += " " }
            out += part
        }
        return out
    }

    /// Chinese, Japanese and Korean characters and full-width punctuation: no space between lines of them.
    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return String(c).containsHan || (0x3000...0x30FF).contains(v) || (0xFF00...0xFFEF).contains(v)
            || (0xAC00...0xD7AF).contains(v)
    }

    // MARK: - Command palette

    /// Keys while a command name is typed after "@": letters narrow the list, Tab, Space, Return or a
    /// digit pick a command, ↑↓ move, ⌫ edits, Esc removes it. Any other key, or a letter no command
    /// starts with, inserts the "@…" as typed and then acts as usual, so "@name" mentions still reach
    /// the app. Nil outside the palette.
    private func handlePaletteKey(_ event: KeyEvent) -> Response? {
        guard let query = paletteQuery else { return nil }
        let matches = Command.matching(query, in: commands)
        let plain = event.modifiers.subtracting([.capsLock, .shift]).isEmpty
        switch event.keyCode {
        case VirtualKey.tab where plain:
            return matches.isEmpty ? commitPalette(then: event) : .consumed(complete(matches))
        case VirtualKey.space where plain:
            // "@ " is just an at sign and a space.
            return query.isEmpty || matches.isEmpty ? commitPalette(then: event) : .consumed(complete(matches))
        case VirtualKey.returnKey, VirtualKey.keypadEnter:
            // Picks, like Tab; "@" alone goes in as typed.
            return query.isEmpty || matches.isEmpty ? .consumed(finish(committing: draft)) : .consumed(complete(matches))
        case VirtualKey.escape:
            draft = ""
            setLevelOnePhase()
            return .consumed([.updateMarkedText, .hidePanel])
        case VirtualKey.delete where plain:
            draft.removeLast()
            paletteHighlight = 0
            setLevelOnePhase()
            return .consumed([.updateMarkedText, draft.isEmpty ? .hidePanel : .showPanel])
        case VirtualKey.up, VirtualKey.down:
            guard !matches.isEmpty else { return .consumed() }
            paletteHighlight = (paletteHighlighted + (event.keyCode == VirtualKey.up ? -1 : 1) + matches.count) % matches.count
            return .consumed([.showPanel])
        default:
            break
        }
        if plain, let text = event.printableText, text.count == 1, let c = text.first, c.isASCII {
            if c.isLetter, !Command.matching(query + text, in: commands).isEmpty {
                draft += text
                paletteHighlight = 0
                return .consumed([.updateMarkedText, .showPanel])
            }
            if let n = c.wholeNumberValue, matches.indices.contains(n - 1) {
                return .consumed(complete(matches, at: n - 1))
            }
        }
        return commitPalette(then: event)
    }

    /// Picks a palette command: the draft becomes "@name ", and the rest of the sentence follows.
    private func complete(_ matches: [Command], at index: Int? = nil) -> [Effect] {
        let command = matches[index ?? paletteHighlighted]
        draft = "@\(command.name) "
        paletteHighlight = 0
        // File names, paths and code are typed as letters; the input mode comes back when the command is done.
        if command.typesLatin, let engine, !engine.snapshot().isAsciiMode {
            engine.setAsciiMode(true)
            restoreChineseAfterOpen = true
            engineState = engine.snapshot()
        }
        setLevelOnePhase()
        return [.updateMarkedText, .showPanel]
    }

    /// Tab on an `@open` result: its path replaces what was typed (a folder's ends in "/", which lists it).
    private func completeLivePath() -> [Effect] {
        let live = currentLiveResults
        guard live.indices.contains(liveHighlight) else { return [] }
        let result = live[liveHighlight]
        draft = "@open " + (result.path as NSString).abbreviatingWithTildeInPath + (result.isFolder ? "/" : "")
        liveResults = []
        liveResultsQuery = nil
        liveHighlight = 0
        return [.updateMarkedText, .showPanel]
    }

    /// Leaves the palette: what was typed ("@", "@na") goes in as typed, then `event` acts as usual.
    private func commitPalette(then event: KeyEvent) -> Response {
        let typed = finish(committing: draft)
        let next = handleLevelOne(event)
        return Response(effects: typed + next.effects, handled: next.handled)
    }

    /// Whether typed text the engine passed on goes into the draft: it continues a draft, or in
    /// sentence mode starts an English one (English mode with `englishAI`; a leading space is just a space).
    private func takesIntoDraft(_ text: String) -> Bool {
        if !draft.isEmpty { return true }
        return sentenceMode && englishAI && engineState.isAsciiMode && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func appendTyped(_ text: String, afterVoice: Bool = false) {
        if draft.isEmpty { draftStartedLatin = engineState.isAsciiMode }
        draft += afterVoice ? appendix(text) : text  // "hello world" + "and" → "hello world and"
    }

    /// Keys with a meaning for the draft itself, when the engine has nothing left to convert.
    private func handleDraftKey(_ event: KeyEvent, afterVoice: Bool) -> Response? {
        let plain = event.modifiers.subtracting(.capsLock).isEmpty
        // A command draft ("@question …") isn't text to insert as typed: Esc clears it like a Chinese draft.
        let latin = isLatinDraft && draftCommand == nil
        let live = currentLiveResults
        if !live.isEmpty, plain {
            switch event.keyCode {
            case VirtualKey.up, VirtualKey.down:
                liveHighlight = (liveHighlight + (event.keyCode == VirtualKey.up ? -1 : 1) + live.count) % live.count
                return .consumed([.showPanel])
            case VirtualKey.tab:
                return .consumed(completeLivePath())
            default:
                break
            }
        }
        if latin, event.modifiers.contains(.control) {
            return commitDraftAndPassThrough()  // ⌃ shortcuts act on the text as typed
        }
        switch event.keyCode {
        case VirtualKey.space where plain && actionKey == .space:
            // In English (Latin) mode Space separates words; a second Space in a row translates.
            // Right after dictation the sentence is finished, so one Space does. (With the other
            // action keys, Space in a draft is just a space: it goes on below.)
            if engineState.isAsciiMode, !draft.hasSuffix(" "), !afterVoice {
                draft += " "
                return .consumed([.updateMarkedText, .showPanel])
            }
            return startAction()
        case VirtualKey.returnKey, VirtualKey.keypadEnter:
            return latin ? commitDraftAndPassThrough() : .consumed(finish(committing: draft))
        case VirtualKey.delete:
            if latin, event.modifiers.contains(.option) { return commitDraftAndPassThrough() }  // ⌥⌫ deletes a word
            draft.removeLast()
            setLevelOnePhase()
            return .consumed([.updateMarkedText, draft.isEmpty ? .hidePanel : .showPanel])
        case VirtualKey.escape:
            if latin { return commitDraftAndPassThrough() }  // never throws away what was typed
            draft = ""
            setLevelOnePhase()
            return .consumed([.updateMarkedText, .hidePanel])
        case VirtualKey.tab, VirtualKey.left, VirtualKey.right, VirtualKey.up, VirtualKey.down,
             VirtualKey.home, VirtualKey.end, VirtualKey.pageUp, VirtualKey.pageDown, VirtualKey.forwardDelete:
            return latin ? commitDraftAndPassThrough() : .consumed()
        default:
            return nil
        }
    }

    /// Inserts the draft as typed and lets the application handle the key as if nothing was pending.
    private func commitDraftAndPassThrough() -> Response {
        Response(effects: finish(committing: draft), handled: false)
    }

    /// Collects the engine's commit and new state after it processed something.
    private func afterEngineChange(_ engine: PinyinEngine, effects: [Effect], picked: Bool = false) -> [Effect] {
        var effects = effects
        if let committed = engine.takeCommit(), !committed.isEmpty {
            effects += accept(committed, picked: picked)
        }
        engineState = engine.snapshot()
        setLevelOnePhase()
        effects += [.updateMarkedText, wantsPanel ? .showPanel : .hidePanel]
        return effects
    }

    /// Engine output continues a draft (an @ command, or in sentence mode any sentence); in sentence
    /// mode Chinese text and anything picked from a composition (words, English words, emoji, dates)
    /// also start one, so the sentence stays whole. Otherwise it is inserted, as in any input method.
    private func accept(_ text: String, picked: Bool = false) -> [Effect] {
        if !draft.isEmpty || sentenceMode && (text.containsHan || picked) {
            if draft.isEmpty { draftStartedLatin = false }
            draft += text
            return []
        }
        return [.commit(text)]
    }

    private func setLevelOnePhase() {
        phase = draft.isEmpty && !engineState.isComposing && voice == .off ? .idle : .drafting
        if draft.isEmpty { draftStartedLatin = false }
        restoreInputModeAfterOpen()
    }

    /// Back to Chinese once the draft is no longer a command typed in letters (`@open`, code).
    private func restoreInputModeAfterOpen() {
        guard restoreChineseAfterOpen, draft.isEmpty || draftCommand?.typesLatin != true, let engine else { return }
        restoreChineseAfterOpen = false
        engine.setAsciiMode(false)
        engineState = engine.snapshot()
    }

    private func toggleLatin() -> [Effect] {
        guard let engine, !isLevelTwo else { return [] }
        let before = engine.snapshot()
        let latin = before.isAsciiMode
        let raw = engine.rawInput
        // librime's own Shift handling (rime-ice: `Shift_L: commit_code`) keeps the words already
        // picked and commits the remaining letters as typed. rime-ice ignores Shift_R, so Shift_L
        // stands for either key.
        _ = engine.processKey(RimeKey.shiftL, mask: 0)
        _ = engine.processKey(RimeKey.shiftL, mask: RimeKey.releaseMask)
        var effects: [Effect] = []
        if let committed = engine.takeCommit(), !committed.isEmpty {
            // Only the letters as typed: not a pick. Anything else includes picked candidates.
            effects += accept(committed, picked: before.isComposing && committed != raw)
        }
        if engine.snapshot().isAsciiMode == latin {
            // The schema has no Shift binding: switch directly, keeping the typed letters.
            if !latin, engine.snapshot().isComposing {
                let rest = engine.rawInput
                engine.clearComposition()
                if !rest.isEmpty { effects += accept(rest) }
            }
            engine.setAsciiMode(!latin)
        }
        effects = afterEngineChange(engine, effects: effects)
        return effects + [.notice(latin ? messages.chineseMode : messages.englishMode)]
    }

    private func toggleSentenceMode() -> Response {
        .consumed(setSentenceMode(!sentenceMode))
    }

    /// Sentence mode on or off (⇧Space or the menu): with it, text collects into a draft without an
    /// @ command, and the action key improves it. Turning it off inserts such a draft as is; an @
    /// command being typed stays.
    public func setSentenceMode(_ on: Bool) -> [Effect] {
        guard on != sentenceMode else { return [] }
        sentenceMode = on
        var effects: [Effect] = []
        if !on, !draft.isEmpty, draftCommand == nil, paletteQuery == nil, activeCommand == nil {
            if case .translating = phase { effects.append(.cancelConversion) }
            effects += [.hidePanel, .commit(draft)]
            draft = ""
            result = .empty
            highlightOverride = nil
            setLevelOnePhase()
            if engineState.isComposing || voice != .off { effects += [.updateMarkedText, .showPanel] }
        }
        return effects + [.sentenceModeChanged(on), .notice(on ? messages.sentenceModeOn : messages.sentenceModeOff)]
    }

    // MARK: - Voice

    private func startVoice() -> [Effect] {
        var effects: [Effect] = []
        if isLevelTwo { effects += backToDraft() }
        // "@q" + hold right ⌥: the command is picked, and the dictation is what follows it.
        if paletteQuery != nil, !paletteMatches.isEmpty { effects += complete(paletteMatches) }
        // Pinyin still being typed is converted first; the transcript follows it.
        if let engine, engine.snapshot().isComposing, let text = engine.commitComposition(), !text.isEmpty {
            effects += accept(text, picked: true)
            engineState = engine.snapshot()
        }
        voiceCounter += 1
        voice = .listening(id: voiceCounter, text: "")
        optionPressed = nil  // the hold became dictation: its release is not a tap
        actsAfterVoice = false
        setLevelOnePhase()
        let language: Language = engineState.isAsciiMode ? .english : .chinese
        // Start last: if it fails at once, its notice must not be hidden by these updates.
        return effects + [.updateMarkedText, .showPanel, .startVoice(id: voiceCounter, language: language)]
    }

    private func releaseVoice(id: Int, text: String) -> [Effect] {
        voice = .finishing(id: id, text: text)
        return [.stopVoice(id: id), .showPanel]
    }

    private func cancelVoice(_ id: Int, refresh: Bool = true) -> [Effect] {
        voice = .off
        actsAfterVoice = false
        guard refresh else { return [.cancelVoice(id: id)] }
        setLevelOnePhase()
        return [.cancelVoice(id: id), .updateMarkedText, wantsPanel ? .showPanel : .hidePanel]
    }

    /// `text` as it continues the draft: English words get a separating space.
    private func appendix(_ text: String) -> String {
        text.isEmpty ? "" : separator(before: text, after: draft) + text
    }

    private func separator(before text: String, after existing: String) -> String {
        guard let last = existing.last, let first = text.first else { return "" }
        let wordy: (Character) -> Bool = { $0.isLetter && !String($0).containsHan || $0.isNumber }
        return (wordy(last) || ".,!?;:".contains(last)) && wordy(first) ? " " : ""
    }

    // MARK: - Level two

    private func handleLevelTwo(_ event: KeyEvent) -> Response {
        switch event.keyCode {
        case VirtualKey.space:
            return .consumed(acceptInLevelTwo())
        case VirtualKey.returnKey, VirtualKey.keypadEnter:
            // Like Space: the highlighted row (row 0 is the sentence as typed). After a failure
            // nothing is highlighted, and Return keeps the sentence as typed (as the Return action
            // key it retries instead, before reaching here).
            if case .failed = phase { return .consumed(finish(committing: sentText)) }
            return .consumed(commitChoice(at: highlighted))
        case VirtualKey.escape, VirtualKey.delete:
            return .consumed(backToDraft())
        case VirtualKey.up, VirtualKey.pageUp:
            return .consumed(moveHighlight(by: -1))
        case VirtualKey.down, VirtualKey.pageDown:
            return .consumed(moveHighlight(by: 1))
        case VirtualKey.tab:
            return .consumed(moveHighlight(by: event.modifiers.contains(.shift) ? -1 : 1))
        case VirtualKey.left, VirtualKey.right, VirtualKey.home, VirtualKey.end, VirtualKey.forwardDelete:
            return .consumed()
        default:
            break
        }
        guard let text = event.printableText else { return .consumed() }
        if text.count == 1, let c = text.first, c.isASCII, c.isNumber {
            guard let index = choices.firstIndex(where: { $0.label == text }) else { return .consumed() }
            return .consumed(commitChoice(at: index))
        }
        // Typing more: back to the draft and continue the sentence with this key.
        let back = backToDraft()
        let next = handleLevelOne(event)
        return .consumed(back + next.effects)
    }

    private func startAction() -> Response {
        let parsed = Command.parse(draft, in: commands)
        let input = sentText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A command with nothing after it takes the clipboard's text (shown in the draft first; the
        // action key again runs it). This works where ⌘V can't (terminals paste on their own).
        if input.isEmpty, parsed != nil, !isLevelTwo { return .consumed([requestClipboard(forEmptyCommand: true)]) }
        guard !input.isEmpty else { return parsed == nil ? .consumed() : .consumed([.notice(messages.typeAfterCommand)]) }
        if let command = parsed?.command, let program = missingPrograms[command.name] {
            let message = command == .claude ? messages.claudeNotInstalled
                : messages.notInstalled.replacingOccurrences(of: "{program}", with: program)
            return .consumed([.updateMarkedText, .notice(message)])
        }
        if let command = parsed?.command, command.kind == .terminal {
            guard !secureInputActive() else {
                return .consumed([.updateMarkedText, .notice(command.custom == nil ? messages.secureInputTerminal : messages.secureInputCommand)])
            }
            // The session runs in its own window: nothing to wait for or insert here.
            if let custom = command.custom {
                return .consumed(finish(committing: "") + [.launchInTerminal(argv: custom.arguments(for: input)),
                                                           .notice(messages.ranInTerminal)])
            }
            return .consumed(finish(committing: "") + [.runInTerminal(prompt: input), .notice(messages.openedTerminal)])
        }
        requestCounter += 1
        phase = .translating(id: requestCounter)
        result = .empty
        searchResults = []
        highlightOverride = nil
        activeCommand = parsed?.command
        let start: Effect
        switch parsed?.command {
        case let command? where command.kind == .generate: start = .startCommand(command, input: input, id: requestCounter)
        case let command? where command.kind == .run: start = .startRun(command, input: input, id: requestCounter)
        case .open?: start = .search(query: input, id: requestCounter)
        default: start = .startConversion(input: input, id: requestCounter)
        }
        return .consumed([start, .updateMarkedText, .showPanel])
    }

    // MARK: - Action key

    /// ⌥Space, when that is the action key (an Option tap arrives as modifier changes instead).
    /// The action key as a key press: Return, or ⌥Space (an Option tap arrives as modifier changes).
    /// While right ⌥ is held for dictation, Return arrives as ⌥Return.
    private func isActionKey(_ event: KeyEvent) -> Bool {
        let modifiers = event.modifiers.subtracting(.capsLock)
        switch actionKey {
        case .enter:
            let listening: Bool
            if case .listening = voice { listening = true } else { listening = false }
            return (event.keyCode == VirtualKey.returnKey || event.keyCode == VirtualKey.keypadEnter)
                && (modifiers.isEmpty || listening && modifiers == .option)
        case .optionSpace:
            return event.keyCode == VirtualKey.space && modifiers == .option
        case .optionTap, .space:
            return false
        }
    }

    /// The action key: pinyin still being typed is converted as Space would pick it, then the draft
    /// runs (its @ command, or in sentence mode the improve conversion). In level two it accepts like
    /// Space; during dictation the sentence goes once the transcript is final. Nil when there is
    /// nothing to run: without an @ command (and outside sentence mode) the key is the app's, as in
    /// any input method.
    private func actionKeyPressed() -> [Effect]? {
        guard let engine else { return nil }
        if isLevelTwo { return acceptInLevelTwo() }
        if paletteQuery != nil { return paletteMatches.isEmpty ? nil : complete(paletteMatches) }
        guard draftCommand != nil || sentenceMode else { return nil }
        if voice != .off { return actAfterVoice() }
        // @open with results as you type: open the highlighted one right away.
        let live = currentLiveResults
        if live.indices.contains(liveHighlight) { return finish(committing: "") + [.open(path: live[liveHighlight].path)] }
        let composing = engine.snapshot().isComposing
        guard composing || !draft.isEmpty else { return nil }
        let effects = composing ? convertComposition(engine) : []
        setLevelOnePhase()
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return effects + [.updateMarkedText, wantsPanel ? .showPanel : .hidePanel]
        }
        return effects + startAction().effects
    }

    /// The action key during dictation: recording stops (as if the key was released) and the
    /// sentence goes to the model as soon as the final transcript is in.
    private func actAfterVoice() -> [Effect] {
        actsAfterVoice = true
        if case let .listening(id, text) = voice { return releaseVoice(id: id, text: text) }
        return [.showPanel]
    }

    private static let maxPicks = 16

    /// Picks the highlighted candidate as Space would until no pinyin is left (a long input can take
    /// several picks); the words go to the draft.
    private func convertComposition(_ engine: PinyinEngine) -> [Effect] {
        var effects: [Effect] = []
        for _ in 0..<Self.maxPicks {
            let before = engine.snapshot()
            guard before.isComposing else { break }
            _ = engine.processKey(RimeKey.space, mask: 0)
            let committed = engine.takeCommit() ?? ""
            if !committed.isEmpty { effects += accept(committed, picked: true) }
            if committed.isEmpty, engine.snapshot() == before { break }  // Space picks nothing here
        }
        // Whatever Space didn't convert goes in the way the engine commits a composition.
        if engine.snapshot().isComposing, let rest = engine.commitComposition(), !rest.isEmpty {
            effects += accept(rest, picked: true)
        }
        engineState = engine.snapshot()
        return effects
    }

    /// Space (or the action key) in level two: inserts the highlighted line once it is complete;
    /// after a failure, asks again.
    private func acceptInLevelTwo() -> [Effect] {
        if case .failed = phase { return startAction().effects }
        return commitChoice(at: highlighted)
    }

    private func backToDraft() -> [Effect] {
        var effects: [Effect] = []
        if case .translating = phase { effects.append(.cancelConversion) }
        result = .empty
        searchResults = []
        activeCommand = nil
        highlightOverride = nil
        setLevelOnePhase()
        return effects + [.updateMarkedText, wantsPanel ? .showPanel : .hidePanel]
    }

    private func commitChoice(at index: Int) -> [Effect] {
        let all = choices
        guard all.indices.contains(index), all[index].isComplete, !all[index].text.isEmpty else { return [] }
        if case let .file(path) = all[index].kind { return finish(committing: "") + [.open(path: path)] }
        return finish(committing: all[index].text)
    }

    private func moveHighlight(by delta: Int) -> [Effect] {
        let count = choices.count
        guard count > 0 else { return [] }
        let current = min(highlighted, count - 1)
        highlightOverride = (current + delta + count) % count
        return [.showPanel]
    }

    /// Ends the composition, inserting `text`, and clears the engine.
    private func finish(committing text: String) -> [Effect] {
        var effects: [Effect] = []
        if case .translating = phase { effects.append(.cancelConversion) }
        if let id = voice.id { effects += cancelVoice(id, refresh: false) }
        engine?.clearComposition()
        engineState = engine?.snapshot() ?? .empty
        draft = ""
        draftStartedLatin = false
        draftEndsWithVoice = false
        actsAfterVoice = false
        result = .empty
        searchResults = []
        activeCommand = nil
        paletteHighlight = 0
        pendingPaste = nil  // a paste still on its way is dropped
        liveResults = []
        liveResultsQuery = nil
        liveHighlight = 0
        highlightOverride = nil
        phase = .idle
        restoreInputModeAfterOpen()
        effects.append(.hidePanel)
        effects.append(text.isEmpty ? .updateMarkedText : .commit(text))
        return effects
    }
}
