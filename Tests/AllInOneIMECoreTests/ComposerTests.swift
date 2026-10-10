import Testing
@testable import AllInOneIMECore

/// Minimal stand-in for Rime: whole-input candidates from a tiny dictionary.
final class FakeEngine: PinyinEngine {
    var dictionary = [
        "nihao": ["你好", "拟好"],
        "wo": ["我", "窝"],
        "jintian": ["今天", "金天"],
    ]
    var input = ""
    var highlighted = 0
    var ascii = false
    /// Every key librime would have been given, in order.
    var keys: [(keycode: Int32, mask: Int32)] = []
    private var pendingCommit: String?

    func candidates() -> [String] { menu().words }

    /// The candidates for the input and how many letters picking one uses up: a whole-input entry,
    /// else (like Rime's partial candidates) the longest known prefix, else the letters as typed.
    func menu() -> (words: [String], length: Int) {
        guard !input.isEmpty else { return ([], 0) }
        if let words = dictionary[input] { return (words, input.count) }
        for n in stride(from: input.count - 1, to: 0, by: -1) {
            if let words = dictionary[String(input.prefix(n))] { return (words, n) }
        }
        return ([input], input.count)
    }

    func processKey(_ keycode: Int32, mask: Int32) -> Bool {
        keys.append((keycode, mask))
        if ascii { return false }
        let composing = !input.isEmpty
        switch keycode {
        case 0x61...0x7A:
            input.append(Character(Unicode.Scalar(UInt8(keycode))))
            highlighted = 0
            return true
        case RimeKey.space where composing: return select(highlighted)
        case 0x31...0x35 where composing: return select(Int(keycode - 0x31))
        case RimeKey.returnKey where composing:
            emit(input)
            input = ""
            return true
        case RimeKey.backSpace where composing:
            input.removeLast()
            return true
        case RimeKey.escape where composing:
            input = ""
            return true
        case RimeKey.down where composing:
            highlighted = min(highlighted + 1, candidates().count - 1)
            return true
        case 0x2C:  // ','
            if composing { emit(candidates()[highlighted]); input = "" }
            emit("，")
            return true
        default:
            return composing
        }
    }

    private func select(_ index: Int) -> Bool {
        let (all, length) = menu()
        guard all.indices.contains(index) else { return true }
        emit(all[index])
        input.removeFirst(length)
        highlighted = 0
        return true
    }

    private func emit(_ s: String) { pendingCommit = (pendingCommit ?? "") + s }

    func takeCommit() -> String? {
        defer { pendingCommit = nil }
        return pendingCommit
    }

    func snapshot() -> EngineSnapshot {
        EngineSnapshot(
            isComposing: !input.isEmpty, preedit: input, cursor: input.count,
            candidates: candidates().enumerated().map { EngineCandidate(label: String($0.offset + 1), text: $0.element) },
            highlighted: highlighted, isAsciiMode: ascii)
    }

    func selectCandidate(onPage index: Int) -> Bool {
        guard !input.isEmpty, candidates().indices.contains(index) else { return false }
        return select(index)
    }

    /// Like librime: the highlighted candidate, then any letters it doesn't cover, as typed.
    func commitComposition() -> String? {
        guard !input.isEmpty else { return nil }
        let (all, length) = menu()
        emit(all[min(highlighted, all.count - 1)])
        emit(String(input.dropFirst(length)))
        input = ""
        highlighted = 0
        return takeCommit()
    }

    var rawInput: String { input }
    func clearComposition() { input = "" }
    func setAsciiMode(_ on: Bool) { ascii = on }
}

func k(_ s: String, mods: KeyModifiers = []) -> KeyEvent { KeyEvent(keyCode: 0, characters: s, modifiers: mods) }
let spaceKey = KeyEvent(keyCode: VirtualKey.space, characters: " ")
let enterKey = KeyEvent(keyCode: VirtualKey.returnKey, characters: "\r")
let escKey = KeyEvent(keyCode: VirtualKey.escape, characters: "\u{1B}")
let backspaceKey = KeyEvent(keyCode: VirtualKey.delete, characters: "\u{7F}")
let upKey = KeyEvent(keyCode: VirtualKey.up, characters: "\u{F700}")
let downKey = KeyEvent(keyCode: VirtualKey.down, characters: "\u{F701}")
let shiftSpace = KeyEvent(keyCode: VirtualKey.space, characters: " ", modifiers: .shift)
/// ⌥Space as AppKit delivers it on a US layout (it types a no-break space).
let optionSpace = KeyEvent(keyCode: VirtualKey.space, characters: "\u{A0}", charactersIgnoringModifiers: " ", modifiers: .option)

func commits(_ r: Composer.Response) -> [String] { commits(r.effects) }
func commits(_ effects: [Composer.Effect]) -> [String] {
    effects.compactMap { if case let .commit(s) = $0 { return s } else { return nil } }
}

struct ComposerTests {
    let final = ConversionResult(
        versions: [CandidateLine("Hi there."), CandidateLine("Hello."), CandidateLine("Hey.")],
        rewrites: [
            Rewrite(style: "润色", line: CandidateLine("你好呀！")),
            Rewrite(style: "简洁", line: CandidateLine("嗨！")),
            Rewrite(style: "正式", line: CandidateLine("您好！")),
        ])

    func rewrites(_ pairs: [(String, String)], complete: Bool = true) -> [Rewrite] {
        pairs.map { Rewrite(style: $0.0, line: CandidateLine($0.1, isComplete: complete)) }
    }

    /// Most tests below use the original Space action key; the "Action key" section covers
    /// ⌥Space (the default) and the Option tap.
    func composer(voice: Bool = true, key: ActionKey = .space) -> (Composer, FakeEngine) {
        let engine = FakeEngine()
        return (Composer(engine: engine, voiceEnabled: voice, actionKey: key), engine)
    }

    /// Composer in English mode.
    func english(key: ActionKey = .space) -> (Composer, FakeEngine) {
        let (c, e) = composer(key: key)
        c.setInputMode(.english)
        return (c, e)
    }

    /// "@improve " picked from the palette ("@i", Tab), in English mode with `english`: what is typed
    /// next is the sentence to improve.
    func improveDraft(key: ActionKey = .space, english: Bool = false) -> (Composer, FakeEngine) {
        let (c, e) = composer(key: key)
        if english { c.setInputMode(.english) }
        _ = c.handleKeyDown(at)
        type("i", c)
        _ = c.handleKeyDown(tab)
        #expect(c.draft == "@improve ")
        return (c, e)
    }

    func type(_ s: String, _ c: Composer) {
        for ch in s { _ = c.handleKeyDown(k(String(ch))) }
    }

    /// Draft "@improve 你好" with a request in flight (id 1).
    func translating() -> (Composer, FakeEngine) {
        let (c, e) = improveDraft()
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        _ = c.handleKeyDown(spaceKey)
        return (c, e)
    }

    @Test func idlePassesThroughNonLetters() {
        let (c, _) = composer()
        for key in [k("1"), spaceKey, enterKey, backspaceKey, escKey, upKey, k("c", mods: .command)] {
            #expect(c.handleKeyDown(key) == .passThrough)
        }
        #expect(c.phase == .idle)
    }

    @Test func typingShowsPinyinAndCandidates() {
        let (c, _) = composer()
        let r = c.handleKeyDown(k("n"))
        #expect(r.handled)
        #expect(r.effects == [.updateMarkedText, .showPanel])
        type("ihao", c)
        #expect(c.markedText == "nihao")
        #expect(c.markedCursor == 5)
        #expect(c.engineState.candidates.map(\.text) == ["你好", "拟好"])
        #expect(c.phase == .drafting)
    }

