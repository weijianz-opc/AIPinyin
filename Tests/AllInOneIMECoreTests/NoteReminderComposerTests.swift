import Foundation
import Testing
@testable import AllInOneIMECore

/// @note and @reminder: they stay on this Mac (nothing for a model) and insert nothing.
extension ComposerTests {
    var commandC: KeyEvent { KeyEvent(keyCode: 0x08, characters: "c", modifiers: .command) }

    /// A composer (⏎ as the action key, or `key`) with "@" and `letters` typed, then Tab.
    func command(_ letters: String, key: ActionKey = .enter) -> Composer {
        let (c, _) = composer(key: key)
        _ = c.handleKeyDown(at)
        type(letters, c)
        _ = c.handleKeyDown(tab)
        return c
    }

    var tomorrow3pm: ReminderDraft {
        ReminderDraft(title: "给张三打电话", due: DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 0), hasTime: true)
    }

    /// "@reminder 你好" read (id 1) as `reminder`, shown to confirm; the action key `key` sent it.
    func confirming(_ reminder: ReminderDraft, key: ActionKey = .enter) -> Composer {
        let c = command("rem", key: key)
        type("nihao", c)
        switch key {
        case .enter: _ = c.handleKeyDown(enterKey)
        case .space: _ = [c.handleKeyDown(spaceKey), c.handleKeyDown(spaceKey)]  // picks 你好, then sends
        case .optionSpace: _ = c.handleKeyDown(optionSpace)
        case .optionTap: _ = tapOption(c)
        }
        _ = c.receiveReminder(reminder, id: 1)
        return c
    }

    @Test func theyAreOfferedOnceTheirLettersAreTyped() {
        // Five rows are shown at a time and they come after @read: the list scrolls to them, or their
        // letters bring them up.
        let all = palette().0
        #expect(Array(all.paletteVisible) == [.improve, .question, .claude, .open, .read])
        #expect(all.paletteMatches.contains(.note) && all.paletteMatches.contains(.reminder))
        #expect(palette("n").0.paletteMatches == [.note, .question, .open, .reminder, .settings])  // then names containing "n"
        #expect(palette("no").0.paletteMatches == [.note])
        #expect(palette("rem").0.paletteMatches == [.reminder])
        #expect(palette("r").0.paletteMatches == [.read, .reminder, .improve])  // starting with "r" first
        #expect(command("n").draft == "@note " && command("rem").draft == "@reminder ")
        #expect(!command("n").engineState.isAsciiMode && !command("rem").engineState.isAsciiMode)  // Chinese, as typed
    }

    @Test func noteSavesTheTextAndInsertsNothing() {
        let c = command("n")
        #expect(c.markedText == "note › ")
        type("nihao", c)
        let r = c.handleKeyDown(enterKey)  // converts the pinyin and saves it
        #expect(r.handled && commits(r).isEmpty)
        #expect(r.effects == [.hidePanel, .updateMarkedText, .saveNote(text: "你好"), .commandUsed("note")])
        #expect(c.phase == .idle && c.draft.isEmpty && c.markedText.isEmpty && !c.isLevelTwo && c.activeCommand == nil)
        // Secure input elsewhere doesn't hold it back: nothing goes to a model.
        let s = command("n")
        s.secureInputActive = { true }
        type("nihao", s)
        #expect(s.handleKeyDown(enterKey).effects.contains(.saveNote(text: "你好")))
        // Typed as a sentence with commands in it: saved as typed, nothing runs first.
        let p = command("n")
        _ = p.handleKeyDown(enterKey)
        _ = p.pasted("看 @read https://example.com", id: 1)
        #expect(p.handleKeyDown(enterKey).effects.contains(.saveNote(text: "看 @read https://example.com")))
    }

    @Test func noteWithNothingAfterItTakesTheClipboard() {
        // As for every command (0.3.0): the clipboard's text is shown in the draft, the action key again saves it.
        let c = command("n")
        #expect(c.handleKeyDown(enterKey).effects == [.readClipboard(id: 1)] && !c.isLevelTwo && c.draft == "@note ")
        #expect(c.pasted("买牛奶", id: 1) == [.updateMarkedText, .showPanel] && c.draft == "@note 买牛奶")
        #expect(c.handleKeyDown(enterKey).effects.contains(.saveNote(text: "买牛奶")))
        // Without any: a hint, nothing saved.
        let d = command("n")
        _ = d.handleKeyDown(enterKey)
        #expect(d.pasted(nil, id: 1) == [.notice("在命令后面写上内容")] && d.draft == "@note ")
    }

    @Test func aNoteKeepsItsLines() {
        // Pasted on three lines: saved on three lines, shown on one with 「 ↵ 」 between them.
        let c = command("n")
        _ = c.handleKeyDown(enterKey)
        #expect(c.pasted("牛奶\n鸡蛋\r\n面包\n", id: 1) == [.updateMarkedText, .showPanel])
        #expect(c.draft == "@note 牛奶\n鸡蛋\r\n面包" && c.markedText == "note › 牛奶 ↵ 鸡蛋 ↵ 面包" && c.markedCursor == c.markedText.count)
        #expect(c.handleKeyDown(enterKey).effects.contains(.saveNote(text: "牛奶\n鸡蛋\r\n面包")))
        // Its spaces and tabs stay; other control characters go.
        let t = command("n")
        _ = t.handleKeyDown(enterKey)
        _ = t.pasted("  a\tb  c\u{1B}[0m\u{0}\n\n d  ", id: 1)
        #expect(t.draft == "@note a\tb  c[0m\n\n d")
        // Typing after the pasted lines continues the last one.
        type("nihao", t)
        _ = t.handleKeyDown(spaceKey)
        #expect(t.markedText == "note › a\tb  c[0m ↵  ↵  d你好")
        // Up to 20000 characters (other commands: 2000, on one line).
        let long = command("n")
        _ = long.handleKeyDown(enterKey)
        #expect(long.pasted(String(repeating: "字", count: Composer.maxNoteLength + 1), id: 1) == [.notice(long.messages.noteTooLong)])
        _ = long.handleKeyDown(enterKey)
        #expect(long.pasted(String(repeating: "字", count: Composer.maxNoteLength), id: 2) == [.updateMarkedText, .showPanel])
        #expect(long.sentText.count == Composer.maxNoteLength && Composer.maxNoteLength == 20_000)
        #expect(Composer.Messages.chinese.noteTooLong == "剪贴板里的文字太长：最多 20000 字")
        let question = command("q")
        _ = question.handleKeyDown(enterKey)
        _ = question.pasted("牛奶\n鸡蛋", id: 1)
        #expect(question.draft == "@question 牛奶鸡蛋")
    }

    @Test func aNoteThatCouldNotBeSavedComesBack() {
        // ⏎ clears the draft before the note is saved; if that fails, the controller hands the text back.
        let c = command("n")
        type("nihao", c)
        _ = c.handleKeyDown(enterKey)
        #expect(c.phase == .idle)
        #expect(c.restoreDraft(.note, text: "牛奶\n鸡蛋") == [.updateMarkedText, .showPanel])
        #expect(c.draft == "@note 牛奶\n鸡蛋" && c.markedText == "note › 牛奶 ↵ 鸡蛋" && c.phase == .drafting && !c.isLevelTwo)
        #expect(c.handleKeyDown(enterKey).effects.contains(.saveNote(text: "牛奶\n鸡蛋")))  // try again
        // Something else is being typed meanwhile: nothing is put back (the text goes to the clipboard).
        let busy = command("n")
        type("wo", busy)
        #expect(busy.restoreDraft(.note, text: "买牛奶") == nil && busy.draft == "@note " && busy.markedText == "note › wo")
        let typing = composer().0
        type("ni", typing)
        #expect(typing.restoreDraft(.note, text: "买牛奶") == nil && typing.markedText == "ni")
        let choosing = confirming(tomorrow3pm)
        #expect(choosing.restoreDraft(.reminder, text: "明天下午3点给张三打电话") == nil && choosing.phase == .choosing)
    }

    @Test func reminderIsShownToConfirmThenAdded() {
        let c = command("rem")
        type("nihao", c)
        let preview = c.handleKeyDown(enterKey)
        #expect(preview.effects == [.previewReminder(input: "你好", id: 1), .updateMarkedText, .showPanel,
                                    .commandUsed("reminder")])
        #expect(c.phase == .translating(id: 1) && c.activeCommand == .reminder && c.choices.isEmpty)
        // The controller reads it and hands it back: one row, the title, to confirm.
        let reminder = tomorrow3pm
        #expect(c.receiveReminder(reminder, id: 2).isEmpty)  // not this request
        #expect(c.receiveReminder(reminder, id: 1) == [.showPanel])
        #expect(c.phase == .choosing && c.choices == [Composer.Choice(label: "1", kind: .reminder(reminder), text: "给张三打电话",
                                                                     isComplete: true)])
        #expect(c.highlighted == 0 && c.markedText == "reminder › 你好" && c.pendingReminder == reminder)
        // ⌘C copies the title and keeps it up.
        #expect(c.handleKeyDown(commandC) == .consumed([.copy("给张三打电话"), .notice("已复制")]) && c.phase == .choosing)
        // Esc: back to the draft to fix the wording; ⏎ reads it again.
        #expect(c.handleKeyDown(escKey).effects == [.updateMarkedText, .showPanel])
        #expect(c.phase == .drafting && c.draft == "@reminder 你好" && c.choices.isEmpty && c.pendingReminder == nil)
        #expect(c.handleKeyDown(enterKey).effects.first == .previewReminder(input: "你好", id: 2))
        _ = c.receiveReminder(reminder, id: 2)
        // ⏎ adds it, with the text it was read from (it comes back if it can't be added): nothing inserted.
        let add = c.handleKeyDown(enterKey)
        #expect(add.effects == [.hidePanel, .updateMarkedText, .addReminder(reminder, input: "你好")] && commits(add).isEmpty)
        #expect(c.phase == .idle && c.draft.isEmpty && c.markedText.isEmpty && c.pendingReminder == nil)
        // Space and 1 add it too.
        for key in [spaceKey, k("1")] {
            let d = confirming(reminder)
            #expect(d.handleKeyDown(key).effects.last == .addReminder(reminder, input: "你好") && d.phase == .idle)
        }
        // Not added: it comes back as it was, to fix or send again.
        #expect(c.restoreDraft(.reminder, text: "你好") == [.updateMarkedText, .showPanel] && c.draft == "@reminder 你好")
        #expect(c.handleKeyDown(enterKey).effects.first == .previewReminder(input: "你好", id: 3))
    }

    @Test func otherDigitsOnTheConfirmRowGoOnWithTheText() {
        // There is only row 1: another digit is part of the time ("…下午" + 3), back in the draft.
        for digit in ["3", "0", "9"] {
            let c = confirming(tomorrow3pm)
            let r = c.handleKeyDown(k(digit))
            #expect(r.handled && commits(r).isEmpty && !r.effects.contains { if case .addReminder = $0 { return true } else { return false } })
            #expect(c.phase == .drafting && c.draft == "@reminder 你好" + digit && c.pendingReminder == nil, "\(digit)")
        }
    }

    @Test func reminderStaysOnThisMac() {
        // Secure input elsewhere doesn't hold it back, and commands in its text don't run first (no plan).
        let c = command("rem")
        c.secureInputActive = { true }
        #expect(c.handleKeyDown(enterKey).effects == [.readClipboard(id: 1)])  // nothing after it: the clipboard
        _ = c.pasted("明天看 @read https://example.com", id: 1)
        #expect(c.handleKeyDown(enterKey).effects.first == .previewReminder(input: "明天看 @read https://example.com", id: 1))
    }

    @Test func reminderWithOnlyATimeAsksWhatFor() {
        let onlyTime = ReminderDraft(title: "", due: DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 0), hasTime: true)
        let c = confirming(onlyTime)
        #expect(c.phase == .failed("写上要提醒的事，比如「明天下午3点给张三打电话」") && c.choices.isEmpty)
        #expect(Composer.Messages.english.reminderWithoutTitle.hasPrefix("Write what to be reminded of"))
        // ⏎, Space and Esc go back to the text (reading it again would only fail again); nothing is typed into
        // the app, whatever the action key.
        for key in [ActionKey.enter, .space, .optionSpace, .optionTap] {
            for press in [enterKey, spaceKey, escKey] {
                let d = confirming(onlyTime, key: key)
                guard case .failed = d.phase else {
                    Issue.record("\(key): not failed (\(d.phase))")
                    continue
                }
                let r = d.handleKeyDown(press)
                #expect(r.handled && commits(r).isEmpty && d.phase == .drafting && d.draft == "@reminder 你好", "\(key) \(press.keyCode)")
            }
        }
        // ⌥Space as the action key, and a tap of ⌥: back too.
        let o = confirming(onlyTime, key: .optionSpace)
        #expect(commits(o.handleKeyDown(optionSpace)).isEmpty && o.phase == .drafting)
        let t = confirming(onlyTime, key: .optionTap)
        #expect(commits(tapOption(t, at: 5)).isEmpty && t.phase == .drafting)
        // A digit goes on with the text there too.
        let digit = confirming(onlyTime)
        _ = digit.handleKeyDown(k("3"))
        #expect(digit.draft == "@reminder 你好3" && digit.phase == .drafting)
    }
}

