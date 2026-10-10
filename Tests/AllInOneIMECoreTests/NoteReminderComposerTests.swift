import Foundation
import Testing
@testable import AllInOneIMECore

/// @note and @reminder: they stay on this Mac (nothing for a model) and insert nothing.
extension ComposerTests {
    var commandC: KeyEvent { KeyEvent(keyCode: 0x08, characters: "c", modifiers: .command) }

    /// A composer (⏎ as the action key) with "@" and `letters` typed, then Tab.
    func command(_ letters: String) -> Composer {
        let (c, _) = composer(key: .enter)
        _ = c.handleKeyDown(at)
        type(letters, c)
        _ = c.handleKeyDown(tab)
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
        #expect(c.pasted("买牛奶\n和鸡蛋", id: 1) == [.updateMarkedText, .showPanel] && c.draft == "@note 买牛奶和鸡蛋")
        #expect(c.handleKeyDown(enterKey).effects.contains(.saveNote(text: "买牛奶和鸡蛋")))
        // Without any: a hint, nothing saved.
        let d = command("n")
        _ = d.handleKeyDown(enterKey)
        #expect(d.pasted(nil, id: 1) == [.notice("在命令后面写上内容")] && d.draft == "@note ")
    }

    @Test func reminderIsShownToConfirmThenAdded() {
        let c = command("rem")
        type("nihao", c)
        let preview = c.handleKeyDown(enterKey)
        #expect(preview.effects == [.previewReminder(input: "你好", id: 1), .updateMarkedText, .showPanel,
                                    .commandUsed("reminder")])
        #expect(c.phase == .translating(id: 1) && c.activeCommand == .reminder && c.choices.isEmpty)
        // The controller reads it and hands it back: one row, the title, to confirm.
        let reminder = ReminderDraft(title: "给张三打电话", due: DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 0),
                                     hasTime: true)
        #expect(c.receiveReminder(reminder, id: 2).isEmpty)  // not this request
        #expect(c.receiveReminder(reminder, id: 1) == [.showPanel])
        #expect(c.phase == .choosing && c.choices == [Composer.Choice(label: "1", kind: .reminder(reminder), text: "给张三打电话",
                                                                     isComplete: true)])
        #expect(c.highlighted == 0 && c.markedText == "reminder › 你好" && c.pendingReminder == reminder)
        // ⌘C copies the title and keeps it up; 0 is nothing here.
        #expect(c.handleKeyDown(commandC) == .consumed([.copy("给张三打电话"), .notice("已复制")]) && c.phase == .choosing)
        #expect(c.handleKeyDown(k("0")) == .consumed() && c.phase == .choosing)
        // Esc: back to the draft to fix the wording; ⏎ reads it again.
        #expect(c.handleKeyDown(escKey).effects == [.updateMarkedText, .showPanel])
        #expect(c.phase == .drafting && c.draft == "@reminder 你好" && c.choices.isEmpty && c.pendingReminder == nil)
        #expect(c.handleKeyDown(enterKey).effects.first == .previewReminder(input: "你好", id: 2))
        _ = c.receiveReminder(reminder, id: 2)
        // ⏎ adds it: nothing inserted, the draft is gone.
        let add = c.handleKeyDown(enterKey)
        #expect(add.effects == [.hidePanel, .updateMarkedText, .addReminder(reminder)] && commits(add).isEmpty)
        #expect(c.phase == .idle && c.draft.isEmpty && c.markedText.isEmpty && c.pendingReminder == nil)
        // Space and 1 add it too.
        for key in [spaceKey, k("1")] {
            let d = command("rem")
            type("nihao", d)
            _ = d.handleKeyDown(enterKey)
            _ = d.receiveReminder(reminder, id: 1)
            #expect(d.handleKeyDown(key).effects.last == .addReminder(reminder) && d.phase == .idle)
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
        let c = command("rem")
        type("nihao", c)
        _ = c.handleKeyDown(enterKey)
        let onlyTime = ReminderDraft(title: "", due: DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 0), hasTime: true)
        #expect(c.receiveReminder(onlyTime, id: 1) == [.showPanel])
        #expect(c.phase == .failed("写上要提醒的事，比如「明天下午3点给张三打电话」") && c.choices.isEmpty)
        #expect(commits(c.handleKeyDown(spaceKey)).isEmpty)  // Space reads it again (still nothing to add)
        _ = c.receiveReminder(onlyTime, id: 2)
        #expect(c.handleKeyDown(escKey).effects == [.updateMarkedText, .showPanel] && c.phase == .drafting)
        #expect(Composer.Messages.english.reminderWithoutTitle.hasPrefix("Write what to be reminded of"))
    }
}
