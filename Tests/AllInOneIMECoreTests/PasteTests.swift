import Testing
@testable import AllInOneIMECore

/// ⌘V with a draft pending: the clipboard's text joins the draft instead of the document.
extension ComposerTests {
    var pasteKey: KeyEvent { KeyEvent(keyCode: 0x09, characters: "v", charactersIgnoringModifiers: "v", modifiers: .command) }

    /// "@improve " picked from the palette.
    func improveDraft(key: ActionKey = .enter) -> (Composer, FakeEngine) {
        let (c, e) = composer(ai: false, key: key)
        _ = c.handleKeyDown(at)
        type("i", c)
        _ = c.handleKeyDown(tab)
        #expect(c.draft == "@improve ")
        return (c, e)
    }

    /// ⌘V, then the clipboard's `text` arrives; returns the delivery's effects.
    @discardableResult
    func paste(_ text: String?, into c: Composer) -> [Composer.Effect] {
        let r = c.handleKeyDown(pasteKey)
        guard case let .readClipboard(id)? = r.effects.last else {
            Issue.record("⌘V didn't ask for the clipboard: \(r)")
            return []
        }
        return c.pasted(text, id: id)
    }

    @Test func pastedTextJoinsACommandDraftAndTheActionKeyRunsOnIt() {
        let (c, _) = improveDraft()
        // The key is answered at once (the app doesn't paste); the text follows.
        #expect(c.handleKeyDown(pasteKey) == .consumed([.updateMarkedText, .showPanel, .readClipboard(id: 1)]))
        #expect(c.pasted("这个方案我觉得还不够好，需要再改一下", id: 1) == [.updateMarkedText, .showPanel])
        #expect(c.draft == "@improve 这个方案我觉得还不够好，需要再改一下" && c.markedText == c.draft)
        #expect(c.handleKeyDown(enterKey).effects.first == .startConversion(input: "这个方案我觉得还不够好，需要再改一下", id: 1))
        // Other commands take it too; @open searches for it as you type.
        let (q, _) = composer(ai: false, key: .enter)
        _ = q.handleKeyDown(at)
        type("q", q)
        _ = q.handleKeyDown(tab)
        paste("What is a monad?", into: q)
        #expect(q.handleKeyDown(enterKey).effects.first == .startCommand(.question, input: "What is a monad?", id: 1))
        let (o, _) = composer(ai: false, key: .enter)
        _ = o.handleKeyDown(at)
        type("o", o)
        _ = o.handleKeyDown(tab)
        paste("~/Documents/report.pdf", into: o)
        #expect(o.liveQuery == "~/Documents/report.pdf")
    }

    @Test func pastingContinuesWhatWasTypedLikeAnyPaste() {
        // Pinyin still pending is converted first; the text follows exactly (no space added).
        let (c, _) = improveDraft()
        type("nihao", c)
        #expect(c.handleKeyDown(pasteKey).effects.first == .updateMarkedText && !c.engineState.isComposing)
        #expect(c.draft == "@improve 你好")
        _ = c.pasted("，最近怎么样", id: 1)
        #expect(c.draft == "@improve 你好，最近怎么样")
        let (e, _) = english(ai: false, key: .enter)  // English before the draft: the mode can't change mid-way
        _ = e.handleKeyDown(at)
        type("i", e)
        _ = e.handleKeyDown(tab)
        type("Summary", e)
        _ = e.handleKeyDown(spaceKey)  // a space, as in any text
        paste("the meeting went well", into: e)
        _ = e.handleKeyDown(spaceKey)
        paste("  and\n", into: e)  // several pastes add up; each is trimmed at the ends
        #expect(e.draft == "@improve Summary the meeting went well and")
    }

    @Test func aCommandBeingTypedIsPickedFirst() {
        let (c, _) = composer(ai: false, key: .enter)
        _ = c.handleKeyDown(at)
        type("imp", c)
        paste("hello world", into: c)
        #expect(c.draft == "@improve hello world" && c.draftCommand == .improve && c.paletteQuery == nil)
        // "@" alone is an at sign (a mention): it goes in as typed and the app pastes after it.
        let (m, _) = composer(ai: false, key: .enter)
        _ = m.handleKeyDown(at)
        let r = m.handleKeyDown(pasteKey)
        #expect(!r.handled && commits(r) == ["@"] && !r.effects.contains(.readClipboard(id: 1)))
    }

    @Test func linesBecomeOneLine() {
        func pasted(_ text: String) -> String {
            let (c, _) = improveDraft()
            paste(text, into: c)
            return c.sentText
        }
        #expect(pasted("第一行\r\n第二行。\n\n  第三行\u{2028}four\n") == "第一行第二行。第三行 four")
        #expect(pasted("Plan:\n- step one\n- step two") == "Plan: - step one - step two")
        #expect(pasted("see https://example.com/\nthanks") == "see https://example.com/ thanks")  // the URL stays whole
        #expect(pasted("(a)\n(b)\n50%\nof users") == "(a) (b) 50% of users")
        #expect(pasted("One.\nTwo\u{1B}[31m\n") == "One. Two [31m")  // control characters become spaces
        #expect(pasted("日本語\nの文\n한국어\n문장") == "日本語の文한국어문장")
    }

