import Foundation

/// Two-level input state machine.
///
/// Level one is a local pinyin engine (Rime): typing, selecting and committing words works like any
/// pinyin input method. With AI on, text the engine commits is collected into a *draft* (shown inline,
/// not yet in the document) instead of being inserted. In English mode, typed letters can start a
/// draft too (`englishAI`), and holding the right Option key dictates into the draft. The translate
/// key (`TranslateKey`: an Option tap by default, ⌥Space, or Space on a finished draft) starts level
/// two: pinyin still being typed is converted first, then the sentence goes to the model, which
/// streams three versions in the output language and rewrites in the configured styles.
///
///     idle ─letters / voice─▶ drafting ─translate key─▶ translating ─final─▶ choosing
///      ▲               │   ▲ ◀──────────── Esc / ⌫ / typing more ────────────────────────┘ │
///      └── ⏎ commits draft ┘ ◀──────────────── Space / digits / ⏎ commit ──────────────────┘
///
/// The selection key (`selectionKey`: the translate key, or ⌥Space when that is Space) with nothing
/// being composed sends the text selected in the document (read by the controller, see `Selection`)
/// straight to level two. The selection stays in the document, untouched, until a line is chosen,
/// which then replaces it (`replaceSelection`); Esc, 0 and anything that ends the composition leave
/// it exactly as it was.
///
/// With AI off, level one behaves like a plain Rime input method (commits go straight to the document).
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

    /// What is selected in the document when the selection key is pressed with nothing being composed.
    public enum Selection: Equatable, Sendable {
        /// Nothing is selected (or the application doesn't say): the key goes on as usual.
        case none
        /// The selected text, without surrounding whitespace (see `trimSelection`). Blank text (the
        /// controller sends it for a selected empty line) is refused with a notice, like the cases
        /// below: only `none` lets ⌥Space reach the application.
        case text(String)
        /// Text is selected, but the application doesn't hand all of it over.
        case unreadable
        /// More is selected than `maxSelectionLength`.
        case tooLong
    }

    public enum Effect: Equatable, Sendable {
        /// Re-render the inline marked text from `markedText` / `markedCursor`.
        case updateMarkedText
        /// Insert text into the document, replacing the marked text.
        case commit(String)
        /// Replace the selected text that was sent with this (only if it is still selected and unchanged).
        case replaceSelection(String)
        case startConversion(input: String, id: Int)
        case cancelConversion
        /// Show or refresh the candidate panel.
        case showPanel
        case hidePanel
        /// Briefly show a status message near the caret.
        case notice(String)
        /// The AI setting was toggled; persist it.
        case aiModeChanged(Bool)
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
            /// A rewrite in the sentence's own language; the value is the style name ("简洁", …).
            case rewrite(String)

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
        public var aiOn: String
        public var aiOff: String
        public var noResult: String
        /// Selected text that can't be sent (the selection key is consumed, so nothing types over it).
        public var selectionNeedsAI: String
        public var selectionUnreadable: String
        public var selectionTooLong: String
        public var selectionBlank: String
        public var selectionMultiline: String
        public var selectionAttachment: String

        public static let chinese = Messages(
            notReady: "词库准备中，稍候可用", holdToTalk: "按住右 ⌥ 说话", didNotHear: "没听清，再说一次",
            chineseMode: "中", englishMode: "英", aiOn: "AI 翻译：开", aiOff: "AI 翻译：关", noResult: "没有得到结果",
            selectionNeedsAI: "AI 翻译已关（⇧空格开启）", selectionUnreadable: "读不到选中的文字（这个应用不支持）",
            selectionTooLong: "选中的文字太长：最多 \(Composer.maxSelectionLength) 字", selectionBlank: "选中的只有空格或换行",
            selectionMultiline: "选中的文字跨了几行：一次选一段", selectionAttachment: "选中的内容里有图片或附件：只能改文字")
        public static let english = Messages(
            notReady: "Loading the dictionaries, one moment", holdToTalk: "Hold right ⌥ to talk",
            didNotHear: "Didn't catch that, try again", chineseMode: "Chinese", englishMode: "English",
            aiOn: "AI: on", aiOff: "AI: off", noResult: "No result",
            selectionNeedsAI: "AI is off (⇧Space turns it on)", selectionUnreadable: "Can't read the selected text (this app doesn't share it)",
            selectionTooLong: "Too much selected: \(Composer.maxSelectionLength) characters at most",
            selectionBlank: "Only spaces or line breaks are selected",
            selectionMultiline: "The selection spans several lines: select one paragraph",
            selectionAttachment: "The selection has an image or attachment: only text can be rewritten")
    }
    /// Confirmed text waiting for level two (AI mode only).
    public private(set) var draft = ""
    /// Last known state of the level-one engine.
    public private(set) var engineState = EngineSnapshot.empty
    public private(set) var result = ConversionResult.empty
    public private(set) var voice = Voice.off
    /// Level two is working on text selected in the document (⌥Space). That text stays where it is,
    /// untouched and not marked, until a line is chosen.
    public private(set) var replacesSelection = false
    public var aiEnabled: Bool
    /// With AI on, English-mode typing starts a draft (otherwise letters go to the application).
    public var englishAI: Bool
    /// Holding the right Option key records speech.
    public var voiceEnabled: Bool
    /// The key that sends the sentence to the model.
    public var translateKey: TranslateKey
    /// The translate key was pressed during dictation: the sentence goes once the transcript is final.
    public private(set) var translatesAfterVoice = false
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

    public init(engine: PinyinEngine? = nil, aiEnabled: Bool = true, englishAI: Bool = true, voiceEnabled: Bool = true,
                translateKey: TranslateKey = .optionTap) {
        self.engine = engine
        self.aiEnabled = aiEnabled
        self.englishAI = englishAI
        self.voiceEnabled = voiceEnabled
        self.translateKey = translateKey
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
    /// typing (Return, Tab, arrows, Esc, shortcuts) insert it as typed and then reach the application.
    public var isLatinDraft: Bool { draftStartedLatin && !draft.isEmpty && !draft.containsHan }

    /// Whether Space on the draft starts level two now. Only with the `space` translate key (in English
    /// mode the first Space after a word is a space; right after dictation one Space is enough);
    /// otherwise Space in a draft is a space.
    public var spaceTranslates: Bool {
        translateKey == .space && (!engineState.isAsciiMode || draft.hasSuffix(" ") || draftEndsWithVoice)
    }

    /// Inline text: the draft followed by the engine's composition and any speech being recognized.
    /// Nothing while converting selected text (the selection itself shows what is being converted).
    public var markedText: String {
        if replacesSelection { return "" }
        if isLevelTwo { return draft }
        return draft + (engineState.isComposing ? engineState.preedit : "") + appendix(voice.text)
    }

    /// Caret position in `markedText`, in Characters.
    public var markedCursor: Int {
        if voice != .off || replacesSelection { return markedText.count }
        guard !isLevelTwo, engineState.isComposing else { return draft.count }
        return draft.count + min(max(engineState.cursor, 0), engineState.preedit.count)
    }

    /// Level-two rows: "0" the sentence as typed, "1"–"3" the versions in the output language, then
    /// the rewrites in the configured styles, numbered on from 4. A rewrite is shown once it has fully
    /// arrived, and only if it changes the wording (not just punctuation) and repeats no other row.
    public var choices: [Choice] {
        guard isLevelTwo else { return [] }
        var out = [Choice(label: "0", kind: .original, text: draft, isComplete: true)]
        var shownWordings: Set<String> = [draft.wordingKey]
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
        if case .translating = phase { return 1 }
        if let i = all.firstIndex(where: { $0.kind == .version }) { return i }
        if let i = all.firstIndex(where: { $0.kind.isRewrite }) { return i }
        return 0
    }

    /// Whether the candidate panel has something to show.
    public var wantsPanel: Bool {
        if isLevelTwo || voice != .off { return true }
        if engineState.isComposing { return !engineState.candidates.isEmpty }
        return !draft.isEmpty
    }

    // MARK: - Keys

    /// `selection` reads what is selected in the document; it is only called for the selection key
    /// (when that is ⌥Space) with nothing being composed.
    public func handleKeyDown(_ event: KeyEvent, selection: () -> Selection = { .none }) -> Response {
        shiftPressedAt = nil
        optionPressed = nil  // ⌥ with a key is a shortcut, not a tap
        voiceArmed = false  // a key with right ⌥ down is an ⌥ shortcut, not dictation
        if isTranslateKey(event), let effects = translateKeyPressed() {
            draftEndsWithVoice = false
            return .consumed(effects)
        }
        // A key that ends a dictation (⌥Space while right ⌥ is held) is not about selected text.
        let selection = phase == .idle ? selection : { .none }
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
            translatesAfterVoice = false  // another key after the translate key: not sending after all
            prefix = [.cancelVoice(id: id)] + voiceFinished(text, id: id)
        case .off:
            break
        }
        let response = dispatchKey(event, afterVoice: afterVoice || !prefix.isEmpty && draftEndsWithVoice,
                                   selection: selection)
        return Response(effects: prefix + response.effects, handled: response.handled)
    }

    private func dispatchKey(_ event: KeyEvent, afterVoice: Bool, selection: () -> Selection) -> Response {
        draftEndsWithVoice = false
        let modifiers = event.modifiers.subtracting(.capsLock)
        if modifiers.contains(.command) {
            // ⌘C, ⌘X, ⌘Z … act on the selected text itself: stop converting it (nothing is replaced later).
            if replacesSelection { return Response(effects: finish(committing: ""), handled: false) }
            // A shortcut with an English draft pending acts on the text as typed (⌘A, ⌘⏎ …).
            return isLatinDraft && !isLevelTwo ? Response(effects: commitAll(), handled: false) : .passThrough
        }
        // Selected text needs no pinyin engine, so this works while the dictionaries are prepared too.
        if event.keyCode == VirtualKey.space, modifiers == [.option], selectionKey == .optionSpace, phase == .idle,
           let response = convertSelection(selection()) {
            return response
        }
        if event.keyCode == VirtualKey.space, modifiers == [.shift] {
            // Typing English, Shift is often still down for the Space after a capital ("I am").
            if isLatinDraft && !isLevelTwo {
                return handleLevelOne(KeyEvent(keyCode: VirtualKey.space, characters: " "), afterVoice: afterVoice)
            }
            return toggleAI()
        }
        return isLevelTwo ? handleLevelTwo(event) : handleLevelOne(event, afterVoice: afterVoice)
    }

    /// Shift pressed and released on its own (within half a second, so holding Shift for a
    /// Shift-click selection doesn't count) switches the engine between Chinese and Latin input.
    /// Words already picked are kept and remaining letters are committed as typed (librime's
    /// `commit_code`). The right Option key held on its own records speech until it is released.
    /// With the `optionTap` translate key, either Option key pressed and released on its own sends
    /// the sentence (a hold of the right one still dictates), or with nothing being composed the
    /// selected text (`selection` is only called then).
    /// The application always receives modifier changes as well. `timestamp` is in seconds.
    public func handleFlagsChanged(keyCode: UInt16, modifiers: KeyModifiers, timestamp: TimeInterval,
                                   selection: () -> Selection = { .none }) -> [Effect] {
        if isOptionTap(keyCode: keyCode, modifiers: modifiers, timestamp: timestamp), translateKey == .optionTap,
           let effects = translateKeyPressed() ?? (phase == .idle ? convertSelection(selection())?.effects : nil) {
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

    /// The final transcript: it continues the draft (AI on) or is inserted (AI off). If the translate
    /// key was pressed during dictation, the sentence then goes to the model.
    public func voiceFinished(_ text: String, id: Int) -> [Effect] {
        guard voice.id == id else { return [] }
        voice = .off
        let translate = translatesAfterVoice
        translatesAfterVoice = false
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            setLevelOnePhase()
            return [.updateMarkedText, wantsPanel ? .showPanel : .hidePanel, .notice(messages.didNotHear)]
        }
        guard aiEnabled else {
            setLevelOnePhase()
            return [.commit(spoken), wantsPanel ? .showPanel : .hidePanel]
        }
        if draft.isEmpty { draftStartedLatin = engineState.isAsciiMode && !spoken.containsHan }
        draft += appendix(spoken)
        draftEndsWithVoice = true
        setLevelOnePhase()
        if translate { return startTranslation().effects }
        return [.updateMarkedText, .showPanel]
    }

    /// Recording or recognition failed (no microphone permission, model missing, …).
    public func voiceFailed(_ message: String, id: Int) -> [Effect] {
        guard voice.id == id else { return [] }
        voice = .off
        translatesAfterVoice = false
        setLevelOnePhase()
        return [.updateMarkedText, wantsPanel ? .showPanel : .hidePanel, .notice(message)]
    }

    // MARK: - Ending the composition from outside

    /// The application ends the composition (focus change, click elsewhere, input source switch):
    /// everything pending is committed as converted text, including speech recognized so far.
    /// Selected text being converted is left as it is.
    public func commitAll() -> [Effect] {
        if replacesSelection { return finish(committing: "") }
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
        if replacesSelection { return finish(committing: "") }
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

    // MARK: - Selected text

    /// The most selected text one press sends to the model, in Characters.
    public static let maxSelectionLength = 500

    /// The key that sends selected text: the translate key, or ⌥Space when that is Space (Space on
    /// selected text types over it, as in any text field).
    public var selectionKey: TranslateKey { translateKey == .optionTap ? .optionTap : .optionSpace }

    /// The selection key with nothing being composed: the selected text goes to the model right away
    /// (it stays selected in the document meanwhile). Nil when nothing usable is selected: the key then
    /// does what it does otherwise (⌥Space reaches the application, a tap of right ⌥ hints at dictation).
    private func convertSelection(_ selection: Selection) -> Response? {
        guard selection != .none else { return nil }
        // Text is selected: from here on ⌥Space must not reach the application, which would replace it.
        guard aiEnabled else { return .consumed([.notice(messages.selectionNeedsAI)]) }
        guard case let .text(text) = selection else {
            return .consumed([.notice(selection == .tooLong ? messages.selectionTooLong : messages.selectionUnreadable)])
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .consumed([.notice(messages.selectionBlank)])
        }
        guard text.count <= Self.maxSelectionLength else { return .consumed([.notice(messages.selectionTooLong)]) }
        // One paragraph: the model answers one line per version.
        guard !text.contains(where: \.isNewline) else { return .consumed([.notice(messages.selectionMultiline)]) }
        // An image, file or tag in the text can't go to the model, and replacing would delete it.
        guard !text.unicodeScalars.contains(Self.attachmentCharacter) else {
            return .consumed([.notice(messages.selectionAttachment)])
        }
        draft = text
        draftStartedLatin = false
        replacesSelection = true
        return startTranslation()
    }

    /// What text fields hand over for an inline attachment (NSTextAttachment.character). Checked per
    /// scalar: a combining mark after it would make it part of a larger Character.
    static let attachmentCharacter: Unicode.Scalar = "\u{FFFC}"

    /// `text` without leading and trailing whitespace and line breaks, and where that part is in
    /// `text` (UTF-16 offset and length, as IMK ranges count): only that part is replaced, so a
    /// selection that took in the line break after it (triple-click) keeps it. Nil when `text` isn't
    /// well-formed UTF-16 (the selection splits a character, e.g. half of an emoji).
    public static func trimSelection(_ text: String) -> (text: String, offset: Int, length: Int)? {
        let string = text as NSString
        guard isWellFormedUTF16(string) else { return nil }
        let visible = CharacterSet.whitespacesAndNewlines.inverted
        let first = string.rangeOfCharacter(from: visible)
        guard first.location != NSNotFound else { return ("", 0, 0) }
        let last = string.rangeOfCharacter(from: visible, options: .backwards)
        guard last.location != NSNotFound, NSMaxRange(last) > first.location else { return nil }
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        return (string.substring(with: range), range.location, range.length)
    }

    /// Whether every surrogate in `string` is half of a pair.
    static func isWellFormedUTF16(_ string: NSString) -> Bool {
        var i = 0
        while i < string.length {
            let unit = string.character(at: i)
            if UTF16.isLeadSurrogate(unit) {
                guard i + 1 < string.length, UTF16.isTrailSurrogate(string.character(at: i + 1)) else { return false }
                i += 2
            } else if UTF16.isTrailSurrogate(unit) {
                return false
            } else {
                i += 1
            }
        }
        return true
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
        if !composing {
            if !draft.isEmpty, let response = handleDraftKey(event, afterVoice: afterVoice) { return response }
            if draft.isEmpty {
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

    /// Whether typed text the engine passed on goes into the draft: it continues a draft, or starts
    /// an English one (English mode with `englishAI`; a leading space is just a space).
    private func takesIntoDraft(_ text: String) -> Bool {
        guard aiEnabled else { return false }
        if !draft.isEmpty { return true }
        return englishAI && engineState.isAsciiMode && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func appendTyped(_ text: String, afterVoice: Bool = false) {
        if draft.isEmpty { draftStartedLatin = engineState.isAsciiMode }
        draft += afterVoice ? appendix(text) : text  // "hello world" + "and" → "hello world and"
    }

    /// Keys with a meaning for the draft itself, when the engine has nothing left to convert.
    private func handleDraftKey(_ event: KeyEvent, afterVoice: Bool) -> Response? {
        let plain = event.modifiers.subtracting(.capsLock).isEmpty
        let latin = isLatinDraft
        if latin, event.modifiers.contains(.control) {
            return commitDraftAndPassThrough()  // ⌃ shortcuts act on the text as typed
        }
        switch event.keyCode {
        case VirtualKey.space where plain && translateKey == .space:
            // In English (Latin) mode Space separates words; a second Space in a row translates.
            // Right after dictation the sentence is finished, so one Space does. (With the other
            // translate keys, Space in a draft is just a space: it goes on below.)
            if engineState.isAsciiMode, !draft.hasSuffix(" "), !afterVoice {
                draft += " "
                return .consumed([.updateMarkedText, .showPanel])
            }
            return startTranslation()
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

    /// Engine output goes to the draft in AI mode: Chinese text, anything after it, and anything
    /// picked from a composition (words, English words, emoji, dates), so the sentence stays whole.
    /// Punctuation or letters committed with Return when nothing is pending are inserted directly.
    private func accept(_ text: String, picked: Bool = false) -> [Effect] {
        if aiEnabled && (!draft.isEmpty || text.containsHan || picked) {
            if draft.isEmpty { draftStartedLatin = false }
            draft += text
            return []
        }
        return [.commit(text)]
    }

    private func setLevelOnePhase() {
        phase = draft.isEmpty && !engineState.isComposing && voice == .off ? .idle : .drafting
        if draft.isEmpty { draftStartedLatin = false }
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

    private func toggleAI() -> Response {
        .consumed(setAI(!aiEnabled))
    }

    /// Turns level two on or off (⇧Space or the menu). Turning it off inserts a pending draft as is
    /// (selected text being converted is left as it is).
    public func setAI(_ on: Bool) -> [Effect] {
        guard on != aiEnabled else { return [] }
        aiEnabled = on
        var effects: [Effect] = []
        if !on, replacesSelection {
            effects = finish(committing: "")
        } else if !on, !draft.isEmpty {
            if case .translating = phase { effects.append(.cancelConversion) }
            effects += [.hidePanel, .commit(draft)]
            draft = ""
            result = .empty
            highlightOverride = nil
            setLevelOnePhase()
            if engineState.isComposing || voice != .off { effects += [.updateMarkedText, .showPanel] }
        }
        return effects + [.aiModeChanged(on), .notice(on ? messages.aiOn : messages.aiOff)]
    }

    // MARK: - Voice

    private func startVoice() -> [Effect] {
        var effects: [Effect] = []
        if isLevelTwo { effects += backToDraft() }
        // Pinyin still being typed is converted first; the transcript follows it.
        if let engine, engine.snapshot().isComposing, let text = engine.commitComposition(), !text.isEmpty {
            effects += accept(text, picked: true)
            engineState = engine.snapshot()
        }
        voiceCounter += 1
        voice = .listening(id: voiceCounter, text: "")
        optionPressed = nil  // the hold became dictation: its release is not a tap
        translatesAfterVoice = false
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
        translatesAfterVoice = false
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
            // nothing is highlighted, and Return keeps the sentence as typed (selected text: as it is).
            if case .failed = phase { return .consumed(finish(committing: replacesSelection ? "" : draft)) }
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
        // Typing more: back to the draft and continue the sentence with this key. On selected text
        // the key then does what it does with nothing pending (typing replaces the selection, as anywhere).
        let wasSelection = replacesSelection
        let back = backToDraft()
        let next = handleLevelOne(event)
        return Response(effects: back + next.effects, handled: !wasSelection || next.handled)
    }

    private func startTranslation() -> Response {
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .consumed() }
        requestCounter += 1
        phase = .translating(id: requestCounter)
        result = .empty
        highlightOverride = nil
        return .consumed([.startConversion(input: input, id: requestCounter), .updateMarkedText, .showPanel])
    }

    // MARK: - Translate key

    /// ⌥Space, when that is the translate key (an Option tap arrives as modifier changes instead).
    private func isTranslateKey(_ event: KeyEvent) -> Bool {
        translateKey == .optionSpace && event.keyCode == VirtualKey.space
            && event.modifiers.subtracting(.capsLock) == .option
    }

    /// The translate key: pinyin still being typed is converted as Space would pick it, then the
    /// sentence goes to the model. In level two it accepts like Space; during dictation the sentence
    /// goes once the transcript is final. Nil when there is nothing to send (the key then has its
    /// usual meaning, e.g. ⌥Space reaches the application).
    private func translateKeyPressed() -> [Effect]? {
        guard aiEnabled else { return nil }
        if voice != .off { return translateAfterVoice() }
        if isLevelTwo { return acceptInLevelTwo() }  // selected text gets here without an engine too
        guard let engine else { return nil }
        let composing = engine.snapshot().isComposing
        guard composing || !draft.isEmpty else { return nil }
        let effects = composing ? convertComposition(engine) : []
        setLevelOnePhase()
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return effects + [.updateMarkedText, wantsPanel ? .showPanel : .hidePanel]
        }
        return effects + startTranslation().effects
    }

    /// The translate key during dictation: recording stops (as if the key was released) and the
    /// sentence goes to the model as soon as the final transcript is in.
    private func translateAfterVoice() -> [Effect] {
        translatesAfterVoice = true
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

    /// Space (or the translate key) in level two: inserts the highlighted line once it is complete;
    /// after a failure, asks again.
    private func acceptInLevelTwo() -> [Effect] {
        if case .failed = phase { return startTranslation().effects }
        return commitChoice(at: highlighted)
    }

    private func backToDraft() -> [Effect] {
        // Selected text was never taken out of the document: there is no draft to go back to.
        if replacesSelection { return finish(committing: "") }
        var effects: [Effect] = []
        if case .translating = phase { effects.append(.cancelConversion) }
        result = .empty
        highlightOverride = nil
        setLevelOnePhase()
        return effects + [.updateMarkedText, wantsPanel ? .showPanel : .hidePanel]
    }

    private func commitChoice(at index: Int) -> [Effect] {
        let all = choices
        guard all.indices.contains(index), all[index].isComplete, !all[index].text.isEmpty else { return [] }
        // For selected text, the original means leaving it as it is.
        if replacesSelection, all[index].kind == .original { return finish(committing: "") }
        return finish(committing: all[index].text)
    }

    private func moveHighlight(by delta: Int) -> [Effect] {
        let count = choices.count
        guard count > 0 else { return [] }
        let current = min(highlighted, count - 1)
        highlightOverride = (current + delta + count) % count
        return [.showPanel]
    }

    /// Ends the composition, inserting `text`, and clears the engine. For selected text, `text`
    /// replaces the selection instead, and an empty `text` leaves it as it was.
    private func finish(committing text: String) -> [Effect] {
        var effects: [Effect] = []
        if case .translating = phase { effects.append(.cancelConversion) }
        if let id = voice.id { effects += cancelVoice(id, refresh: false) }
        let selection = replacesSelection
        engine?.clearComposition()
        engineState = engine?.snapshot() ?? .empty
        draft = ""
        draftStartedLatin = false
        draftEndsWithVoice = false
        translatesAfterVoice = false
        replacesSelection = false
        result = .empty
        highlightOverride = nil
        phase = .idle
        effects.append(.hidePanel)
        if selection {
            if !text.isEmpty { effects.append(.replaceSelection(text)) }
        } else {
            effects.append(text.isEmpty ? .updateMarkedText : .commit(text))
        }
        return effects
    }
}
