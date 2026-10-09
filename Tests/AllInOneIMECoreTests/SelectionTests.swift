import Foundation
import Testing
@testable import AllInOneIMECore

/// Whether an effect inserts or replaces text in the document.
func changesDocument(_ effect: Composer.Effect) -> Bool {
    switch effect {
    case .commit, .replaceSelection: return true
    default: return false
    }
}

/// Selected text sent with the selection key: the translate key, or ⌥Space when that is Space.
extension ComposerTests {
    static let selected = "我今天有点不舒服"

    /// An Option tap (left by default) with `selection` as what is selected; returns what the release does.
    func tapOption(_ c: Composer, right: Bool = false, at time: Double = 1,
                   selection: @escaping () -> Composer.Selection) -> [Composer.Effect] {
        let key = right ? VirtualKey.rightOption : VirtualKey.leftOption
        let side: KeyModifiers = right ? .rightOption : .leftOption
        _ = c.handleFlagsChanged(keyCode: key, modifiers: [.option, side], timestamp: time, selection: selection)
        return c.handleFlagsChanged(keyCode: key, modifiers: [], timestamp: time + 0.1, selection: selection)
    }

    /// `text` sent with the selection key for `key` (request id 1 in flight).
    func convertingSelection(_ text: String = ComposerTests.selected, key: TranslateKey = .space) -> (Composer, FakeEngine) {
        let (c, e) = composer(key: key)
        if key == .optionTap {
            _ = tapOption(c, selection: { .text(text) })
        } else {
            _ = c.handleKeyDown(optionSpace, selection: { .text(text) })
        }
        return (c, e)
    }

    /// `selected` with the final answer in.
    func choosingForSelection(key: TranslateKey = .space) -> Composer {
        let (c, _) = convertingSelection(key: key)
        _ = c.receive(final, isFinal: true, id: 1)
        return c
    }

    @Test func theSelectionKeyFollowsTheTranslateKey() {
        #expect(Composer(translateKey: .optionTap).selectionKey == .optionTap)
        #expect(Composer(translateKey: .optionSpace).selectionKey == .optionSpace)
        #expect(Composer(translateKey: .space).selectionKey == .optionSpace)  // Space would type over it
    }

    @Test func theSelectionKeySendsTheSelectedText() {
        let started: [Composer.Effect] = [.startConversion(input: Self.selected, id: 1), .updateMarkedText, .showPanel]
        for key in [TranslateKey.optionSpace, .space] {
            let (c, _) = composer(key: key)
            let r = c.handleKeyDown(optionSpace, selection: { .text(Self.selected) })
            #expect(r == .consumed(started), "\(key)")
            #expect(c.phase == .translating(id: 1) && c.replacesSelection, "\(key)")
            #expect(c.markedText.isEmpty && c.markedCursor == 0, "\(key)")  // it stays in the document, not marked
        }
        // The default: a tap of either ⌥ (modifier changes always reach the application too).
        for right in [false, true] {
            let (c, _) = composer(key: .optionTap)
            #expect(tapOption(c, right: right, selection: { .text(Self.selected) }) == started, "right: \(right)")
            #expect(c.replacesSelection && c.choices.first?.text == Self.selected)
            #expect(c.voiceHoldElapsed().isEmpty && c.voice == .off)  // the right ⌥ tap doesn't dictate later
        }
        let c = choosingForSelection(key: .optionTap)
        #expect(c.phase == .choosing && c.markedText.isEmpty && c.wantsPanel)
    }