    @Test func withoutADraftTheAppPastesAndWithoutTextANoticeSaysSo() {
        // Nothing pending, pinyin only, results showing: ⌘V is the app's (the clipboard isn't read).
        let (idle, _) = composer(ai: false, key: .enter)
        #expect(idle.handleKeyDown(pasteKey) == .passThrough)
        let (pinyin, _) = composer(ai: false, key: .enter)
        type("ni", pinyin)
        #expect(!pinyin.handleKeyDown(pasteKey).handled)
        let (results, _) = improveDraft()
        type("nihao", results)
        _ = results.handleKeyDown(enterKey)
        #expect(results.isLevelTwo && !results.handleKeyDown(pasteKey).handled)
        // ⌘⇧V (paste and match style) and other shortcuts are unchanged.
        let (s, _) = improveDraft()
        let (ref, _) = improveDraft()
        #expect(s.handleKeyDown(KeyEvent(keyCode: 0x09, characters: "v", charactersIgnoringModifiers: "V", modifiers: [.command, .shift]))
                == ref.handleKeyDown(k("a", mods: .command)))
        // No text (an image, a password, not allowed): the draft stays, with a notice.
        let (c, _) = improveDraft()
        #expect(paste(nil, into: c) == [.notice(c.messages.nothingToPaste)] && c.draft == "@improve ")
        #expect(paste(" \n\t ", into: c) == [.notice(c.messages.nothingToPaste)] && c.draft == "@improve ")
    }

    @Test func aPasteArrivingLateIsDroppedOnceTheDraftIsGone() {
        let (c, _) = improveDraft()
        type("nihao", c)
        let r = c.handleKeyDown(pasteKey)
        #expect(r.effects.last == .readClipboard(id: 1))
        _ = c.handleKeyDown(enterKey)  // sent before the clipboard arrived
        #expect(c.pasted("late", id: 1).isEmpty && c.sentText == "你好")
        let (d, _) = improveDraft()
        _ = d.handleKeyDown(pasteKey)
        _ = d.handleKeyDown(escKey)  // cleared
        #expect(d.pasted("late", id: 1).isEmpty && d.draft.isEmpty)
        let (f, _) = improveDraft()
        _ = f.handleKeyDown(pasteKey)
        _ = f.handleKeyDown(pasteKey)  // only the latest ⌘V counts
        #expect(f.pasted("first", id: 1).isEmpty && f.pasted("second", id: 2) == [.updateMarkedText, .showPanel])
        #expect(f.draft == "@improve second")
    }

    @Test func terminalsKeepCommandVForThemselves() {
        // Terminals paste on ⌘V themselves: the input method stays out (no second copy in the draft).
        let (c, _) = improveDraft()
        c.pastesIntoDraft = false
        let (ref, _) = improveDraft()
        #expect(c.handleKeyDown(pasteKey) == ref.handleKeyDown(k("a", mods: .command)))  // as before the paste feature
    }

    var controlV: KeyEvent { KeyEvent(keyCode: 0x09, characters: "\u{16}", charactersIgnoringModifiers: "v", modifiers: .control) }

    func readsClipboard(_ effects: [Composer.Effect]) -> Bool {
        effects.contains { if case .readClipboard = $0 { return true } else { return false } }
    }

    @Test func controlVPastesIntoTheCommandInEveryApp() {
        // Terminals included (no app pastes on ⌃V by itself), after text already typed.
        for terminal in [false, true] {
            let (c, _) = improveDraft()
            c.pastesIntoDraft = !terminal
            type("nihao", c)
            let r = c.handleKeyDown(controlV)
            #expect(r.handled && r.effects.last == .readClipboard(id: 1), "terminal: \(terminal)")
            #expect(c.draft == "@improve 你好" && !c.engineState.isComposing)  // the pinyin is converted first
            #expect(c.pasted("，这个方案还不够好", id: 1) == [.updateMarkedText, .showPanel])
            #expect(c.draft == "@improve 你好，这个方案还不够好")
            #expect(c.handleKeyDown(enterKey).effects.first == .startConversion(input: "你好，这个方案还不够好", id: 1))
        }
        // "@imp" picks its command first, as with ⌘V.
        let (p, _) = composer(ai: false, key: .enter)
        _ = p.handleKeyDown(at)
        type("imp", p)
        #expect(p.handleKeyDown(controlV).effects.last == .readClipboard(id: 1))
        _ = p.pasted("hello world", id: 1)
        #expect(p.draft == "@improve hello world")
        // Nothing pending, or "@" alone (a mention): ⌃V is the app's (a shell's literal next, a text
        // view's page down), and the clipboard isn't read.
        let (idle, _) = composer(ai: false, key: .enter)
        #expect(idle.handleKeyDown(controlV) == .passThrough)
        let (m, _) = composer(ai: false, key: .enter)
        _ = m.handleKeyDown(at)
        let mention = m.handleKeyDown(controlV)
        #expect(commits(mention) == ["@"] && !mention.handled && !readsClipboard(mention.effects))
        // Results showing: not read either; ⌃⇧V is not ⌃V.
        let (l, _) = improveDraft()
        type("nihao", l)
        _ = l.handleKeyDown(enterKey)
        #expect(l.isLevelTwo && !readsClipboard(l.handleKeyDown(controlV).effects))
        let (s, _) = improveDraft()
        let shifted = KeyEvent(keyCode: 0x09, characters: "\u{16}", charactersIgnoringModifiers: "V", modifiers: [.control, .shift])
        #expect(!readsClipboard(s.handleKeyDown(shifted).effects) && s.draft == "@improve ")
    }

    @Test func theActionKeyOnAnEmptyCommandTakesTheClipboard() {
        for terminal in [false, true] {
            let (c, _) = improveDraft()
            c.pastesIntoDraft = !terminal
            // The text is shown in the command first; the action key again runs it.
            #expect(c.handleKeyDown(enterKey) == .consumed([.readClipboard(id: 1)]) && !c.isLevelTwo)
            #expect(c.pasted("这个方案还不够好", id: 1) == [.updateMarkedText, .showPanel])
            #expect(c.draft == "@improve 这个方案还不够好" && !c.isLevelTwo)
            #expect(c.handleKeyDown(enterKey).effects.first == .startConversion(input: "这个方案还不够好", id: 1))
        }
        // An Option tap or ⌥Space as the action key too; nothing on the clipboard: the old hint.
        let (t, _) = palette("i")
        _ = t.handleKeyDown(tab)
        #expect(tapOption(t) == [.readClipboard(id: 1)])
        #expect(t.pasted(nil, id: 1) == [.notice(t.messages.typeAfterCommand)] && t.draft == "@improve ")
        // A command with text after it runs as before; plain text in sentence mode isn't affected.
        let (d, _) = improveDraft()
        type("nihao", d)
        #expect(d.handleKeyDown(enterKey).effects.first == .startConversion(input: "你好", id: 1))
        let (s, _) = composer(ai: true, key: .enter)
        type("nihao", s)
        _ = s.handleKeyDown(spaceKey)
        #expect(s.handleKeyDown(enterKey).effects.first == .startConversion(input: "你好", id: 1))
    }

    @Test func sentenceModeDraftsTakeThePasteToo() {
        let (c, _) = composer(ai: true, key: .enter)
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        paste("世界", into: c)
        #expect(c.draft == "你好世界" && c.handleKeyDown(enterKey).effects.first == .startConversion(input: "你好世界", id: 1))
    }

    @Test func tooMuchOnTheClipboardIsRefused() {
        let (c, _) = improveDraft()
        let tooLong = [.notice(c.messages.pasteTooLong)] as [Composer.Effect]
        #expect(paste(String(repeating: "字", count: Composer.maxPasteLength + 1), into: c) == tooLong)
        #expect(paste(String(repeating: "长", count: Composer.maxPasteLength * 9), into: c) == tooLong)  // refused unread
        #expect(c.draft == "@improve ")
        let ok = String(repeating: "字", count: Composer.maxPasteLength)
        paste(ok, into: c)
        #expect(c.sentText == ok)
        #expect(Composer.Messages.chinese.pasteTooLong.contains(String(Composer.maxPasteLength)))
    }

    @Test func longInputGetsRoomForTheWholeAnswer() {
        var config = Config.default
        let lines = 3 + RewriteStyle.resolve(config.rewriteStyles).count
        #expect(Prompt.request(for: "你好", config: config).inferenceConfig.maxTokens == config.maxTokens)
        let paragraph = String(repeating: "这个方案还需要再讨论一下。", count: 30)  // 390 characters
        let tokens = Prompt.request(for: paragraph, config: config).inferenceConfig.maxTokens ?? 0
        #expect(tokens >= paragraph.count * lines && tokens <= 8192)
        #expect(Prompt.request(for: String(repeating: "字", count: Composer.maxPasteLength), config: config)
                .inferenceConfig.maxTokens == 8192)
        // A limit the user set stays as it is.
        config.maxTokens = 300
        #expect(Prompt.request(for: paragraph, config: config).inferenceConfig.maxTokens == 300)
        config.maxTokens = 4000
        #expect(Prompt.request(for: paragraph, config: config).inferenceConfig.maxTokens == 4000)
    }
}