/// What goes to Notes, and what comes back from it, without Notes.
struct NotesFormatTests {
    @Test func aNotesBodyIsEscapedHTMLALinePerLine() {
        #expect(NotesFormat.html("a<b> & \"c\"\n\nd") == "<div>a&lt;b&gt; &amp; &quot;c&quot;</div><div><br></div><div>d</div>")
        // \r\n is one line break, as are the Unicode separators.
        #expect(NotesFormat.html("牛奶\r\n鸡蛋\u{2028}面包") == "<div>牛奶</div><div>鸡蛋</div><div>面包</div>")
        // Spaces HTML would collapse are kept: several in a row, at either end of a line.
        #expect(NotesFormat.html("a  b c") == "<div>a&nbsp;&nbsp;b c</div>")
        #expect(NotesFormat.html(" a ") == "<div>&nbsp;a&nbsp;</div>" && NotesFormat.html(" ") == "<div>&nbsp;</div>")
        #expect(NotesFormat.html("") == "<div><br></div>")
    }

    @Test func aNotesTitleIsItsFirstLine() {
        #expect(NotesFormat.title(of: "\n  周会要点  \n第二行") == "周会要点")
        #expect(NotesFormat.title(of: String(repeating: "长", count: 100)) == String(repeating: "长", count: 80))
        #expect(NotesFormat.title(of: " \n ").isEmpty)
    }