    @Test func otherKeysAndStatesNeverReadTheSelection() {
        var reads = 0
        let read: () -> Composer.Selection = {
            reads += 1
            return .text("x")
        }
        // With the Option tap as translate key, ⌥Space is just ⌥Space.
        let (t, _) = composer(key: .optionTap)
        #expect(t.handleKeyDown(optionSpace, selection: read) == .passThrough)
        let (c, _) = composer(key: .space)
        for key in [spaceKey, k("c", mods: .command), k("∑", mods: .option),
                    KeyEvent(keyCode: VirtualKey.space, characters: " ", modifiers: [.option, .command]),
                    KeyEvent(keyCode: VirtualKey.space, characters: " ", modifiers: [.option, .control]),
                    KeyEvent(keyCode: VirtualKey.space, characters: " ", modifiers: [.option, .shift])] {
            _ = c.handleKeyDown(key, selection: read)
        }
        type("ni", c)
        _ = c.handleKeyDown(optionSpace, selection: read)  // composing pinyin
        _ = c.handleKeyDown(escKey)
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        _ = c.handleKeyDown(optionSpace, selection: read)  // a draft is pending
        _ = c.handleKeyDown(spaceKey)
        _ = c.handleKeyDown(optionSpace, selection: read)  // level two
        // ⌥Space as translate key: a pending draft is sent, not the selection.
        let (o, _) = composer(key: .optionSpace)
        type("nihao", o)
        #expect(startsConversion(o.handleKeyDown(optionSpace, selection: read).effects) && !o.replacesSelection)
        // An Option tap: only with nothing composed, and not when it was part of a chord.
        let (p, _) = composer(key: .optionTap)
        type("nihao", p)
        #expect(startsConversion(tapOption(p, selection: read)) && !p.replacesSelection)
        let (q, _) = composer(key: .optionTap)
        _ = q.handleFlagsChanged(keyCode: VirtualKey.leftOption, modifiers: [.option, .leftOption], timestamp: 1, selection: read)
        _ = q.handleKeyDown(KeyEvent(keyCode: VirtualKey.right, characters: "\u{F703}", modifiers: .option), selection: read)
        _ = q.handleFlagsChanged(keyCode: VirtualKey.leftOption, modifiers: [], timestamp: 1.1, selection: read)  // ⌥→
        _ = q.handleFlagsChanged(keyCode: VirtualKey.leftOption, modifiers: [.option, .leftOption], timestamp: 2, selection: read)
        _ = q.handleFlagsChanged(keyCode: VirtualKey.leftOption, modifiers: [], timestamp: 2.9, selection: read)  // held too long
        #expect(reads == 0)
        // Caps Lock doesn't matter, and no pinyin engine is needed (dictionaries still being prepared).
        let notReady = Composer(engine: nil, translateKey: .optionSpace)
        let capsOption = KeyEvent(keyCode: VirtualKey.space, characters: "\u{A0}", modifiers: [.option, .capsLock])
        #expect(notReady.handleKeyDown(capsOption, selection: read).effects.first == .startConversion(input: "x", id: 1))
        #expect(reads == 1 && notReady.replacesSelection)
    }

    @Test func onlyAKeyWithNothingGoingOnReadsTheSelection() {
        var reads = 0
        let read: () -> Composer.Selection = {
            reads += 1
            return .text("x")
        }
        // A tap with AI off while pinyin is being typed, and while a dictation is finishing.
        let (c, _) = composer(ai: false, key: .optionTap)
        type("ni", c)
        _ = tapOption(c, selection: read)
        let (d, _) = composer(key: .optionTap)
        _ = startDictation(d)
        _ = optionUp(d)  // released: waiting for the transcript
        _ = tapOption(d, at: 3, selection: read)
        #expect(d.translatesAfterVoice)  // the tap sends the transcript instead
        // ⌥Space while right ⌥ is still held (Space translate key): it ends the dictation, nothing more.
        let (f, _) = composer(key: .space)
        _ = startDictation(f)
        let r = f.handleKeyDown(optionSpace, selection: read)
        #expect(r.effects.first == .cancelVoice(id: 1) && !startsConversion(r.effects) && !f.replacesSelection)
        #expect(reads == 0)
        // Selected text is sent while the dictionaries are prepared; the translate key then accepts too.
        let notReady = Composer(engine: nil, translateKey: .optionTap)
        _ = tapOption(notReady, selection: { .text(Self.selected) })
        _ = notReady.receive(final, isFinal: true, id: 1)
        #expect(tapOption(notReady, at: 5, selection: read) == [.hidePanel, .replaceSelection("Hi there.")] && reads == 0)
        let failed = Composer(engine: nil, translateKey: .optionTap)
        _ = tapOption(failed, selection: { .text(Self.selected) })
        _ = failed.fail("请求超时", id: 1)
        #expect(tapOption(failed, at: 5, selection: read).first == .startConversion(input: Self.selected, id: 2))
    }

