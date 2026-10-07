import Testing
@testable import AIPinyinCore

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
    private var pendingCommit: String?

    func candidates() -> [String] { input.isEmpty ? [] : dictionary[input] ?? [input] }

    func processKey(_ keycode: Int32, mask: Int32) -> Bool {
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
        let all = candidates()
        guard all.indices.contains(index) else { return true }
        emit(all[index])
        input = ""
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

    func commitComposition() -> String? {
        guard !input.isEmpty else { return nil }
        _ = select(highlighted)
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

func commits(_ r: Composer.Response) -> [String] { commits(r.effects) }
func commits(_ effects: [Composer.Effect]) -> [String] {
    effects.compactMap { if case let .commit(s) = $0 { return s } else { return nil } }
}

struct ComposerTests {
    let final = ConversionResult(
        english: [CandidateLine("Hi there."), CandidateLine("Hello."), CandidateLine("Hey.")],
        rewrites: [
            Rewrite(style: "润色", line: CandidateLine("你好呀！")),
            Rewrite(style: "简洁", line: CandidateLine("嗨！")),
            Rewrite(style: "正式", line: CandidateLine("您好！")),
        ])

    func rewrites(_ pairs: [(String, String)], complete: Bool = true) -> [Rewrite] {
        pairs.map { Rewrite(style: $0.0, line: CandidateLine($0.1, isComplete: complete)) }
    }

    func composer(ai: Bool = true) -> (Composer, FakeEngine) {
        let engine = FakeEngine()
        return (Composer(engine: engine, aiEnabled: ai), engine)
    }

    func type(_ s: String, _ c: Composer) {
        for ch in s { _ = c.handleKeyDown(k(String(ch))) }
    }

    /// Draft "你好" with a request in flight (id 1).
    func translating() -> (Composer, FakeEngine) {
        let (c, e) = composer()
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
        let (c, _) = composer()
        type("nihao", c)
        let confirm = c.handleKeyDown(spaceKey)
        #expect(commits(confirm).isEmpty)
        #expect(c.draft == "你好")
        #expect(c.markedText == "你好")
        #expect(confirm.effects.contains(.showPanel))  // hint: Space translates
        let translate = c.handleKeyDown(spaceKey)
        #expect(translate.effects == [.startConversion(input: "你好", id: 1), .updateMarkedText, .showPanel])
        #expect(c.phase == .translating(id: 1))
        #expect(c.markedText == "你好")
    }

    @Test func sentenceBuiltFromSeveralPiecesAndPunctuation() {
        let (c, _) = composer()
        type("wo", c)
        _ = c.handleKeyDown(spaceKey)
        type("jintian", c)
        #expect(c.markedText == "我jintian")
        #expect(c.markedCursor == 8)
        _ = c.handleKeyDown(k("2"))  // pick 金天 by digit
        #expect(c.draft == "我金天")
        _ = c.handleKeyDown(backspaceKey)
        #expect(c.draft == "我金")
        _ = c.handleKeyDown(k(","))
        #expect(c.draft == "我金，")
        _ = c.handleKeyDown(k("3"))  // engine ignores digits when idle: stays in the sentence
        #expect(c.draft == "我金，3")
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

    @Test func pickedEnglishWordStartsTheSentence() {
        let (c, e) = composer()
        e.dictionary["ok"] = ["OK"]
        type("ok", c)
        #expect(commits(c.handleKeyDown(spaceKey)).isEmpty)
        #expect(c.draft == "OK")
        type("wo", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.draft == "OK我")
        #expect(c.handleKeyDown(spaceKey).effects.first == .startConversion(input: "OK我", id: 1))
    }

    @Test func pickedDateOrEmojiStartsTheSentenceToo() {
        let (c, e) = composer()
        e.dictionary["rq"] = ["2026-10-06"]
        e.dictionary["hi"] = ["👋"]
        type("rq", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.draft == "2026-10-06")
        let (d, f) = composer()
        f.dictionary["hi"] = ["👋"]
        type("hi", d)
        _ = d.choose(index: 0)  // mouse click
        #expect(d.draft == "👋")
        // AI off: picks go straight to the document.
        let (o, g) = composer(ai: false)
        g.dictionary["rq"] = ["2026-10-06"]
        type("rq", o)
        #expect(commits(o.handleKeyDown(spaceKey)) == ["2026-10-06"])
    }

    @Test func enterCommitsTheDraftAsIs() {
        let (c, _) = composer()
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        let r = c.handleKeyDown(enterKey)
        #expect(commits(r) == ["你好"])
        #expect(c.phase == .idle)
        #expect(c.draft.isEmpty)
    }

    @Test func escapeDiscardsTheDraft() {
        let (c, _) = composer()
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.handleKeyDown(escKey).effects == [.updateMarkedText, .hidePanel])
        #expect(c.phase == .idle)
        #expect(c.markedText.isEmpty)
    }

    @Test func levelTwoSpaceWaitsForFirstEnglishLine() {
        let (c, _) = translating()
        let partial = ConversionResult(english: [CandidateLine("Hi th", isComplete: false)])
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
        #expect(c.choices.map(\.kind) == [.original, .english, .english, .english,
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
        #expect(commits(e.handleKeyDown(enterKey)) == ["你好"])
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
        _ = c.receive(ConversionResult(english: [CandidateLine("Hi.")], rewrites: rewrites([("润色", " 你好 ")])),
                      isFinal: true, id: 1)
        #expect(c.choices.map(\.label) == ["0", "1"])

        let (d, _) = translating()
        _ = d.receive(ConversionResult(english: [CandidateLine("Hi.")],
                                       rewrites: rewrites([("润色", "你好。"), ("正式", "您好。")])),
                      isFinal: true, id: 1)
        // "你好。" is the original plus a full stop: hidden, and the formal rewrite takes label 4.
        #expect(d.choices.map(\.label) == ["0", "1", "4"])
        #expect(d.choices.last?.kind == .rewrite("正式"))
        #expect(commits(d.handleKeyDown(k("4"))) == ["您好。"])

        let (e, _) = translating()
        _ = e.receive(ConversionResult(english: [CandidateLine("Hi.")],
                                       rewrites: rewrites([("润色", "您好！"), ("正式", "您好。")])),
                      isFinal: true, id: 1)
        #expect(e.choices.map(\.label) == ["0", "1", "4"])  // 正式 repeats the 润色 wording
        #expect(e.choices.last?.kind == .rewrite("润色"))
    }

    @Test func rewritesFollowTheModelsOrder() {
        let (c, _) = translating()
        _ = c.receive(ConversionResult(english: [CandidateLine("Hi.")],
                                       rewrites: rewrites([("委婉", "你好呀，打扰啦"), ("口语", "嗨～")])),
                      isFinal: true, id: 1)
        #expect(c.choices.map(\.kind) == [.original, .english, .rewrite("委婉"), .rewrite("口语")])
        #expect(c.choices.map(\.label) == ["0", "1", "4", "5"])
    }

    @Test func rewritesAppearOnceComplete() {
        let (c, _) = translating()
        _ = c.receive(ConversionResult(english: [CandidateLine("Hi.")], rewrites: rewrites([("润色", "你好")], complete: false)),
                      isFinal: false, id: 1)
        #expect(c.choices.map(\.label) == ["0", "1"])  // could still turn out to be a copy
        _ = c.receive(ConversionResult(english: [CandidateLine("Hi.")],
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
            #expect(c.draft == "你好")
        }
    }

    @Test func typingInLevelTwoContinuesTheSentence() {
        let (c, _) = translating()
        let r = c.handleKeyDown(k("w"))
        #expect(r.effects.first == .cancelConversion)
        #expect(c.phase == .drafting)
        #expect(c.markedText == "你好w")
        type("o", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.draft == "你好我")
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

    @Test func aiOffCommitsStraightFromTheEngine() {
        let (c, _) = composer(ai: false)
        type("nihao", c)
        let r = c.handleKeyDown(spaceKey)
        #expect(commits(r) == ["你好"])
        #expect(c.phase == .idle)
        #expect(c.handleKeyDown(spaceKey) == .passThrough)
    }

    @Test func shiftSpaceTogglesAIAndFlushesTheDraft() {
        let (c, _) = translating()
        let r = c.handleKeyDown(shiftSpace)
        #expect(r.effects == [.cancelConversion, .hidePanel, .commit("你好"), .aiModeChanged(false), .notice("AI 翻译：关")])
        #expect(!c.aiEnabled)
        #expect(c.phase == .idle)
        #expect(c.handleKeyDown(shiftSpace).effects == [.aiModeChanged(true), .notice("AI 翻译：开")])
    }

    @Test func menuToggleFlushesTheDraftToo() {
        let (c, _) = composer()
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.setAI(true).isEmpty)  // already on
        #expect(c.setAI(false) == [.hidePanel, .commit("你好"), .aiModeChanged(false), .notice("AI 翻译：关")])
        #expect(c.draft.isEmpty && c.phase == .idle)
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
        let (c, e) = composer()
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        e.ascii = true
        type("ok", c)
        #expect(c.draft == "你好ok")
    }

    @Test func latinModeSpaceSeparatesWordsAndDoubleSpaceTranslates() {
        let (c, e) = composer()
        type("wo", c)
        _ = c.handleKeyDown(spaceKey)
        e.ascii = true
        c.refreshEngineState()
        type("check", c)
        #expect(c.handleKeyDown(spaceKey).effects == [.updateMarkedText, .showPanel])
        type("it", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.draft == "我check it ")
        let r = c.handleKeyDown(spaceKey)
        #expect(r.effects.first == .startConversion(input: "我check it", id: 1))
    }

    @Test func commitAllAndCommitAsTyped() {
        let (c, _) = composer()
        type("wo", c)
        _ = c.handleKeyDown(spaceKey)
        type("nihao", c)
        #expect(commits(c.commitAll()) == ["我你好"])
        #expect(c.phase == .idle)
        #expect(!c.engineState.isComposing)

        let (d, _) = composer()
        type("wo", d)
        _ = d.handleKeyDown(spaceKey)
        type("ni", d)
        #expect(commits(d.commitAsTyped()) == ["我ni"])
        #expect(d.markedText.isEmpty)

        let (t, _) = translating()
        #expect(t.commitAll() == [.cancelConversion, .hidePanel, .commit("你好")])
        let (idle, _) = composer()
        #expect(idle.commitAll() == [.hidePanel, .updateMarkedText])
    }

    @Test func mouseSelectsCandidatesAtBothLevels() {
        let (c, _) = composer()
        type("nihao", c)
        _ = c.choose(index: 1)
        #expect(c.draft == "拟好")
        _ = c.handleKeyDown(spaceKey)
        _ = c.receive(final, isFinal: true, id: 1)
        #expect(commits(c.choose(index: 3)) == ["Hey."])
    }

    @Test func notReadyEngineLetsKeysThroughWithOneNotice() {
        let c = Composer(engine: nil, aiEnabled: true)
        #expect(c.handleKeyDown(k("n")) == Composer.Response(effects: [.notice("词库准备中，稍候可用")], handled: false))
        #expect(c.handleKeyDown(k("i")) == .passThrough)
    }

    @Test func capsLockTypesDirectlyWhenIdle() {
        let (c, _) = composer()
        #expect(c.handleKeyDown(k("W", mods: .capsLock)) == .passThrough)
    }
}