    @Test func firstSpaceDraftsSecondSpaceTranslates() {
        let (c, _) = improveDraft()
        type("nihao", c)
        let confirm = c.handleKeyDown(spaceKey)
        #expect(commits(confirm).isEmpty)
        #expect(c.draft == "@improve 你好")
        #expect(c.markedText == "improve › 你好")
        #expect(confirm.effects.contains(.showPanel))  // hint: Space translates
        let translate = c.handleKeyDown(spaceKey)
        #expect(translate.effects == [.startConversion(input: "你好", id: 1), .updateMarkedText, .showPanel,
                                                      .commandUsed("improve")])
        #expect(c.phase == .translating(id: 1))
        #expect(c.markedText == "improve › 你好")
    }

    @Test func sentenceBuiltFromSeveralPiecesAndPunctuation() {
        let (c, _) = improveDraft()
        type("wo", c)
        _ = c.handleKeyDown(spaceKey)
        type("jintian", c)
        #expect(c.markedText == "improve › 我jintian")
        #expect(c.markedCursor == 18)
        _ = c.handleKeyDown(k("2"))  // pick 金天 by digit
        #expect(c.draft == "@improve 我金天")
        _ = c.handleKeyDown(backspaceKey)
        #expect(c.draft == "@improve 我金")
        _ = c.handleKeyDown(k(","))
        #expect(c.draft == "@improve 我金，")
        _ = c.handleKeyDown(k("3"))  // engine ignores digits when idle: stays in the sentence
        #expect(c.draft == "@improve 我金，3")
        let r = c.handleKeyDown(spaceKey)
        #expect(r.effects.first == .startConversion(input: "我金，3", id: 1))
    }

    @Test func punctuationAndRawLettersWithNothingPendingAreInsertedDirectly() {
        let (c, _) = composer()
        #expect(commits(c.handleKeyDown(k(","))) == ["，"])
        type("hello", c)
        #expect(commits(c.handleKeyDown(enterKey)) == ["hello"])
        #expect(c.phase == .idle)
    }

    @Test func pickedDatesAndEmojiGoStraightIn() {
        let (c, e) = composer()
        e.dictionary["rq"] = ["2026-10-06"]
        e.dictionary["hi"] = ["👋"]
        type("rq", c)
        #expect(commits(c.handleKeyDown(spaceKey)) == ["2026-10-06"] && c.phase == .idle)
        type("hi", c)
        #expect(commits(c.choose(index: 0)) == ["👋"] && c.draft.isEmpty)  // mouse click
    }

    @Test func escapeDiscardsTheDraft() {
        let (c, _) = improveDraft()
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.handleKeyDown(escKey).effects == [.updateMarkedText, .hidePanel])
        #expect(c.phase == .idle)
        #expect(c.markedText.isEmpty)
    }

    @Test func levelTwoSpaceWaitsForFirstEnglishLine() {
        let (c, _) = translating()
        let partial = ConversionResult(versions: [CandidateLine("Hi th", isComplete: false)])
        #expect(c.receive(partial, isFinal: false, id: 1) == [.showPanel])
        #expect(c.highlighted == 1)
        #expect(c.handleKeyDown(spaceKey).effects.isEmpty)
        #expect(c.phase == .translating(id: 1))
        #expect(commits(c.handleKeyDown(k("0"))) == ["你好"])  // the original is always ready
    }

    @Test func levelTwoChoices() {
        let (c, _) = translating()
        _ = c.receive(final, isFinal: true, id: 1)
        #expect(c.phase == .choosing)
        #expect(c.choices.map(\.label) == ["0", "1", "2", "3", "4", "5", "6"])
        #expect(c.choices.map(\.kind) == [.original, .version, .version, .version,
                                          .rewrite("润色"), .rewrite("简洁"), .rewrite("正式")])
        #expect(commits(c.handleKeyDown(spaceKey)) == ["Hi there."])
        #expect(c.phase == .idle)

        for (digit, expected) in [("2", "Hello."), ("4", "你好呀！"), ("5", "嗨！"), ("6", "您好！"), ("0", "你好")] {
            let (d, _) = translating()
            _ = d.receive(final, isFinal: true, id: 1)
            #expect(commits(d.handleKeyDown(k(digit))) == [expected])
        }
        let (e, _) = translating()
        _ = e.receive(final, isFinal: true, id: 1)
        #expect(e.handleKeyDown(k("9")).effects.isEmpty)
        #expect(commits(e.handleKeyDown(enterKey)) == ["Hi there."])  // like Space: the highlighted row
    }

    @Test func returnInsertsTheHighlightedRow() {
        let (c, _) = translating()
        _ = c.receive(final, isFinal: true, id: 1)
        _ = c.handleKeyDown(downKey)
        #expect(commits(c.handleKeyDown(enterKey)) == ["Hello."])
        // Row 0 is the sentence as typed.
        let (d, _) = translating()
        _ = d.receive(final, isFinal: true, id: 1)
        _ = d.handleKeyDown(upKey)
        #expect(commits(d.handleKeyDown(enterKey)) == ["你好"])
        // Before the first line is complete Return waits, like Space; 0 is always ready.
        let (e, _) = translating()
        _ = e.receive(ConversionResult(versions: [CandidateLine("Hi th", isComplete: false)]), isFinal: false, id: 1)
        #expect(e.handleKeyDown(enterKey) == .consumed() && e.phase == .translating(id: 1))
        #expect(commits(e.handleKeyDown(k("0"))) == ["你好"])
    }

    @Test func arrowsMoveHighlightAndWrap() {
        let (c, _) = translating()
        _ = c.receive(final, isFinal: true, id: 1)
        _ = c.handleKeyDown(downKey)
        #expect(c.highlighted == 2)
        _ = c.handleKeyDown(upKey)
        _ = c.handleKeyDown(upKey)
        #expect(c.highlighted == 0)
        _ = c.handleKeyDown(upKey)
        #expect(c.highlighted == 6)
        #expect(commits(c.handleKeyDown(spaceKey)) == ["您好！"])
    }

    @Test func rewritesThatOnlyChangePunctuationAreHidden() {
        let (c, _) = translating()
        _ = c.receive(ConversionResult(versions: [CandidateLine("Hi.")], rewrites: rewrites([("润色", " 你好 ")])),
                      isFinal: true, id: 1)
        #expect(c.choices.map(\.label) == ["0", "1"])

        let (d, _) = translating()
        _ = d.receive(ConversionResult(versions: [CandidateLine("Hi.")],
                                       rewrites: rewrites([("润色", "你好。"), ("正式", "您好。")])),
                      isFinal: true, id: 1)
        // "你好。" is the original plus a full stop: hidden, and the formal rewrite takes label 4.
        #expect(d.choices.map(\.label) == ["0", "1", "4"])
        #expect(d.choices.last?.kind == .rewrite("正式"))
        #expect(commits(d.handleKeyDown(k("4"))) == ["您好。"])

        let (e, _) = translating()
        _ = e.receive(ConversionResult(versions: [CandidateLine("Hi.")],
                                       rewrites: rewrites([("润色", "您好！"), ("正式", "您好。")])),
                      isFinal: true, id: 1)
        #expect(e.choices.map(\.label) == ["0", "1", "4"])  // 正式 (formal) repeats the 润色 (polish) wording
        #expect(e.choices.last?.kind == .rewrite("润色"))
    }

    @Test func rewritesFollowTheModelsOrder() {
        let (c, _) = translating()
        _ = c.receive(ConversionResult(versions: [CandidateLine("Hi.")],
                                       rewrites: rewrites([("委婉", "你好呀，打扰啦"), ("口语", "嗨～")])),
                      isFinal: true, id: 1)
        #expect(c.choices.map(\.kind) == [.original, .version, .rewrite("委婉"), .rewrite("口语")])
        #expect(c.choices.map(\.label) == ["0", "1", "4", "5"])
    }

    @Test func rewritesAppearOnceComplete() {
        let (c, _) = translating()
        _ = c.receive(ConversionResult(versions: [CandidateLine("Hi.")], rewrites: rewrites([("润色", "你好")], complete: false)),
                      isFinal: false, id: 1)
        #expect(c.choices.map(\.label) == ["0", "1"])  // could still turn out to be a copy
        _ = c.receive(ConversionResult(versions: [CandidateLine("Hi.")],
                                       rewrites: rewrites([("润色", "你好呀！")]) + rewrites([("简洁", "嗨")], complete: false)),
                      isFinal: false, id: 1)
        #expect(c.choices.map(\.label) == ["0", "1", "4"])
        _ = c.receive(final, isFinal: true, id: 1)
        #expect(c.choices.map(\.label) == ["0", "1", "2", "3", "4", "5", "6"])
        #expect(c.phase == .choosing)
    }

    @Test func onlyChineseRewritesStillMakeAResult() {
        let (c, _) = translating()
        _ = c.receive(ConversionResult(rewrites: rewrites([("正式", "您好！")])), isFinal: true, id: 1)
        #expect(c.phase == .choosing)
        #expect(c.choices[c.highlighted].kind == .rewrite("正式"))
    }

    @Test func escapeAndBackspaceReturnToTheDraft() {
        for key in [escKey, backspaceKey] {
            let (c, _) = translating()
            let r = c.handleKeyDown(key)
            #expect(r.effects == [.cancelConversion, .updateMarkedText, .showPanel])
            #expect(c.phase == .drafting)
            #expect(c.draft == "@improve 你好")
        }
    }

    @Test func typingInLevelTwoContinuesTheSentence() {
        let (c, _) = translating()
        let r = c.handleKeyDown(k("w"))
        #expect(r.effects.first == .cancelConversion)
        #expect(c.phase == .drafting)
        #expect(c.markedText == "improve › 你好w")
        type("o", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.draft == "@improve 你好我")
        #expect(c.handleKeyDown(spaceKey).effects.first == .startConversion(input: "你好我", id: 2))
    }

    @Test func staleUpdatesAreIgnored() {
        let (c, _) = translating()
        _ = c.handleKeyDown(escKey)
        _ = c.handleKeyDown(spaceKey)  // id 2
        #expect(c.receive(final, isFinal: true, id: 1).isEmpty)
        #expect(c.fail("boom", id: 1).isEmpty)
        #expect(c.phase == .translating(id: 2))
    }

    @Test func failureRetriesWithSpace() {
        let (c, _) = translating()
        #expect(c.fail("超时", id: 1) == [.showPanel])
        #expect(c.phase == .failed("超时"))
        #expect(c.handleKeyDown(spaceKey).effects.first == .startConversion(input: "你好", id: 2))
        _ = c.receive(.empty, isFinal: true, id: 2)
        #expect(c.phase == .failed("没有得到结果"))
        #expect(commits(c.handleKeyDown(enterKey)) == ["你好"])
    }

    @Test func withoutACommandSpaceCommitsStraightFromTheEngine() {
        let (c, _) = composer()
        type("nihao", c)
        let r = c.handleKeyDown(spaceKey)
        #expect(commits(r) == ["你好"])
        #expect(c.phase == .idle)
        #expect(c.handleKeyDown(spaceKey) == .passThrough)
    }

    @Test func shiftAloneTogglesLatinAndKeepsTypedLetters() {
        let (c, e) = composer()
        type("ni", c)
        #expect(c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: .shift, timestamp: 10).isEmpty)
        let r = c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: [], timestamp: 10.1)
        #expect(commits(r) == ["ni"])
        #expect(r.contains(.notice("英")))
        #expect(e.ascii)
        #expect(c.handleKeyDown(k("a")) == .passThrough)  // Latin letters go to the app

        // Shift used for a capital letter is not a toggle.
        _ = c.handleFlagsChanged(keyCode: VirtualKey.rightShift, modifiers: .shift, timestamp: 11)
        _ = c.handleKeyDown(k("A", mods: .shift))
        #expect(c.handleFlagsChanged(keyCode: VirtualKey.rightShift, modifiers: [], timestamp: 11.1).isEmpty)
        #expect(e.ascii)
        // Shift together with another modifier (e.g. ⌘⇧4) is not a toggle either.
        _ = c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: .shift, timestamp: 12)
        _ = c.handleFlagsChanged(keyCode: 0x37, modifiers: [.shift, .command], timestamp: 12.05)
        #expect(c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: .command, timestamp: 12.1).isEmpty)
        #expect(e.ascii)
        // Holding Shift (e.g. for a Shift-click selection) is not a toggle.
        _ = c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: .shift, timestamp: 13)
        #expect(c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: [], timestamp: 14).isEmpty)
        #expect(e.ascii)

        _ = c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: .shift, timestamp: 15)
        #expect(c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: [], timestamp: 15.2).contains(.notice("中")))
        #expect(!e.ascii)
    }

    @Test func latinLettersAfterChineseStayInTheDraft() {
        let (c, e) = improveDraft()
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        e.ascii = true
        type("ok", c)
        #expect(c.draft == "@improve 你好ok")
    }

    @Test func latinModeSpaceSeparatesWordsAndDoubleSpaceTranslates() {
        let (c, e) = improveDraft()
        type("wo", c)
        _ = c.handleKeyDown(spaceKey)
        e.ascii = true
        c.refreshEngineState()
        type("check", c)
        #expect(c.handleKeyDown(spaceKey).effects == [.updateMarkedText, .showPanel])
        type("it", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.draft == "@improve 我check it ")
        let r = c.handleKeyDown(spaceKey)
        #expect(r.effects.first == .startConversion(input: "我check it", id: 1))
    }

    @Test func commitAllAndCommitAsTyped() {
        let (c, _) = improveDraft()
        type("wo", c)
        _ = c.handleKeyDown(spaceKey)
        type("nihao", c)
        #expect(commits(c.commitAll()) == ["@improve 我你好"])
        #expect(c.phase == .idle)
        #expect(!c.engineState.isComposing)

        let (d, _) = improveDraft()
        type("wo", d)
        _ = d.handleKeyDown(spaceKey)
        type("ni", d)
        #expect(commits(d.commitAsTyped()) == ["@improve 我ni"])
        #expect(d.markedText.isEmpty)

        let (t, _) = translating()
        #expect(t.commitAll() == [.cancelConversion, .hidePanel, .commit("@improve 你好")])
        let (p, _) = composer()  // pinyin alone: converted
        type("nihao", p)
        #expect(commits(p.commitAll()) == ["你好"])
        let (idle, _) = composer()
        #expect(idle.commitAll() == [.hidePanel, .updateMarkedText])
    }

    @Test func mouseSelectsCandidatesAtBothLevels() {
        let (c, _) = improveDraft()
        type("nihao", c)
        _ = c.choose(index: 1)
        #expect(c.draft == "@improve 拟好")
        _ = c.handleKeyDown(spaceKey)
        _ = c.receive(final, isFinal: true, id: 1)
        #expect(commits(c.choose(index: 3)) == ["Hey."])
    }

    @Test func notReadyEngineLetsKeysThroughWithOneNotice() {
        let c = Composer(engine: nil)
        #expect(c.handleKeyDown(k("n")) == Composer.Response(effects: [.notice("词库准备中，稍候可用")], handled: false))
        #expect(c.handleKeyDown(k("i")) == .passThrough)
    }

    @Test func capsLockTypesDirectlyWhenIdle() {
        let (c, _) = composer()
        #expect(c.handleKeyDown(k("W", mods: .capsLock)) == .passThrough)
    }

    // MARK: - English drafts

    @Test func englishInACommandAndDoubleSpaceSendsIt() {
        let (c, _) = english()
        // Without a command, Space and letters are the app's.
        #expect(c.handleKeyDown(spaceKey) == .passThrough && c.handleKeyDown(k("o")) == .passThrough)
        _ = c.handleKeyDown(at)
        type("i", c)
        _ = c.handleKeyDown(tab)
        let r = c.handleKeyDown(k("o"))
        #expect(r.handled && r.effects == [.updateMarkedText, .showPanel])
        type("k", c)
        #expect(c.draft == "@improve ok" && c.isLatinDraft && c.markedText == "improve › ok")
        #expect(!c.spaceActs)
        #expect(c.handleKeyDown(spaceKey).effects == [.updateMarkedText, .showPanel])
        type("go", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.draft == "@improve ok go " && c.spaceActs)
        #expect(c.handleKeyDown(spaceKey).effects.first == .startConversion(input: "ok go", id: 1))
    }

    @Test func shortcutsInsertAnEnglishCommandAsTypedAndReachTheApp() {
        let shortcuts = [
            KeyEvent(keyCode: 0x00, characters: "a", modifiers: .command),  // ⌘A
            KeyEvent(keyCode: VirtualKey.returnKey, characters: "\r", modifiers: .command),  // ⌘⏎
        ]
        for key in shortcuts {
            let (c, _) = improveDraft(english: true)
            type("ok", c)
            let r = c.handleKeyDown(key)
            #expect(!r.handled, "\(key)")
            #expect(commits(r) == ["@improve ok"], "\(key)")
            #expect(c.phase == .idle && c.draft.isEmpty, "\(key)")
        }
        // Editing keys stay with the command (Return runs it, Esc clears it).
        let editingKeys = [upKey, downKey, KeyEvent(keyCode: VirtualKey.tab, characters: "\t"),
                           KeyEvent(keyCode: VirtualKey.left, characters: "\u{F702}")]
        for key in editingKeys {
            let (c, _) = improveDraft(english: true)
            type("ok", c)
            #expect(c.handleKeyDown(key) == .consumed() && c.draft == "@improve ok", "\(key)")
        }
    }

    @Test func englishDraftEditing() {
        let (c, _) = improveDraft(english: true)
        type("caf", c)
        // ⌥E is a dead key (no characters); the next key then types é.
        let dead = c.handleKeyDown(KeyEvent(keyCode: 0x0E, characters: "", charactersIgnoringModifiers: "e", modifiers: .option))
        #expect(dead.handled && commits(dead).isEmpty && c.draft == "@improve caf")
        _ = c.handleKeyDown(k("é"))
        #expect(c.draft == "@improve café")
    }

    @Test func englishDraftEditingKeys() {
        let (c, _) = improveDraft(english: true)
        type("okk", c)
        _ = c.handleKeyDown(backspaceKey)
        #expect(c.draft == "@improve ok")
        _ = c.handleKeyDown(k("é"))  // no librime key for it: still part of the sentence
        _ = c.handleKeyDown(k("!", mods: .shift))
        #expect(c.draft == "@improve oké!")
        for _ in 0..<4 { _ = c.handleKeyDown(backspaceKey) }
        #expect(c.draft == "@improve " && c.phase == .drafting)
        // Deleting into the command's name brings the palette back; Esc then removes it all.
        _ = c.handleKeyDown(backspaceKey)
        #expect(c.paletteQuery == "improve" && c.paletteMatches == [.improve])
        #expect(c.handleKeyDown(escKey).effects == [.updateMarkedText, .hidePanel] && c.phase == .idle)
        #expect(c.handleKeyDown(backspaceKey) == .passThrough)
    }

    @Test func pinyinAfterAnEnglishDraftMakesItAChineseSentence() {
        let (c, _) = improveDraft(english: true)
        type("ok", c)
        _ = c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: .shift, timestamp: 1)
        _ = c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: [], timestamp: 1.1)
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.draft == "@improve ok你好" && !c.isLatinDraft)
        // Shortcuts no longer insert it as typed: they reach the app with the draft still pending.
        #expect(c.handleKeyDown(k("a", mods: .command)) == .passThrough && c.draft == "@improve ok你好")
        #expect(c.handleKeyDown(enterKey).effects.first == .startConversion(input: "ok你好", id: 1))
    }

    @Test func defaultInputModeOnlyAppliesWhenIdle() {
        let (c, e) = composer()
        c.setInputMode(.english)
        #expect(e.ascii && c.engineState.isAsciiMode)
        c.setInputMode(.chinese)
        #expect(!e.ascii)
        type("ni", c)
        c.setInputMode(.english)
        #expect(!e.ascii)  // composing: left alone
    }

    @Test func rewritesRepeatingAMainVersionAreHidden() {
        let (c, _) = improveDraft(english: true)
        type("hi", c)
        _ = c.handleKeyDown(spaceKey)
        _ = c.handleKeyDown(spaceKey)
        _ = c.receive(ConversionResult(versions: [CandidateLine("Hi there!"), CandidateLine("Hello!")],
                                       rewrites: rewrites([("润色", "Hi there."), ("简洁", "Hey.")])),
                      isFinal: true, id: 1)
        #expect(c.choices.map(\.label) == ["0", "1", "2", "4"])
        #expect(c.choices.last?.text == "Hey.")
    }

    // MARK: - Voice

    /// Right Option down / up as modifier changes report them (device bit included).
    func optionDown(_ c: Composer) -> [Composer.Effect] {
        c.handleFlagsChanged(keyCode: VirtualKey.rightOption, modifiers: [.option, .rightOption], timestamp: 0)
    }

    func optionUp(_ c: Composer) -> [Composer.Effect] {
        c.handleFlagsChanged(keyCode: VirtualKey.rightOption, modifiers: [], timestamp: 0)
    }

    /// Press and hold past the arming delay: dictation starts.
    func startDictation(_ c: Composer) -> [Composer.Effect] {
        #expect(optionDown(c) == [.armVoice(delay: Composer.voiceArmDelay)])
        return c.voiceHoldElapsed()
    }

    @Test func holdingRightOptionDictatesIntoTheDraft() {
        let (c, _) = improveDraft()
        #expect(optionDown(c) == [.armVoice(delay: Composer.voiceArmDelay)])
        #expect(c.voice == .off && c.draft == "@improve ")  // nothing happens until the hold is confirmed
        #expect(c.voiceHoldElapsed() == [.updateMarkedText, .showPanel, .startVoice(id: 1, language: .chinese)])
        #expect(c.voice == .listening(id: 1, text: "") && c.isComposing && c.wantsPanel)
        #expect(c.voiceText("我今天", id: 1) == [.updateMarkedText, .showPanel])
        #expect(c.markedText == "improve › 我今天" && c.markedCursor == 13)
        #expect(optionUp(c) == [.stopVoice(id: 1), .showPanel])
        #expect(c.voice == .finishing(id: 1, text: "我今天"))
        #expect(c.voiceFinished("我今天有点不舒服", id: 1) == [.updateMarkedText, .showPanel])
        #expect(c.voice == .off && c.draft == "@improve 我今天有点不舒服" && c.phase == .drafting)
        #expect(c.handleKeyDown(spaceKey).effects.first == .startConversion(input: "我今天有点不舒服", id: 1))
    }

    @Test func tapsAndOptionShortcutsNeverStartDictation() {
        // A tap: released before the hold is confirmed.
        let (c, _) = composer()
        _ = optionDown(c)
        #expect(optionUp(c) == [.notice("按住右 ⌥ 说话")])
        #expect(c.voiceHoldElapsed().isEmpty && c.voice == .off)
        // ⌥← with pinyin pending: the arrow goes to the engine, the pinyin stays as it is.
        let (d, _) = composer()
        type("zhongguo", d)
        _ = optionDown(d)
        _ = d.handleKeyDown(KeyEvent(keyCode: VirtualKey.left, characters: "\u{F702}", modifiers: .option))
        #expect(d.voiceHoldElapsed().isEmpty && d.voice == .off && d.engineState.isComposing && d.draft.isEmpty)
        // Another modifier joining in (⌥⇧, ⌥⌘) is a shortcut.
        let (e, _) = composer()
        _ = optionDown(e)
        _ = e.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: [.option, .rightOption, .shift], timestamp: 0)
        #expect(e.voiceHoldElapsed().isEmpty)
        // The key is no longer down when the timer fires (its release went unseen).
        let (f, _) = composer()
        _ = optionDown(f)
        #expect(f.voiceHoldElapsed(stillHeld: false).isEmpty && f.voice == .off)
        // Right ⌥ while left ⌥ is held is not a hold on its own.
        let (g, _) = composer()
        let both = g.handleFlagsChanged(keyCode: VirtualKey.rightOption, modifiers: [.option, .leftOption, .rightOption], timestamp: 0)
        #expect(both.isEmpty && g.voiceHoldElapsed().isEmpty)
    }

    @Test func aMissedReleaseStillStopsTheRecording() {
        // Left ⌥ goes down during dictation, right ⌥ is released, then left ⌥.
        let (c, _) = composer()
        _ = startDictation(c)
        #expect(c.handleFlagsChanged(keyCode: VirtualKey.leftOption, modifiers: [.option, .leftOption, .rightOption], timestamp: 0).isEmpty)
        #expect(c.handleFlagsChanged(keyCode: VirtualKey.rightOption, modifiers: [.option, .leftOption], timestamp: 0)
                == [.stopVoice(id: 1), .showPanel])
        // The release itself was never delivered: the next modifier change without right ⌥ ends it.
        let (d, _) = composer()
        _ = startDictation(d)
        #expect(d.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: .shift, timestamp: 0)
                == [.stopVoice(id: 1), .showPanel])
        // Without device bits (older event sources) the Option flag decides.
        let (e, _) = composer()
        _ = e.handleFlagsChanged(keyCode: VirtualKey.rightOption, modifiers: .option, timestamp: 0)
        _ = e.voiceHoldElapsed()
        #expect(e.handleFlagsChanged(keyCode: VirtualKey.rightOption, modifiers: [], timestamp: 0)
                == [.stopVoice(id: 1), .showPanel])
    }

    @Test func keysWhileListeningCancelTheRecording() {
        let (c, _) = composer()
        _ = startDictation(c)
        let r = c.handleKeyDown(k("n"))
        #expect(r.effects.first == .cancelVoice(id: 1) && r.handled)
        #expect(c.voice == .off && c.markedText == "n")
        let (d, _) = composer()
        _ = startDictation(d)
        #expect(d.handleKeyDown(escKey) == .consumed([.cancelVoice(id: 1), .updateMarkedText, .hidePanel]))
        let (o, _) = composer()
        _ = startDictation(o)
        let chord = o.handleKeyDown(k("∑", mods: .option))  // an ⌥ chord with nothing pending reaches the app
        #expect(!chord.handled && chord.effects.first == .cancelVoice(id: 1))
    }

    @Test func aKeyBeforeTheFinalTranscriptKeepsWhatWasHeard() {
        let (c, _) = improveDraft()
        _ = startDictation(c)
        _ = c.voiceText("你好", id: 1)
        _ = optionUp(c)
        let r = c.handleKeyDown(spaceKey)
        #expect(r.effects.prefix(2) == [.cancelVoice(id: 1), .updateMarkedText])
        #expect(r.effects.contains(.startConversion(input: "你好", id: 1)))
        let (d, _) = composer()
        _ = startDictation(d)
        _ = d.voiceText("你好", id: 1)
        _ = optionUp(d)
        #expect(d.handleKeyDown(escKey).effects.first == .cancelVoice(id: 1))
        #expect(d.draft.isEmpty && d.phase == .idle)
    }

    @Test func englishDictationMakesAnEnglishDraftThatOneSpaceSends() {
        let (c, _) = improveDraft(english: true)
        type("ok", c)
        #expect(startDictation(c).last == .startVoice(id: 1, language: .english))
        _ = c.voiceText("this is", id: 1)
        #expect(c.markedText == "improve › ok this is")
        _ = optionUp(c)
        _ = c.voiceFinished("this is a blocker bug", id: 1)
        #expect(c.draft == "@improve ok this is a blocker bug" && c.isLatinDraft && c.spaceActs)
        #expect(c.handleKeyDown(spaceKey).effects.first == .startConversion(input: "ok this is a blocker bug", id: 1))
        // Typing right after an English transcript gets a separating space.
        let (d, _) = improveDraft(english: true)
        _ = startDictation(d)
        _ = optionUp(d)
        _ = d.voiceFinished("hello world", id: 1)
        type("and", d)
        #expect(d.draft == "@improve hello world and")
    }

    @Test func dictationConvertsPendingPinyinAndLeavesLevelTwo() {
        let (c, _) = improveDraft()
        type("nihao", c)
        _ = startDictation(c)
        #expect(c.draft == "@improve 你好" && c.markedText == "improve › 你好")
        _ = optionUp(c)
        _ = c.voiceFinished("吗", id: 1)
        #expect(c.draft == "@improve 你好吗")
        let (t, _) = translating()
        #expect(startDictation(t).prefix(1) == [.cancelConversion])
        #expect(!t.isLevelTwo && t.draft == "@improve 你好" && t.voice == .listening(id: 1, text: ""))
        // Without a command the pinyin goes in first, then what is said.
        let (p, _) = composer()
        type("nihao", p)
        #expect(commits(startDictation(p)) == ["你好"] && p.draft.isEmpty)
    }

    @Test func dictationWithoutACommandInsertsTheTranscript() {
        let (c, _) = composer()
        _ = startDictation(c)
        _ = optionUp(c)
        #expect(commits(c.voiceFinished("你好", id: 1)) == ["你好"])
        #expect(c.phase == .idle)
    }

    @Test func voiceOffNotReadyEmptyAndFailedResults() {
        let (c, _) = composer(voice: false)
        #expect(optionDown(c).isEmpty && c.voiceHoldElapsed().isEmpty && c.voice == .off)
        let (n, _) = composer()
        n.engine = nil
        #expect(optionDown(n).isEmpty)  // dictionaries not ready: no dictation either
        let (d, _) = composer()
        _ = startDictation(d)
        _ = optionUp(d)
        #expect(d.voiceFinished("  ", id: 1).last == .notice("没听清，再说一次"))
        #expect(d.phase == .idle)
        _ = startDictation(d)
        #expect(d.voiceFailed("没有麦克风权限", id: 2).last == .notice("没有麦克风权限"))
        #expect(d.voice == .off && d.phase == .idle)
        #expect(d.voiceText("迟到", id: 2).isEmpty)
        #expect(d.voiceFinished("迟到", id: 2).isEmpty)
    }

    @Test func focusLossKeepsWhatWasHeardAndShiftIsIgnoredWhileListening() {
        let (c, e) = improveDraft()
        type("wo", c)
        _ = c.handleKeyDown(spaceKey)
        _ = startDictation(c)
        _ = c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: [.shift, .option, .rightOption], timestamp: 10.1)
        _ = c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: [.option, .rightOption], timestamp: 10.2)
        #expect(!e.ascii && c.voice == .listening(id: 1, text: ""))
        _ = c.voiceText("今天", id: 1)
        #expect(c.commitAll() == [.cancelVoice(id: 1), .hidePanel, .commit("@improve 我今天")])
        #expect(c.voice == .off && c.phase == .idle)
    }

    @Test func shiftSpaceInAnEnglishDraftIsASpace() {
        let (c, _) = improveDraft(english: true)
        _ = c.handleKeyDown(k("I", mods: .shift))
        let r = c.handleKeyDown(shiftSpace)  // Shift still down from the capital
        #expect(r.handled && c.draft == "@improve I ")
        // Nothing pending: the app's space, in English and in Chinese mode.
        let (d, _) = english()
        #expect(d.handleKeyDown(shiftSpace) == .passThrough)
        let (z, _) = composer()
        #expect(z.handleKeyDown(shiftSpace) == .passThrough && z.phase == .idle)
    }

    /// ⇧Space does exactly what Space does, whatever is pending and with every action key, and
    /// librime never gets Shift+space (a schema may bind it, e.g. to full-width).
    @Test func shiftSpaceIsSpace() {
        func improve(_ c: Composer, _ text: String) {
            _ = c.handleKeyDown(at)
            type("i", c)
            _ = c.handleKeyDown(tab)
            type(text, c)
        }
        func results(_ c: Composer) {
            improve(c, "nihao")
            _ = c.handleKeyDown(spaceKey)
            act(c)
        }
        let states: [(name: String, english: Bool, setUp: (Composer) -> Void)] = [
            ("nothing pending", false, { _ in }),
            ("nothing pending, English", true, { _ in }),
            ("pinyin", false, { type("nihao", $0) }),
            ("the palette", false, { _ = $0.handleKeyDown(at); type("q", $0) }),
            ("pinyin in a command", false, { improve($0, "nihao") }),
            ("a command", false, { improve($0, "nihao"); _ = $0.handleKeyDown(spaceKey) }),
            ("an English command", true, { improve($0, "ok") }),
            ("an English command after a space", true, { improve($0, "ok"); _ = $0.handleKeyDown(spaceKey) }),
            ("results", false, { results($0); _ = $0.receive(final, isFinal: true, id: 1) }),
            ("a failure", false, { results($0); _ = $0.fail("超时", id: 1) }),
            ("dictation", false, { improve($0, ""); _ = startDictation($0) }),
        ]
        for key in ActionKey.allCases {
            for state in states {
                let (c, engine) = composer(key: key)
                let (space, _) = composer(key: key)
                for each in [c, space] {
                    if state.english { each.setInputMode(.english) }
                    state.setUp(each)
                }
                engine.keys.removeAll()
                #expect(c.handleKeyDown(shiftSpace) == space.handleKeyDown(spaceKey), "\(key), \(state.name)")
                #expect(c.draft == space.draft && c.phase == space.phase && c.markedText == space.markedText,
                        "\(key), \(state.name): '\(c.markedText)' / '\(space.markedText)'")
                #expect(!engine.keys.contains { $0.keycode == RimeKey.space && $0.mask & RimeKey.shiftMask != 0 },
                        "\(key), \(state.name): \(engine.keys)")
            }
        }
    }

    @Test func versionsRepeatingTheOriginalAreHidden() {
        let (c, _) = translating()
        _ = c.receive(ConversionResult(versions: [CandidateLine("你好。"), CandidateLine("你好呀！"), CandidateLine("你好呀。")]),
                      isFinal: true, id: 1)
        #expect(c.choices.map(\.text) == ["你好", "你好呀！"])
        #expect(c.choices.map(\.label) == ["0", "1"])
        let (d, _) = translating()
        _ = d.receive(ConversionResult(versions: [CandidateLine("你好。")]), isFinal: true, id: 1)
        #expect(d.phase == .choosing && d.choices.count == 1)  // the model said it's fine as typed
    }

    // MARK: - Action key

    /// Left or right Option going down or up, as modifier changes report it (device bit included).
    func option(_ c: Composer, right: Bool = false, down: Bool, at time: Double) -> [Composer.Effect] {
        c.handleFlagsChanged(keyCode: right ? VirtualKey.rightOption : VirtualKey.leftOption,
                             modifiers: down ? [.option, right ? .rightOption : .leftOption] : [], timestamp: time)
    }

    /// An Option key pressed and released on its own; returns what the release does.
    func tapOption(_ c: Composer, right: Bool = false, at time: Double = 1) -> [Composer.Effect] {
        _ = option(c, right: right, down: true, at: time)
        return option(c, right: right, down: false, at: time + 0.1)
    }

    func startsConversion(_ effects: [Composer.Effect]) -> Bool {
        effects.contains { if case .startConversion = $0 { return true } else { return false } }
    }

    /// Presses the action key `c` is set to; returns what it does.
    @discardableResult
    func act(_ c: Composer) -> [Composer.Effect] {
        switch c.actionKey {
        case .enter: return c.handleKeyDown(enterKey).effects
        case .optionTap: return tapOption(c)
        case .optionSpace: return c.handleKeyDown(optionSpace).effects
        case .space: return c.handleKeyDown(spaceKey).effects
        }
    }

    @Test func returnIsTheDefault() {
        #expect(Composer().actionKey == .enter)
        #expect(Config.default.actionKey == .enter)
    }

    @Test func withoutAnAtCommandItIsARegularInputMethod() {
        let (c, e) = composer(key: .enter)
        type("nihao", c)
        #expect(commits(c.handleKeyDown(spaceKey)) == ["你好"] && c.draft.isEmpty && c.phase == .idle)
        type("nihao", c)
        let raw = c.handleKeyDown(enterKey)  // Return while composing: the letters as typed, no AI
        #expect(commits(raw) == ["nihao"] && !raw.effects.contains { if case .startConversion = $0 { return true } else { return false } })
        #expect(c.handleKeyDown(enterKey) == .passThrough)  // nothing pending: the app's Return
        #expect(tapOption(c).isEmpty)
        // English letters and ⇧Space go straight to the app.
        e.ascii = true
        c.refreshEngineState()
        #expect(c.handleKeyDown(k("o")) == .passThrough && c.handleKeyDown(shiftSpace) == .passThrough)
        // Dictation inserts what was said.
        let (d, _) = composer(key: .enter)
        _ = startDictation(d)
        _ = optionUp(d)
        #expect(commits(d.voiceFinished("你好", id: 1)) == ["你好"] && d.phase == .idle)
    }

    @Test func atCommandsWorkInTheRegularInputMethod() {
        let (c, _) = composer(key: .enter)
        _ = c.handleKeyDown(at)
        type("q", c)
        _ = c.handleKeyDown(enterKey)  // picks @question
        type("nihao", c)
        #expect(c.markedText == "question › nihao" && c.draft == "@question ")  // shown without its "@"; nihao is pinyin
        #expect(c.handleKeyDown(enterKey).effects.first == .startCommand(.question, input: "你好", id: 1))
        _ = c.receive(ConversionResult(versions: [CandidateLine("你好是问候语。")]), isFinal: true, id: 1)
        #expect(commits(c.handleKeyDown(enterKey)) == ["你好是问候语。"])
        // @improve is the translation; dictation fills a command.
        let (i, _) = composer(key: .enter)
        _ = i.handleKeyDown(at)
        type("i", i)
        _ = i.handleKeyDown(tab)
        _ = startDictation(i)
        _ = optionUp(i)
        _ = i.voiceFinished("我今天有点不舒服", id: 1)
        #expect(i.draft == "@improve 我今天有点不舒服")
        #expect(i.handleKeyDown(enterKey).effects.first == .startConversion(input: "我今天有点不舒服", id: 1))
    }

    /// Without an @ command nothing is ever sent, whatever the action key: picks and Return go into
    /// the text, the action key does nothing, and English and dictation go straight in.
    @Test func aPlainSentenceAndReturnNeverStartAConversion() {
        func sends(_ effects: [Composer.Effect]) -> Bool {
            effects.contains {
                switch $0 {
                case .startConversion, .startCommand, .search, .runInTerminal: return true
                default: return false
                }
            }
        }
        for key in ActionKey.allCases {
            let (c, e) = composer(key: key)
            var effects: [Composer.Effect] = []
            func press(_ event: KeyEvent) -> Composer.Response {
                let r = c.handleKeyDown(event)
                effects += r.effects
                return r
            }
            for word in ["wo", "jintian"] {
                type(word, c)
                _ = press(spaceKey)
            }
            _ = press(k(","))
            type("nihao", c)
            _ = press(enterKey)  // the letters as typed
            #expect(press(enterKey) == .passThrough, "\(key)")  // nothing pending: the app's Return
            #expect(act(c).isEmpty, "\(key)")  // nothing to run
            e.ascii = true
            c.refreshEngineState()
            #expect(press(k("o")) == .passThrough && press(enterKey) == .passThrough, "\(key)")
            e.ascii = false
            c.refreshEngineState()
            _ = startDictation(c)
            _ = optionUp(c)
            effects += c.voiceFinished("你好", id: 1)
            #expect(press(enterKey) == .passThrough, "\(key)")
            #expect(commits(effects) == ["我", "今天", "，", "nihao", "你好"], "\(key): \(commits(effects))")
            #expect(!sends(effects) && c.phase == .idle && c.draft.isEmpty, "\(key): \(effects)")
        }
    }

    let shiftReturn = KeyEvent(keyCode: VirtualKey.returnKey, characters: "\r", modifiers: .shift)

    @Test func returnRunsTheAction() {
        // On pinyin still being typed (converted first), and on a draft.
        let (c, _) = improveDraft(key: .enter)
        type("nihao", c)
        #expect(c.handleKeyDown(enterKey).effects.first == .startConversion(input: "你好", id: 1))
        // In the results it inserts the highlighted line; after a failure it asks again.
        _ = c.receive(final, isFinal: true, id: 1)
        #expect(commits(c.handleKeyDown(enterKey)) == ["Hi there."])
        let (d, _) = improveDraft(key: .enter)
        type("nihao", d)
        _ = d.handleKeyDown(spaceKey)
        _ = d.handleKeyDown(enterKey)
        _ = d.fail("超时", id: 1)
        #expect(d.handleKeyDown(enterKey).effects.first == .startConversion(input: "你好", id: 2))
        #expect(commits(d.handleKeyDown(k("0"))) == ["你好"])  // still streaming: 0 is always ready
        // An English draft is polished too.
        let (e, _) = improveDraft(key: .enter, english: true)
        type("ok", e)
        #expect(e.handleKeyDown(enterKey).effects.first == .startConversion(input: "ok", id: 1))
        // Nothing pending: Return is the app's.
        let (idle, _) = composer(key: .enter)
        #expect(idle.handleKeyDown(enterKey) == .passThrough)
    }

    @Test func shiftReturnInsertsAsTyped() {
        let (c, _) = improveDraft(key: .enter)
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(commits(c.handleKeyDown(shiftReturn)) == ["@improve 你好"] && c.phase == .idle)
        // An English command too (the key itself is used up).
        let (e, _) = improveDraft(key: .enter, english: true)
        type("ok", e)
        let r = e.handleKeyDown(shiftReturn)
        #expect(r.handled && commits(r) == ["@improve ok"])
        // With another action key, @ commands run on Return anyway.
        let (q, _) = composer(key: .optionTap)
        _ = q.handleKeyDown(at)
        type("q", q)
        _ = q.handleKeyDown(tab)
        type("nihao", q)
        #expect(q.handleKeyDown(enterKey).effects.first == .startCommand(.question, input: "你好", id: 1))
    }

    @Test func returnWhileDictatingSendsOnceRecognized() {
        // Right ⌥ is still down, so the key arrives as ⌥Return.
        let (c, _) = improveDraft(key: .enter)
        _ = startDictation(c)
        _ = c.voiceText("你好", id: 1)
        let optionReturn = KeyEvent(keyCode: VirtualKey.returnKey, characters: "\r", modifiers: .option)
        #expect(c.handleKeyDown(optionReturn) == .consumed([.stopVoice(id: 1), .showPanel]) && c.actsAfterVoice)
        #expect(c.voiceFinished("你好吗", id: 1).first == .startConversion(input: "你好吗", id: 1))
    }

    @Test func messagesFollowTheInterfaceLanguage() {
        let (c, _) = composer()
        c.messages = .english
        _ = c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: .shift, timestamp: 1)
        #expect(c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: [], timestamp: 1.1).last == .notice("English"))
        let (d, _) = composer()
        d.messages = .english
        #expect(tapOption(d, right: true) == [.notice("Hold right ⌥ to talk")])
        let (t, _) = translating()
        t.messages = .english
        _ = t.receive(.empty, isFinal: true, id: 1)
        #expect(t.phase == .failed("No result"))
        let n = Composer(engine: nil)
        n.messages = .english
        #expect(n.handleKeyDown(k("n")).effects == [.notice("Loading the dictionaries, one moment")])
    }

    @Test func optionSpaceActsAndSpaceStaysASpace() {
        let (c, _) = improveDraft(key: .optionSpace)
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)  // picks 你好
        #expect(c.draft == "@improve 你好" && !c.spaceActs)
        let r = c.handleKeyDown(spaceKey)
        #expect(r.handled && commits(r).isEmpty && c.draft == "@improve 你好 " && c.phase == .drafting)  // just a space
        #expect(c.handleKeyDown(optionSpace).effects == [.startConversion(input: "你好", id: 1), .updateMarkedText, .showPanel,
                                                      .commandUsed("improve")])
        #expect(c.phase == .translating(id: 1))
    }

    @Test func optionSpaceConvertsPinyinStillBeingTyped() {
        let (c, _) = improveDraft(key: .optionSpace)
        type("nihao", c)
        #expect(c.handleKeyDown(optionSpace).effects.first == .startConversion(input: "你好", id: 1))
        #expect(c.draft == "@improve 你好" && !c.engineState.isComposing)
        // A long input can take several picks (我, then 今天), like pressing Space until it's done.
        let (d, _) = improveDraft(key: .optionSpace)
        type("wojintian", d)
        #expect(d.engineState.candidates.first?.text == "我")
        #expect(d.handleKeyDown(optionSpace).effects.first == .startConversion(input: "我今天", id: 1))
        // Words already picked stay; the highlighted candidate is the one taken.
        let (e, _) = improveDraft(key: .optionSpace)
        type("wo", e)
        _ = e.handleKeyDown(spaceKey)
        type("nihao", e)
        _ = e.handleKeyDown(downKey)
        #expect(e.handleKeyDown(optionSpace).effects.first == .startConversion(input: "我拟好", id: 1))
    }

    @Test func optionSpaceWithNothingToSendReachesTheApp() {
        let (c, _) = composer(key: .optionSpace)
        #expect(c.handleKeyDown(optionSpace) == .passThrough)
    }

    @Test func optionSpaceInLevelTwoAcceptsLikeSpace() {
        let (c, _) = improveDraft(key: .optionSpace)
        type("nihao", c)
        _ = c.handleKeyDown(optionSpace)
        #expect(c.handleKeyDown(optionSpace) == .consumed())  // waits for the first line
        _ = c.receive(final, isFinal: true, id: 1)
        #expect(commits(c.handleKeyDown(optionSpace)) == ["Hi there."])
        let (d, _) = improveDraft(key: .optionSpace)
        type("nihao", d)
        _ = d.handleKeyDown(optionSpace)
        _ = d.fail("超时", id: 1)
        #expect(d.handleKeyDown(optionSpace).effects.first == .startConversion(input: "你好", id: 2))  // retry
        let (e, _) = improveDraft(key: .optionSpace)
        type("nihao", e)
        _ = e.handleKeyDown(optionSpace)
        _ = e.receive(final, isFinal: true, id: 1)
        #expect(commits(e.handleKeyDown(spaceKey)) == ["Hi there."])  // Space still inserts
    }

    @Test func optionSpaceInAnEnglishDraft() {
        let (c, _) = improveDraft(key: .optionSpace, english: true)
        type("ok", c)
        _ = c.handleKeyDown(spaceKey)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.draft == "@improve ok  " && c.isLatinDraft && c.phase == .drafting)  // no double-Space trigger
        #expect(c.handleKeyDown(optionSpace).effects.first == .startConversion(input: "ok", id: 1))
    }

    @Test func spaceTranslatesOnlyWithTheSpaceKey() {
        for key in ActionKey.allCases {
            let (c, _) = improveDraft(key: key)
            type("nihao", c)
            _ = c.handleKeyDown(spaceKey)
            #expect(c.spaceActs == (key == .space), "\(key)")
        }
        // With the Space key, ⌥Space is an ordinary key (it types a no-break space).
        let (s, _) = improveDraft(key: .space)
        type("nihao", s)
        _ = s.handleKeyDown(spaceKey)
        #expect(!startsConversion(s.handleKeyDown(optionSpace).effects) && s.draft == "@improve 你好\u{A0}")
    }

    @Test func optionTapActs() {
        let (c, _) = improveDraft(key: .optionTap)
        type("nihao", c)  // pending pinyin is converted first
        #expect(tapOption(c).first == .startConversion(input: "你好", id: 1))
        _ = c.receive(final, isFinal: true, id: 1)
        #expect(commits(tapOption(c, at: 5)) == ["Hi there."])  // in level two a tap accepts
        // Space in the draft is a space, ⌥Space is not special; a tap of right ⌥ also sends (voice on).
        let (d, _) = improveDraft(key: .optionTap)
        type("nihao", d)
        _ = d.handleKeyDown(spaceKey)
        _ = d.handleKeyDown(spaceKey)
        #expect(d.draft == "@improve 你好 " && d.phase == .drafting)
        #expect(option(d, right: true, down: true, at: 1) == [.armVoice(delay: Composer.voiceArmDelay)])
        #expect(option(d, right: true, down: false, at: 1.1).first == .startConversion(input: "你好", id: 1))
        #expect(d.voiceHoldElapsed().isEmpty && d.voice == .off)  // the tap disarmed dictation
    }

    @Test func whatIsNotAnOptionTap() {
        let (c, _) = improveDraft(key: .optionTap)
        type("nihao", c)
        // Held too long.
        _ = option(c, down: true, at: 1)
        #expect(option(c, down: false, at: 2).isEmpty)
        // An ⌥ shortcut: a key in between (⌥←).
        _ = option(c, down: true, at: 3)
        _ = c.handleKeyDown(KeyEvent(keyCode: VirtualKey.left, characters: "\u{F702}", modifiers: .option))
        #expect(option(c, down: false, at: 3.1).isEmpty)
        // Another modifier in between (⌥⇧).
        _ = option(c, down: true, at: 4)
        _ = c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: [.option, .leftOption, .shift], timestamp: 4.03)
        _ = c.handleFlagsChanged(keyCode: VirtualKey.leftShift, modifiers: [.option, .leftOption], timestamp: 4.06)
        #expect(option(c, down: false, at: 4.1).isEmpty)
        // Both Option keys.
        _ = option(c, down: true, at: 5)
        _ = c.handleFlagsChanged(keyCode: VirtualKey.rightOption, modifiers: [.option, .leftOption, .rightOption], timestamp: 5.03)
        _ = c.handleFlagsChanged(keyCode: VirtualKey.rightOption, modifiers: [.option, .leftOption], timestamp: 5.06)
        #expect(option(c, down: false, at: 5.1).isEmpty)
        #expect(c.phase == .drafting && c.engineState.isComposing)
        // Nothing pending: left ⌥ does nothing, right ⌥ shows the voice hint as before.
        let (d, _) = composer(key: .optionTap)
        #expect(tapOption(d).isEmpty)
        #expect(tapOption(d, right: true) == [.notice("按住右 ⌥ 说话")])
        // With the other action keys a tap does nothing.
        for key in [ActionKey.optionSpace, .space] {
            let (e, _) = improveDraft(key: key)
            type("nihao", e)
            #expect(tapOption(e).isEmpty && e.phase == .drafting, "\(key)")
        }
    }

    @Test func actionKeyDuringDictationSendsOnceTheTranscriptIsFinal() {
        // ⌥Space while still holding right ⌥: the recording stops; the sentence goes with the final transcript.
        let (c, _) = improveDraft(key: .optionSpace)
        type("wo", c)
        _ = c.handleKeyDown(spaceKey)
        _ = startDictation(c)
        _ = c.voiceText("今天", id: 1)
        #expect(c.handleKeyDown(optionSpace) == .consumed([.stopVoice(id: 1), .showPanel]))
        #expect(c.voice == .finishing(id: 1, text: "今天") && c.actsAfterVoice)
        #expect(optionUp(c).isEmpty)  // releasing the key afterwards changes nothing
        #expect(c.voiceFinished("今天有点不舒服", id: 1).first == .startConversion(input: "我今天有点不舒服", id: 1))
        #expect(c.phase == .translating(id: 1) && !c.actsAfterVoice)

        // Released first, then an Option tap while the transcript is still being finished.
        let (d, _) = improveDraft(key: .optionTap)
        _ = startDictation(d)
        _ = optionUp(d)
        #expect(tapOption(d, at: 3) == [.showPanel] && d.actsAfterVoice)
        #expect(d.voiceFinished("你好", id: 1).first == .startConversion(input: "你好", id: 1))

        // Another key before the transcript arrives: nothing is sent, the key continues the sentence.
        let (e, _) = improveDraft(key: .optionSpace)
        _ = startDictation(e)
        _ = e.voiceText("你好", id: 1)
        _ = e.handleKeyDown(optionSpace)
        #expect(!startsConversion(e.handleKeyDown(k("m")).effects))
        #expect(e.draft == "@improve 你好" && e.markedText == "improve › 你好m" && !e.actsAfterVoice)

        // Esc, a failure or nothing heard: nothing is sent.
        let (f, _) = improveDraft(key: .optionSpace)
        _ = startDictation(f)
        _ = f.handleKeyDown(optionSpace)
        _ = f.handleKeyDown(escKey)
        #expect(f.voice == .off && !f.actsAfterVoice && f.draft == "@improve ")
        _ = startDictation(f)
        _ = f.handleKeyDown(optionSpace)
        #expect(f.voiceFailed("没有麦克风权限", id: 2).last == .notice("没有麦克风权限") && !f.actsAfterVoice)
        _ = startDictation(f)
        _ = f.handleKeyDown(optionSpace)
        #expect(f.voiceFinished(" ", id: 3).last == .notice("没听清，再说一次") && f.draft == "@improve ")
    }

    // MARK: - @ commands

    let at = KeyEvent(keyCode: 0x13, characters: "@", charactersIgnoringModifiers: "@", modifiers: .shift)
    let tab = KeyEvent(keyCode: VirtualKey.tab, characters: "\t")

    /// A composer (action key: a tap of ⌥) with "@" typed.
    func palette(_ query: String = "", english: Bool = false) -> (Composer, FakeEngine) {
        let (c, e) = composer(key: .optionTap)
        if english { c.setInputMode(.english) }
        _ = c.handleKeyDown(at)
        type(query, c)
        return (c, e)
    }

    @Test func atStartsTheCommandPalette() {
        let (c, _) = composer(key: .optionTap)
        #expect(c.handleKeyDown(at) == .consumed([.updateMarkedText, .showPanel]))
        #expect(c.draft == "@" && c.markedText == "@" && c.paletteQuery == "" && c.wantsPanel)
        #expect(Array(c.paletteVisible) == [.improve, .question, .claude, .open, .read] && c.paletteMatches.count == 12)
        type("q", c)
        #expect(c.paletteMatches == [.question] && c.markedText == "q" && c.draft == "@q")
        #expect(c.handleKeyDown(tab).effects == [.updateMarkedText, .showPanel])
        #expect(c.draft == "@question " && c.paletteQuery == nil && c.draftCommand == .question)
        // Space, a digit or the action key pick too; ↑↓ move the highlight.
        let (s, _) = palette("cl")
        _ = s.handleKeyDown(spaceKey)
        #expect(s.draft == "@claude ")
        let (d, _) = palette()
        _ = d.handleKeyDown(k("4"))
        #expect(d.draft == "@open ")
        let (t, _) = palette("o")
        _ = tapOption(t)
        #expect(t.draft == "@open " && t.phase == .drafting)
        let (a, _) = palette()
        _ = a.handleKeyDown(downKey)
        #expect(a.paletteHighlighted == 1)
        _ = a.handleKeyDown(upKey)
        _ = a.handleKeyDown(upKey)
        #expect(a.paletteHighlighted == 11 && a.paletteFirstVisible == 7)  // around to the last, scrolled to it
        _ = a.handleKeyDown(upKey)
        _ = a.handleKeyDown(tab)
        #expect(a.draft == "@tasks ")
    }

    @Test func atMentionsStillReachTheApp() {
        // A letter no command starts with: "@" goes in as typed, and the letter is pinyin as usual.
        let (c, e) = palette()
        let r = c.handleKeyDown(k("z"))
        #expect(commits(r) == ["@"] && r.handled && e.input == "z" && c.draft.isEmpty)
        // In English mode the letter then goes to the app.
        let (d, _) = palette("cl", english: true)
        let r2 = d.handleKeyDown(k("x"))
        #expect(commits(r2) == ["@cl"] && !r2.handled && d.draft.isEmpty)
        let (o, _) = palette(english: true)
        let r3 = o.handleKeyDown(k("w"))  // in no command's name ("j" is in @js, "k" in @tasks)
        #expect(commits(r3) == ["@"] && !r3.handled)
        // "@ " is just an at sign and a space; Return inserts "@…" as typed; Esc and ⌫ remove it.
        let (s, _) = palette()
        #expect(commits(s.handleKeyDown(spaceKey)) == ["@"])
        let (n, _) = palette("que")
        #expect(commits(n.handleKeyDown(enterKey)).isEmpty && n.draft == "@question ")  // Return picks, like Tab
        let (lone, _) = palette()
        #expect(commits(lone.handleKeyDown(enterKey)) == ["@"])
        let (x, _) = palette("que")
        #expect(x.handleKeyDown(escKey).effects == [.updateMarkedText, .hidePanel] && x.draft.isEmpty)
        let (b, _) = palette("q")
        _ = b.handleKeyDown(backspaceKey)
        #expect(b.draft == "@")
        #expect(b.handleKeyDown(backspaceKey).effects == [.updateMarkedText, .hidePanel] && b.phase == .idle)
        // "@" inside a command offers the commands that run in a text (@read); a letter none of them
        // starts with leaves the "@" as text (a mention). After words already inserted it opens the commands.
        let (m, me) = improveDraft(key: .optionTap)
        type("nihao", m)
        _ = m.handleKeyDown(spaceKey)
        _ = m.handleKeyDown(at)
        #expect(m.draft == "@improve 你好@" && m.paletteQuery == "")
        type("x", m)
        #expect(m.draft == "@improve 你好@" && m.paletteQuery == nil && me.input == "x")
        let (w, _) = composer(key: .optionTap)
        type("nihao", w)
        #expect(commits(w.handleKeyDown(spaceKey)) == ["你好"])
        #expect(w.handleKeyDown(at) == .consumed([.updateMarkedText, .showPanel]) && w.paletteQuery == "")
    }

    @Test func commandDraftsGoToTheirCommand() {
        func send(_ name: String, _ pinyin: String) -> (Composer, [Composer.Effect]) {
            let (c, _) = palette(name)
            _ = c.handleKeyDown(tab)
            type(pinyin, c)
            return (c, tapOption(c, at: 5))
        }
        #expect(send("q", "nihao").1.first == .startCommand(.question, input: "你好", id: 1))
        let (claude, terminal) = send("c", "nihao")
        #expect(terminal.contains(.runInTerminal(prompt: "你好")) && commits(terminal).isEmpty)
        #expect(claude.phase == .idle && claude.markedText.isEmpty && !claude.isLevelTwo)  // the session has its own window
        let (open, search) = send("o", "nihao")
        #expect(search.first == .search(query: "nihao", id: 1))  // @open takes letters as typed (file names, paths)
        #expect(open.engineState.isAsciiMode)
        #expect(send("i", "nihao").1.first == .startConversion(input: "你好", id: 1))  // @improve: the default
        let (marked, _) = send("q", "nihao")
        #expect(marked.markedText == "question › 你好" && marked.activeCommand == .question)
        // Nothing after the command: the clipboard's text is asked for; without any, a hint, no request.
        let (e, _) = palette("q")
        _ = e.handleKeyDown(tab)
        #expect(tapOption(e) == [.readClipboard(id: 1)] && !e.isLevelTwo)
        #expect(e.pasted(nil, id: 1) == [.notice("在命令后面写上内容")] && !e.isLevelTwo)
    }

    @Test func customCommandsGoToTheirCommand() {
        let python = CustomCommand(name: "python", type: .run, argv: ["python3", "-c", "{input}"])
        let reply = CustomCommand(name: "reply", type: .prompt, prompt: "Write a reply.")
        let sh = CustomCommand(name: "sh", type: .terminal, argv: ["zsh", "-c", "{input}"])
        let catalog = Command.catalog([python, reply, sh])
        func start(_ name: String) -> Composer {
            let (c, _) = composer(key: .optionTap)
            c.commands = catalog
            _ = c.handleKeyDown(at)
            type(name, c)
            _ = c.handleKeyDown(tab)
            return c
        }
        // The palette offers them after the built-in ones.
        let (p, _) = composer(key: .optionTap)
        p.commands = catalog
        _ = p.handleKeyDown(at)
        // At most five: the built-in four and the first custom one (nothing used yet).
        #expect(p.paletteVisible.map(\.name) == ["improve", "question", "claude", "open", "read"])
        // @python: code is typed as letters, the program runs, and Chinese comes back after.
        let py = start("pyt")  // "py" alone is the built-in @py
        #expect(py.draft == "@python " && py.engineState.isAsciiMode)
        type("print(1)", py)
        let run = tapOption(py, at: 5)
        #expect(run.first == .startRun(catalog.first { $0.name == "python" }!, input: "print(1)", id: 1) && py.activeCommand?.kind == .run)
        #expect(py.receive(ConversionResult(versions: [CandidateLine("1")]), isFinal: true, id: 1) == [.showPanel])
        #expect(py.choices.map(\.kind) == [.original, .answer] && py.highlighted == 1)
        #expect(commits(py.handleKeyDown(spaceKey)) == ["1"] && !py.engineState.isAsciiMode)
        // A prompt command goes to the model like @question, typed in pinyin.
        let r = start("rep")  // "r" alone is @read first
        #expect(!r.engineState.isAsciiMode)
        type("nihao", r)
        #expect(tapOption(r, at: 5).first == .startCommand(catalog.first { $0.name == "reply" }!, input: "你好", id: 1))
        // A terminal command starts its window with the text as one argument; nothing is inserted.
        let t = start("sh")  // "s" alone is @settings first
        type("ls", t)
        let terminal = tapOption(t, at: 5)
        #expect(terminal.contains(.launchInTerminal(argv: ["zsh", "-c", "ls"])) && commits(terminal).isEmpty && !t.isLevelTwo)
        let refused = start("sh")
        type("ls", refused)
        refused.secureInputActive = { true }
        #expect(!tapOption(refused, at: 5).contains { if case .launchInTerminal = $0 { return true } else { return false } })
    }

    @Test func commandsKnowTheirProgram() {
        let python = CustomCommand(name: "python", type: .run, argv: ["python3", "-c", "{input}"])
        let reply = CustomCommand(name: "reply", type: .prompt, prompt: "Write a reply.")
        #expect(Command.catalog([python, reply]).map(\.program)
            == [nil, nil, "claude", nil, nil, nil, nil, nil, "python3", nil, nil, nil, "python3", nil])  // @py needs python3 too
    }

    @Test func theListPutsWhatIsRunMostFirst() {
        let catalog = Command.catalog(["reply", "sh", "calc"].map { CustomCommand(name: $0, type: .prompt, prompt: "x") })
        let (c, _) = composer(key: .optionTap)
        c.commands = catalog
        // Running @calc counts it, and says so to the controller (which keeps it).
        _ = c.handleKeyDown(at)
        type("ca", c)
        _ = c.handleKeyDown(tab)
        type("nihao", c)
        #expect(tapOption(c, at: 5).contains(.commandUsed("calc")))
        #expect(c.commandUsage.score("calc") > 0)
        // Next time "@" lists it first; the digit picks from what's shown.
        let (d, _) = composer(key: .optionTap)
        d.commands = catalog
        d.commandUsage = c.commandUsage
        _ = d.handleKeyDown(at)
        #expect(d.paletteVisible.map(\.name) == ["calc", "improve", "question", "claude", "open"])
        _ = d.handleKeyDown(k("1"))
        #expect(d.draft == "@calc ")
        // A command beyond the five is found by its letters.
        let (e, _) = composer(key: .optionTap)
        e.commands = catalog
        _ = e.handleKeyDown(at)
        type("s", e)
        #expect(e.paletteMatches.map(\.name) == ["settings", "sh", "question", "js", "tasks"])  // names starting with s first
        // Picking from the list doesn't count: only running does.
        _ = e.handleKeyDown(tab)
        #expect(e.commandUsage.score("sh") == 0)
    }

    @Test func theListComesBackInsideATextForCommandsThatRunThere() {
        let catalog = Command.catalog([CustomCommand(name: "reply", type: .prompt, prompt: "x"),
                                       CustomCommand(name: "stock", type: .run, argv: ["stock", "{input}"])])
        func started() -> (Composer, FakeEngine) {
            let (c, e) = composer(key: .enter)
            c.commands = catalog
            _ = c.handleKeyDown(at)
            type("rep", c)
            _ = c.handleKeyDown(tab)
            type("nihao", c)
            _ = c.handleKeyDown(spaceKey)
            _ = c.handleKeyDown(at)
            return (c, e)
        }
        let (c, e) = started()
        #expect(c.draft == "@reply 你好@" && c.paletteQuery == "")
        #expect(c.paletteMatches.map(\.name) == ["read", "calc", "py", "js", "stock"])  // only what runs inside a text
        type("s", c)
        #expect(c.draft == "@reply 你好@s" && c.paletteMatches.map(\.name) == ["stock", "js"])
        _ = c.handleKeyDown(tab)
        #expect(c.draft == "@reply 你好@stock " && e.ascii)  // letters for the symbol
        type("AAPL", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.draft == "@reply 你好@stock AAPL " && !e.ascii)  // Chinese again for the rest
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.draft == "@reply 你好@stock AAPL 你好")
        #expect(c.paletteQuery == nil)

        // Esc takes back only the "@…"; a letter no such command starts with is pinyin as usual.
        let (d, _) = started()
        type("s", d)
        _ = d.handleKeyDown(escKey)
        #expect(d.draft == "@reply 你好")
        let (f, g) = started()
        type("wo", f)
        #expect(f.draft == "@reply 你好@" && g.input == "wo")
    }

    /// Slack turns an "@…" being typed into a mention and takes the composition: the text shown while
    /// typing has no command "@", and a taken composition starts over instead of showing up twice.
    @Test func noAtForSlackToTurnIntoAMention() {
        let catalog = Command.catalog([CustomCommand(name: "stock", type: .run, argv: ["stock", "{input}"])])
        let (c, _) = composer(key: .enter)
        c.commands = catalog
        _ = c.handleKeyDown(at)
        #expect(c.markedText == "@")  // alone it may be a mention
        type("imp", c)
        #expect(c.markedText == "imp" && c.markedCursor == 3)  // picking a command
        _ = c.handleKeyDown(tab)
        #expect(c.markedText == "improve › " && c.markedCursor == 10)
        _ = c.handleKeyDown(backspaceKey)  // back to the name: still no "@"
        #expect(c.draft == "@improve" && c.markedText == "improve")
        _ = c.handleKeyDown(tab)
        type("nihao", c)
        #expect(c.markedText == "improve › nihao")
        _ = c.handleKeyDown(spaceKey)
        // A command inside the text, and a mention there (full-width: no mention list, sent as typed).
        _ = c.handleKeyDown(at)
        type("st", c)
        #expect(c.markedText == "improve › 你好st")
        _ = c.handleKeyDown(tab)
        type("AAPL", c)
        _ = c.handleKeyDown(spaceKey)
        _ = c.handleKeyDown(at)
        type("bob", c)  // pinyin again after the symbol
        #expect(c.draft == "@improve 你好@stock AAPL @")
        #expect(c.markedText == "improve › 你好stock › AAPL ＠bob")
    }

    @Test func aTakenCompositionStartsOver() {
        // An app that reports its marked text: taken when it reports none while a draft is pending.
        var watch = MarkedTextWatch()
        #expect(!watch.appTookText(expected: "improve › 你好", reportedLength: nil))  // never seen it report: unknown
        watch.didSet(expected: "improve › 你好", reportedLength: 12)
        #expect(watch.appReportsMarkedText)
        #expect(!watch.appTookText(expected: "improve › 你好", reportedLength: 12))
        #expect(watch.appTookText(expected: "improve › 你好", reportedLength: 0))
        #expect(watch.appTookText(expected: "improve › 你好", reportedLength: nil))
        #expect(!watch.appTookText(expected: "", reportedLength: nil))  // nothing pending
        watch.reset()
        #expect(!watch.appTookText(expected: "x", reportedLength: nil))
        // The composer then forgets the draft: nothing inserted, nothing sent, the panel hidden.
        let (c, e) = composer(key: .enter)
        _ = c.handleKeyDown(at)
        type("q", c)
        _ = c.handleKeyDown(tab)
        type("nihao", c)
        let effects = c.appTookMarkedText()
        #expect(effects == [.hidePanel] && commits(effects).isEmpty)
        #expect(c.draft.isEmpty && c.markedText.isEmpty && c.phase == .idle && e.input.isEmpty)
        // During a request it is cancelled.
        let (t, _) = translating()
        #expect(t.appTookMarkedText() == [.cancelConversion, .hidePanel] && t.phase == .idle)
    }

    /// All the commands are in the list, five shown at a time: the highlight scrolls the rest into view.
    @Test func theListScrolls() {
        let catalog = Command.catalog(["alpha", "bravo", "charlie"].map { CustomCommand(name: $0, type: .prompt, prompt: "x") })
        let (c, _) = composer(key: .optionTap)
        c.commands = catalog
        _ = c.handleKeyDown(at)
        #expect(c.paletteMatches.count == 15 && c.paletteVisible.count == 5 && c.paletteFirstVisible == 0)
        for _ in 0..<5 { _ = c.handleKeyDown(downKey) }  // past the fifth: scrolls by one
        #expect(c.paletteHighlighted == 5 && c.paletteFirstVisible == 1)
        #expect(c.paletteVisible.map(\.name) == ["question", "claude", "open", "read", "note"])
        _ = c.handleKeyDown(k("2"))  // the second row shown, not the second command
        #expect(c.draft == "@claude ")
        // The wheel stops at the ends; a click picks among the rows shown.
        let (d, _) = composer(key: .optionTap)
        d.commands = catalog
        _ = d.handleKeyDown(at)
        #expect(d.scrollPalette(by: 100) == [.showPanel] && d.paletteHighlighted == 14 && d.paletteFirstVisible == 10)
        #expect(d.paletteVisible.map(\.name) == ["tasks", "settings", "alpha", "bravo", "charlie"])
        _ = d.scrollPalette(by: -2)
        #expect(d.paletteHighlighted == 12 && d.paletteFirstVisible == 10)  // still in view: no scrolling
        _ = d.choose(index: 2)
        #expect(d.draft == "@alpha ")
        // Typing letters starts again at the top.
        let (e, _) = composer(key: .optionTap)
        e.commands = catalog
        _ = e.handleKeyDown(at)
        for _ in 0..<8 { _ = e.handleKeyDown(downKey) }
        type("a", e)
        #expect(e.paletteHighlighted == 0 && e.paletteFirstVisible == 0 && e.paletteMatches.first?.name == "alpha")
    }

    @Test func claudeIsNotStartedWhileSecureInputIsOn() {
        let (c, _) = palette("c")
        _ = c.handleKeyDown(tab)
        type("nihao", c)
        c.secureInputActive = { true }
        // Nothing goes to Claude Code; the text (pinyin converted) stays to be sent later or inserted.
        let refused = tapOption(c, at: 5)
        #expect(refused.contains(.notice("系统安全输入已开启（密码框或锁屏），没有打开 Claude Code")))
        #expect(refused.contains(.updateMarkedText) && !refused.contains(.runInTerminal(prompt: "你好")))
        #expect(c.markedText == "claude › 你好" && c.draft == "@claude 你好" && !c.isLevelTwo)
        c.secureInputActive = { false }
        #expect(tapOption(c, at: 7).contains(.runInTerminal(prompt: "你好")))
    }

    @Test func answersAreInsertedLikeVersions() {
        let (c, _) = palette("q")
        _ = c.handleKeyDown(tab)
        type("nihao", c)
        _ = tapOption(c)
        #expect(c.choices.map(\.kind) == [.original] && c.highlighted == 1)
        _ = c.receive(ConversionResult(versions: [CandidateLine("你好的意思", isComplete: false)]), isFinal: false, id: 1)
        #expect(c.handleKeyDown(enterKey) == .consumed())  // still streaming
        _ = c.receive(ConversionResult(versions: [CandidateLine("“你好”是问候语。")]), isFinal: true, id: 1)
        #expect(c.phase == .choosing && c.choices.map(\.kind) == [.original, .answer])
        #expect(c.choices.first?.text == "你好")  // the question, without "@question"
        #expect(commits(c.handleKeyDown(enterKey)) == ["“你好”是问候语。"])
        // 0 inserts the question; without an answer the request failed.
        let (d, _) = palette("q")
        _ = d.handleKeyDown(tab)
        type("nihao", d)
        _ = tapOption(d)
        _ = d.receive(.empty, isFinal: true, id: 1)
        #expect(d.phase == .failed("没有得到结果"))
        #expect(commits(d.handleKeyDown(enterKey)) == ["你好"])
    }

    @Test func openPicksAFileWithoutInsertingText() {
        let calculator = SearchResult(name: "Calculator", path: "/System/Applications/Calculator.app")
        let (c, _) = palette("o", english: true)
        _ = c.handleKeyDown(tab)
        type("calc", c)
        #expect(tapOption(c).first == .search(query: "calc", id: 1))
        #expect(c.receiveSearch([calculator, SearchResult(name: "calc.txt", path: "/tmp/calc.txt")], id: 1) == [.showPanel])
        #expect(c.choices.map(\.label) == ["1", "2"] && c.highlighted == 0)
        let r = c.handleKeyDown(spaceKey)
        #expect(r.effects.last == .open(path: calculator.path) && commits(r).isEmpty)
        #expect(c.phase == .idle && c.draft.isEmpty && c.markedText.isEmpty)
        // A digit picks; nothing found is a failure; stale results are ignored.
        let (d, _) = palette("o", english: true)
        _ = d.handleKeyDown(tab)
        type("calc", d)
        _ = tapOption(d)
        _ = d.handleKeyDown(escKey)
        #expect(d.receiveSearch([calculator], id: 1).isEmpty && d.phase == .drafting)
        _ = tapOption(d, at: 9)
        _ = d.receiveSearch([calculator, SearchResult(name: "calc.txt", path: "/tmp/calc.txt")], id: 2)
        #expect(d.handleKeyDown(k("2")).effects.last == .open(path: "/tmp/calc.txt"))
        let (n, _) = palette("o", english: true)
        _ = n.handleKeyDown(tab)
        type("zzz", n)
        _ = tapOption(n)
        _ = n.receiveSearch([], id: 1)
        #expect(n.phase == .failed("没有找到"))
    }

    @Test func holdingRightOptionInThePaletteDictatesTheCommand() {
        let (c, _) = palette("q")
        _ = startDictation(c)
        #expect(c.draft == "@question ")
        _ = optionUp(c)
        _ = c.voiceFinished("什么是量子计算", id: 1)
        #expect(c.draft == "@question 什么是量子计算")
        #expect(tapOption(c, at: 5).first == .startCommand(.question, input: "什么是量子计算", id: 1))
    }

    @Test func openShowsResultsAsYouTypeAndCompletesPaths() {
        let documents = SearchResult(name: "Documents", path: "/Users/me/Documents", isFolder: true)
        let report = SearchResult(name: "report.pdf", path: "/Users/me/Documents/report.pdf")
        let (c, _) = composer(key: .enter)
        _ = c.handleKeyDown(at)
        type("o", c)
        _ = c.handleKeyDown(tab)
        #expect(c.engineState.isAsciiMode && c.liveQuery == nil)  // letters for the path, nothing typed yet
        type("~/Doc", c)
        #expect(c.liveQuery == "~/Doc" && c.currentLiveResults.isEmpty)
        #expect(c.receiveLive([documents], for: "~/Do").isEmpty)  // stale: the text has changed since
        #expect(c.receiveLive([documents, report], for: "~/Doc") == [.showPanel])
        _ = c.handleKeyDown(downKey)
        #expect(c.liveHighlight == 1)
        _ = c.handleKeyDown(upKey)
        // Tab: the highlighted path replaces what was typed; a folder's ends in "/", which lists it.
        #expect(c.handleKeyDown(tab).effects == [.updateMarkedText, .showPanel])
        #expect(c.draft == "@open /Users/me/Documents/" && c.currentLiveResults.isEmpty)
        _ = c.receiveLive([report], for: "/Users/me/Documents/")
        // ⌘C copies the path and keeps everything; ⏎ (the action key) opens it.
        let copy = c.handleKeyDown(KeyEvent(keyCode: 0x08, characters: "c", modifiers: .command))
        #expect(copy.effects.first == .copy(report.path) && copy.handled && c.draft == "@open /Users/me/Documents/")
        let open = c.handleKeyDown(enterKey)
        #expect(open.effects.last == .open(path: report.path) && commits(open).isEmpty && c.phase == .idle)
        #expect(!c.engineState.isAsciiMode)  // back to Chinese once @open is done
        // Esc on the way also brings Chinese back.
        let (d, _) = palette("o")
        _ = d.handleKeyDown(tab)
        _ = d.handleKeyDown(escKey)
        #expect(!d.engineState.isAsciiMode && d.draft.isEmpty)
    }

    @Test func commandCopiesTheHighlightedResult() {
        let (c, _) = translating()
        _ = c.receive(final, isFinal: true, id: 1)
        let copy = c.handleKeyDown(KeyEvent(keyCode: 0x08, characters: "c", modifiers: .command))
        #expect(copy == .consumed([.copy("Hi there."), .notice("已复制")]) && c.phase == .choosing)
        _ = c.handleKeyDown(downKey)
        #expect(c.handleKeyDown(KeyEvent(keyCode: 0x08, characters: "c", modifiers: .command)).effects.first == .copy("Hello."))
        // With nothing to copy, ⌘C is the app's.
        let (d, _) = composer()
        #expect(d.handleKeyDown(KeyEvent(keyCode: 0x08, characters: "c", modifiers: .command)) == .passThrough)
    }
}