    func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
        return list
    }

    @Test func theFoldersNotesNewestFirst() {
        // What the script returns: the ids, the names and the modification dates, three lists.
        let older = Date(timeIntervalSince1970: 1_790_000_000), newer = older.addingTimeInterval(3600)
        let result = list([
            list([NSAppleEventDescriptor(string: "x-coredata://1"), NSAppleEventDescriptor(string: "x-coredata://2"),
                  NSAppleEventDescriptor(string: "")]),
            list([NSAppleEventDescriptor(string: "周会要点"), NSAppleEventDescriptor(string: "买牛奶和鸡蛋")]),
            list([NSAppleEventDescriptor(date: older), NSAppleEventDescriptor(date: newer)]),
        ])
        #expect(NotesFormat.entries(from: result, limit: 10) == [
            NotesFormat.Entry(id: "x-coredata://2", title: "买牛奶和鸡蛋", modified: newer),
            NotesFormat.Entry(id: "x-coredata://1", title: "周会要点", modified: older),
        ])
        #expect(NotesFormat.entries(from: result, limit: 1).map(\.id) == ["x-coredata://2"])
        #expect(NotesFormat.entries(from: result, limit: 0).isEmpty)
        // A name or date missing: kept without it (a note without an id is left out, above).
        let partial = list([list([NSAppleEventDescriptor(string: "a"), NSAppleEventDescriptor(string: "b")]),
                            list([NSAppleEventDescriptor(string: "A")]), list([])])
        #expect(NotesFormat.entries(from: partial, limit: 10) == [
            NotesFormat.Entry(id: "a", title: "A", modified: .distantPast), NotesFormat.Entry(id: "b", title: "", modified: .distantPast),
        ])
        // No folder yet (`{}`), or anything else: none.
        #expect(NotesFormat.entries(from: list([]), limit: 10).isEmpty)
        #expect(NotesFormat.entries(from: NSAppleEventDescriptor(string: "x"), limit: 10).isEmpty)
        #expect(NotesFormat.entries(from: list([list([]), list([]), list([])]), limit: 10).isEmpty)
    }
}