    @Test func nothingSelectedLeavesTheKeyAlone() {
        let (c, _) = composer(key: .optionSpace)
        #expect(c.handleKeyDown(optionSpace, selection: { .none }) == .passThrough)
        #expect(c.handleKeyDown(optionSpace) == .passThrough)  // callers that don't read selections
        let (t, _) = composer(key: .optionTap)
        #expect(tapOption(t, selection: { .none }).isEmpty)
        #expect(tapOption(t, right: true, at: 3, selection: { .none }) == [.notice(t.messages.holdToTalk)])
        #expect(c.phase == .idle && t.phase == .idle && !c.replacesSelection && !t.replacesSelection)
    }

    @Test func selectedTextThatCantBeSentIsKeptAndExplained() {
        // ⌥Space is consumed either way: reaching the application, it would type over the selection.
        func notice(_ selection: Composer.Selection, ai: Bool = true) -> String? {
            let (c, _) = composer(ai: ai, key: .optionSpace)
            let r = c.handleKeyDown(optionSpace, selection: { selection })
            #expect(r.handled && c.phase == .idle && c.draft.isEmpty && !c.replacesSelection)
            let (t, _) = composer(ai: ai, key: .optionTap)
            #expect(tapOption(t, selection: { selection }) == r.effects && t.phase == .idle)
            guard r.effects.count == 1, case let .notice(text) = r.effects[0] else { return nil }
            return text
        }
        let m = Composer.Messages.chinese
        #expect(notice(.text(Self.selected), ai: false) == m.selectionNeedsAI)
        #expect(notice(.unreadable) == m.selectionUnreadable)
        #expect(notice(.tooLong) == m.selectionTooLong)
        #expect(notice(.text(String(repeating: "字", count: Composer.maxSelectionLength + 1))) == m.selectionTooLong)
        #expect(notice(.text("第一行\n第二行")) == m.selectionMultiline)
        // Only spaces or a line break (an empty line, triple-clicked).
        #expect(notice(.text("")) == m.selectionBlank)
        #expect(notice(.text("  ")) == m.selectionBlank)
        // An inline image, file or tag: it can't be sent, and replacing would delete it.
        #expect(notice(.text("看这个\u{FFFC}图很好")) == m.selectionAttachment)
        #expect(notice(.text("看\u{FFFC}\u{301}图")) == m.selectionAttachment)  // a combining mark after it
        #expect(m.selectionTooLong.contains(String(Composer.maxSelectionLength)))
        // In the interface language.
        let (e, _) = composer(key: .optionSpace)
        e.messages = .english
        #expect(e.handleKeyDown(optionSpace, selection: { .unreadable }).effects == [.notice(Composer.Messages.english.selectionUnreadable)])
        // AI off and nothing selected: ⌥Space is just ⌥Space.
        let (c, _) = composer(ai: false, key: .optionSpace)
        #expect(c.handleKeyDown(optionSpace, selection: { .none }) == .passThrough)
        // Exactly the limit is fine.
        let (d, _) = composer(key: .optionSpace)
        let long = String(repeating: "字", count: Composer.maxSelectionLength)
        #expect(d.handleKeyDown(optionSpace, selection: { .text(long) }).effects.first == .startConversion(input: long, id: 1))
    }

