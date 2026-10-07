import Foundation

/// Two-level input state machine.
///
/// Level one is a local pinyin engine (Rime): typing, selecting and committing words works like any
/// pinyin input method. With AI on, text the engine commits is collected into a *draft* (shown inline,
/// not yet in the document) instead of being inserted. Space on a finished draft starts level two:
/// the sentence goes to the model, which streams three English versions and a polished original.
///
///     idle ─letters─▶ drafting ─Space (nothing left to convert)─▶ translating ─final─▶ choosing
///      ▲               │   ▲ ◀──────────── Esc / ⌫ / typing more ────────────────────────┘ │
///      └── ⏎ commits draft ┘ ◀──────────────── Space / digits / ⏎ commit ──────────────────┘
///
/// With AI off, level one behaves like a plain Rime input method (commits go straight to the document).
/// The input controller performs the returned `Effect`s in order. Main thread only.
public final class Composer {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The engine is composing and/or a draft is pending.
        case drafting
        case translating(id: Int)
        case choosing
        case failed(String)
    }

    public enum Effect: Equatable, Sendable {
        /// Re-render the inline marked text from `markedText` / `markedCursor`.
        case updateMarkedText
        /// Insert text into the document, replacing the marked text.
        case commit(String)
        case startConversion(input: String, id: Int)
        case cancelConversion
        /// Show or refresh the candidate panel.
        case showPanel
        case hidePanel
        /// Briefly show a status message near the caret.
        case notice(String)
        /// The AI setting was toggled; persist it.
        case aiModeChanged(Bool)
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
            case original, english
            /// A Chinese rewrite; the value is the style name ("简洁", "正式", …).
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
    /// Confirmed text waiting for level two (AI mode only).
    public private(set) var draft = ""
    /// Last known state of the level-one engine.
    public private(set) var engineState = EngineSnapshot.empty
    public private(set) var result = ConversionResult.empty
    public var aiEnabled: Bool
    /// Level one. Nil while the dictionaries are being prepared; keys then go to the application.
    public var engine: PinyinEngine? {
        didSet { engineState = engine?.snapshot() ?? .empty }
    }

    private var highlightOverride: Int?
    private var requestCounter = 0
    /// When Shift went down with no other key since (nil once any key is pressed).
    private var shiftPressedAt: TimeInterval?
    private var warnedNotReady = false

    public init(engine: PinyinEngine? = nil, aiEnabled: Bool = true) {
        self.engine = engine
        self.aiEnabled = aiEnabled
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

    /// Inline text: the draft followed by the engine's composition.
    public var markedText: String {
        isLevelTwo ? draft : draft + (engineState.isComposing ? engineState.preedit : "")
    }

    /// Caret position in `markedText`, in Characters.
    public var markedCursor: Int {
        guard !isLevelTwo, engineState.isComposing else { return draft.count }
        return draft.count + min(max(engineState.cursor, 0), engineState.preedit.count)
    }

    /// Level-two rows: "0" the sentence as typed, "1"–"3" English, then the Chinese rewrites in
    /// the configured styles, numbered on from 4. A rewrite is shown once it has fully arrived,
    /// and only if it changes the wording (not just punctuation) and doesn't repeat another one.
    public var choices: [Choice] {
        guard isLevelTwo else { return [] }
        var out = [Choice(label: "0", kind: .original, text: draft, isComplete: true)]
        for (i, line) in result.english.enumerated() {
            out.append(Choice(label: String(i + 1), kind: .english, text: line.text, isComplete: line.isComplete))
        }
        var shownWordings: Set<String> = [draft.wordingKey]
        var next = 4
        for rewrite in result.rewrites where rewrite.line.isComplete && next <= 9 {
            let key = rewrite.line.text.wordingKey
            guard !key.isEmpty, shownWordings.insert(key).inserted else { continue }
            out.append(Choice(label: String(next), kind: .rewrite(rewrite.style), text: rewrite.line.text, isComplete: true))
            next += 1
        }
        return out
    }

    /// Index into `choices`. Defaults to the first English line, even before it has streamed in,
    /// so an early Space never commits something else by accident.
    public var highlighted: Int {
        let all = choices
        if let highlightOverride { return all.isEmpty ? 0 : min(highlightOverride, all.count - 1) }
        if case .translating = phase { return 1 }
        if let i = all.firstIndex(where: { $0.kind == .english }) { return i }
        if let i = all.firstIndex(where: { $0.kind.isRewrite }) { return i }
        return 0
    }

    /// Whether the candidate panel has something to show.
    public var wantsPanel: Bool {
        if isLevelTwo { return true }
        if engineState.isComposing { return !engineState.candidates.isEmpty }
        return !draft.isEmpty
    }

    // MARK: - Keys

    public func handleKeyDown(_ event: KeyEvent) -> Response {
        shiftPressedAt = nil
        let modifiers = event.modifiers.subtracting(.capsLock)
        if modifiers.contains(.command) { return .passThrough }
        if event.keyCode == VirtualKey.space, modifiers == [.shift] { return toggleAI() }
        return isLevelTwo ? handleLevelTwo(event) : handleLevelOne(event)
    }

    /// Shift pressed and released on its own (within half a second, so holding Shift for a
    /// Shift-click selection doesn't count) switches the engine between Chinese and Latin input.
    /// Words already picked are kept and remaining letters are committed as typed (librime's
    /// `commit_code`). The application always receives modifier changes as well. `timestamp` is in seconds.
    public func handleFlagsChanged(keyCode: UInt16, modifiers: KeyModifiers, timestamp: TimeInterval) -> [Effect] {
        let isShift = keyCode == VirtualKey.leftShift || keyCode == VirtualKey.rightShift
        let others = modifiers.subtracting([.shift, .capsLock])
        if isShift, modifiers.contains(.shift), others.isEmpty {
            shiftPressedAt = timestamp
            return []
        }
        let toggle = isShift && !modifiers.contains(.shift)
            && shiftPressedAt.map { timestamp - $0 <= Self.shiftTapWindow } == true
        shiftPressedAt = nil
        return toggle ? toggleLatin() : []
    }

    static let shiftTapWindow: TimeInterval = 0.5

    /// A candidate clicked in the panel.
    public func choose(index: Int) -> [Effect] {
        if isLevelTwo { return commitChoice(at: index) }
        guard let engine, engineState.isComposing, engine.selectCandidate(onPage: index) else { return [] }
        return afterEngineChange(engine, effects: [], picked: true)
    }

    // MARK: - Conversion feedback

    public func receive(_ newResult: ConversionResult, isFinal: Bool, id: Int) -> [Effect] {
        guard phase == .translating(id: id) else { return [] }
        result = newResult
        if isFinal {
            phase = choices.contains(where: { $0.kind != .original && !$0.text.isEmpty }) ? .choosing : .failed("没有得到结果")
        }
        return [.showPanel]
    }

    public func fail(_ message: String, id: Int) -> [Effect] {
        guard phase == .translating(id: id) else { return [] }
        phase = .failed(message)
        return [.showPanel]
    }

    // MARK: - Ending the composition from outside

    /// The application ends the composition (focus change, click elsewhere, input source switch):
    /// everything pending is committed as converted text.
    public func commitAll() -> [Effect] {
        var text = draft
        if !isLevelTwo, let engine, engine.snapshot().isComposing {
            text += engine.commitComposition() ?? ""
        }
        return finish(committing: text)
    }

    /// Commits everything exactly as typed (draft plus raw letters), without converting.
    public func commitAsTyped() -> [Effect] {
        var text = draft
        if !isLevelTwo, let engine, engine.snapshot().isComposing {
            text += engine.rawInput
        }
        return finish(committing: text)
    }

    /// Re-reads the engine (e.g. after it became available).
    public func refreshEngineState() {
        engineState = engine?.snapshot() ?? .empty
    }

    // MARK: - Level one

    private func handleLevelOne(_ event: KeyEvent) -> Response {
        guard let engine else {
            guard event.printableText != nil, !warnedNotReady else { return .passThrough }
            warnedNotReady = true
            return Response(effects: [.notice("词库准备中，稍候可用")], handled: false)
        }
        let composing = engine.snapshot().isComposing
        let modifiers = event.modifiers.subtracting(.capsLock)
        if !composing {
            if !draft.isEmpty, let response = handleDraftKey(event) { return response }
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
        guard let key = RimeKey.map(rimeEvent) else { return pending ? .consumed() : .passThrough }
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
        if !handled, aiEnabled, !draft.isEmpty, !engineState.isComposing, let text = event.printableText {
            // Digits, Latin-mode letters etc. after Chinese text stay part of the sentence.
            draft += text
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

    /// Keys with a meaning for the draft itself, when the engine has nothing left to convert.
    private func handleDraftKey(_ event: KeyEvent) -> Response? {
        let plain = event.modifiers.subtracting(.capsLock).isEmpty
        switch event.keyCode {
        case VirtualKey.space where plain:
            // In English (Latin) mode Space separates words; a second Space in a row translates.
            if engineState.isAsciiMode, !draft.hasSuffix(" ") {
                draft += " "
                return .consumed([.updateMarkedText, .showPanel])
            }
            return startTranslation()
        case VirtualKey.returnKey, VirtualKey.keypadEnter:
            return .consumed(finish(committing: draft))
        case VirtualKey.delete:
            draft.removeLast()
            setLevelOnePhase()
            return .consumed([.updateMarkedText, draft.isEmpty ? .hidePanel : .showPanel])
        case VirtualKey.escape:
            draft = ""
            setLevelOnePhase()
            return .consumed([.updateMarkedText, .hidePanel])
        case VirtualKey.tab, VirtualKey.left, VirtualKey.right, VirtualKey.up, VirtualKey.down,
             VirtualKey.home, VirtualKey.end, VirtualKey.pageUp, VirtualKey.pageDown, VirtualKey.forwardDelete:
            return .consumed()
        default:
            return nil
        }
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
            draft += text
            return []
        }
        return [.commit(text)]
    }

    private func setLevelOnePhase() {
        phase = draft.isEmpty && !engineState.isComposing ? .idle : .drafting
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
        return effects + [.notice(latin ? "中" : "英")]
    }

    private func toggleAI() -> Response {
        .consumed(setAI(!aiEnabled))
    }

    /// Turns level two on or off (⇧Space or the menu). Turning it off inserts a pending draft as is.
    public func setAI(_ on: Bool) -> [Effect] {
        guard on != aiEnabled else { return [] }
        aiEnabled = on
        var effects: [Effect] = []
        if !on, !draft.isEmpty {
            if case .translating = phase { effects.append(.cancelConversion) }
            effects += [.hidePanel, .commit(draft)]
            draft = ""
            result = .empty
            highlightOverride = nil
            setLevelOnePhase()
            if engineState.isComposing { effects += [.updateMarkedText, .showPanel] }
        }
        return effects + [.aiModeChanged(on), .notice(on ? "AI 翻译：开" : "AI 翻译：关")]
    }

    // MARK: - Level two

    private func handleLevelTwo(_ event: KeyEvent) -> Response {
        switch event.keyCode {
        case VirtualKey.space:
            if case .failed = phase { return startTranslation() }
            return .consumed(commitChoice(at: highlighted))
        case VirtualKey.returnKey, VirtualKey.keypadEnter:
            return .consumed(finish(committing: draft))
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

    private func startTranslation() -> Response {
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .consumed() }
        requestCounter += 1
        phase = .translating(id: requestCounter)
        result = .empty
        highlightOverride = nil
        return .consumed([.startConversion(input: input, id: requestCounter), .updateMarkedText, .showPanel])
    }

    private func backToDraft() -> [Effect] {
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
        engine?.clearComposition()
        engineState = engine?.snapshot() ?? .empty
        draft = ""
        result = .empty
        highlightOverride = nil
        phase = .idle
        effects.append(.hidePanel)
        effects.append(text.isEmpty ? .updateMarkedText : .commit(text))
        return effects
    }
}