    @Test func chosenLineReplacesTheSelection() {
        for key in TranslateKey.allCases {
            let c = choosingForSelection(key: key)
            #expect(c.handleKeyDown(spaceKey) == .consumed([.hidePanel, .replaceSelection("Hi there.")]), "\(key)")
            #expect(c.phase == .idle && !c.replacesSelection && c.draft.isEmpty)
            let d = choosingForSelection(key: key)
            #expect(d.handleKeyDown(enterKey).effects == [.hidePanel, .replaceSelection("Hi there.")], "⏎, \(key)")
            let f = choosingForSelection(key: key)
            #expect(f.handleKeyDown(k("5")).effects == [.hidePanel, .replaceSelection("嗨！")], "\(key)")
        }
        let f = choosingForSelection()
        _ = f.handleKeyDown(downKey)
        #expect(f.choose(index: f.highlighted) == [.hidePanel, .replaceSelection("Hello.")])  // a click
        // The selection key again accepts too, like Space.
        let t = choosingForSelection(key: .optionTap)
        #expect(tapOption(t, at: 5, selection: { .text("ignored") }) == [.hidePanel, .replaceSelection("Hi there.")])
        let o = choosingForSelection(key: .optionSpace)
        #expect(o.handleKeyDown(optionSpace, selection: { .text("ignored") }).effects == [.hidePanel, .replaceSelection("Hi there.")])
        // Before the answer: the first line once it has fully arrived.
        let (g, _) = convertingSelection()
        _ = g.receive(ConversionResult(versions: [CandidateLine("Hi th", isComplete: false)]), isFinal: false, id: 1)
        #expect(g.handleKeyDown(optionSpace, selection: { .text("ignored") }).effects.isEmpty)
        #expect(g.handleKeyDown(enterKey).effects.isEmpty && g.replacesSelection)
        _ = g.receive(ConversionResult(versions: [CandidateLine("Hi there.")]), isFinal: false, id: 1)
        #expect(g.handleKeyDown(optionSpace).effects == [.cancelConversion, .hidePanel, .replaceSelection("Hi there.")])
    }

    @Test func everyOtherWayOutLeavesTheSelectedTextAsItWas() {
        // Each of these ends level two with nothing inserted, replaced or marked.
        let ways: [(String, (Composer) -> [Composer.Effect])] = [
            ("Esc", { $0.handleKeyDown(escKey).effects }),
            ("0", { $0.handleKeyDown(k("0")).effects }),
            ("⌫", { $0.handleKeyDown(backspaceKey).effects }),
            ("focus loss", { $0.commitAll() }),
            ("secure input", { $0.commitAsTyped() }),
            ("AI off", { $0.setAI(false) }),
        ]
        for (name, leave) in ways {
            for answered in [false, true] {
                let (c, _) = convertingSelection()
                if answered { _ = c.receive(final, isFinal: true, id: 1) }
                let effects = leave(c)
                let expected: [Composer.Effect] = (answered ? [] : [.cancelConversion]) + [.hidePanel]
                #expect(Array(effects.prefix(expected.count)) == expected, "\(name)")
                #expect(!effects.contains(where: changesDocument), "\(name)")
                #expect(c.phase == .idle && !c.replacesSelection && c.draft.isEmpty && c.markedText.isEmpty, "\(name)")
            }
        }
        // After an error: Space and the selection key ask again, ⏎ and Esc leave it.
        let (f, _) = convertingSelection()
        _ = f.fail("请求超时", id: 1)
        #expect(f.handleKeyDown(spaceKey).effects.first == .startConversion(input: Self.selected, id: 2))
        _ = f.fail("请求超时", id: 2)
        #expect(f.handleKeyDown(optionSpace).effects.first == .startConversion(input: Self.selected, id: 3))
        #expect(f.replacesSelection)
        _ = f.fail("请求超时", id: 3)
        #expect(f.handleKeyDown(enterKey) == .consumed([.hidePanel]))
        let (g, _) = convertingSelection()
        _ = g.fail("请求超时", id: 1)
        #expect(g.handleKeyDown(escKey) == .consumed([.hidePanel]))
    }

    @Test func shortcutsActOnTheSelectedTextItself() {
        // ⌘X, ⌘V, ⌘Z … change the text: the panel closes and nothing is replaced afterwards.
        let (c, _) = convertingSelection()
        #expect(c.handleKeyDown(k("x", mods: .command)) == Composer.Response(effects: [.cancelConversion, .hidePanel], handled: false))
        #expect(c.phase == .idle && !c.replacesSelection)
        #expect(c.handleKeyDown(spaceKey) == .passThrough)
        let d = choosingForSelection()
        #expect(d.handleKeyDown(k("c", mods: .command)) == Composer.Response(effects: [.hidePanel], handled: false))
        #expect(!d.replacesSelection)
    }

    @Test func typingWithThePanelUpActsAsWithNothingPending() {
        // Pinyin starts as usual; its marked text replaces the selection, as in any text field.
        let c = choosingForSelection()
        let r = c.handleKeyDown(k("n"))
        #expect(r.handled && r.effects == [.hidePanel, .updateMarkedText, .showPanel])
        #expect(!c.replacesSelection && c.phase == .drafting && c.markedText == "n" && c.draft.isEmpty)
        // A key that would reach the application with nothing pending still does.
        let d = choosingForSelection()
        #expect(d.handleKeyDown(k("∑", mods: .option)) == Composer.Response(effects: [.hidePanel], handled: false))
        // Dictation: the transcript starts a new draft (nothing of the selection is kept in it).
        let f = choosingForSelection()
        _ = optionDown(f)
        let voice = f.voiceHoldElapsed()
        #expect(voice.prefix(1) == [.hidePanel] && voice.last == .startVoice(id: 1, language: .chinese))
        #expect(!f.replacesSelection && f.voice == .listening(id: 1, text: "") && f.draft.isEmpty)
    }

    @Test func typedSentencesStillWorkAsBeforeAfterASelection() {
        let (c, _) = convertingSelection()
        _ = c.handleKeyDown(escKey)
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        _ = c.handleKeyDown(spaceKey)
        #expect(!c.replacesSelection && c.markedText == "你好")
        _ = c.receive(final, isFinal: true, id: 2)
        #expect(c.handleKeyDown(escKey).effects == [.updateMarkedText, .showPanel])  // back to the draft
        #expect(c.phase == .drafting && c.draft == "你好")
        #expect(commits(c.handleKeyDown(enterKey)) == ["你好"])
    }

    @Test func trimSelectionReportsTheUTF16RangeOfTheText() {
        func trim(_ s: String) -> [String]? {
            Composer.trimSelection(s).map { [$0.text, String($0.offset), String($0.length)] }
        }
        #expect(trim(Self.selected + "\n") == [Self.selected, "0", "8"])  // triple-click takes the line break
        #expect(trim("  hello world \n") == ["hello world", "2", "11"])
        #expect(trim(" 👋 hi ") == ["👋 hi", "1", "5"])  // the emoji is two UTF-16 units
        #expect(trim("a\nb") == ["a\nb", "0", "3"])
        #expect(trim(" \n\t ") == ["", "0", "0"])
        #expect(trim("") == ["", "0", "0"])
        // A selection that splits a character (half an emoji) is not text: never trimmed (or crashed on).
        // Built through NSString: String's own initializers would repair the lone surrogate.
        let halfEmojiAtEnd = NSString(characters: [0x5B57, 0xD83D], length: 2) as String     // 字 + lead surrogate
        let halfEmojiAtStart = NSString(characters: [0x20, 0xDE00, 0x61], length: 3) as String  // space, trail, a
        #expect(trim(halfEmojiAtEnd) == nil)
        #expect(trim(halfEmojiAtStart) == nil)
    }
}
